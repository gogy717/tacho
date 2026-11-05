import SwiftUI
import TachoKit

/// The price table, with the person's own rows over it.
struct PricesEditor: View {
    /// A row in the edit sheet.
    private struct Editing: Identifiable {
        var entry: PriceEntry
        var isNew: Bool

        var id: String { isNew ? "" : entry.id }
    }

    let model: AppModel

    @State private var entries: Loaded<[PriceEntry]> = .loading
    @State private var editing: Editing?

    var body: some View {
        Section {
            switch entries {
            case .loading: ProgressView().frame(maxWidth: .infinity)
            case .failed: ProblemNote(model: model)
            case .ready(let entries):
                ForEach(entries, id: \.id) { entry in
                    PriceRow(entry: entry) { editing = Editing(entry: entry, isNew: false) }
                }
            }
        } header: {
            HStack {
                Text(String(localized: "prices.title", bundle: .tacho))
                Spacer()
                Button(String(localized: "prices.add", bundle: .tacho)) {
                    let empty = Price(input: 0, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0)
                    editing = Editing(entry: PriceEntry(id: "", provider: QuotaProvider.anthropic.rawValue, price: empty), isNew: true)
                }
                .disabled(model.engine == nil)
                Button(String(localized: "prices.restore", bundle: .tacho)) {
                    var changed = model.preferences
                    changed.priceOverrides = [:]
                    model.save(changed)
                }
                .disabled(model.preferences.priceOverrides.isEmpty)
            }
        } footer: {
            Text(String(localized: "prices.unit", bundle: .tacho))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { editing in
            PriceSheet(entry: editing.entry, isNew: editing.isNew, takenIds: takenIds, save: save)
        }
        .task(id: model.preferences.priceOverrides) {
            guard let engine = model.engine else {
                entries = .failed
                return
            }
            await model.settled()
            let latest = await engine.prices.entries
            if !Task.isCancelled { entries = .ready(latest) }
        }
    }

    private var takenIds: Set<String> {
        guard case .ready(let entries) = entries else { return [] }
        return Set(entries.map(\.id))
    }

    /// An override replaces its row whole, so `entry` carries whatever the row had, its fast and long-context cards included.
    private func save(_ entry: PriceEntry) {
        var row = entry
        row.source = nil
        row.asOf = nil
        var changed = model.preferences
        changed.priceOverrides[row.id] = row
        model.save(changed)
    }
}

/// One row: the rates, and where they come from.
struct PriceRow: View {
    let entry: PriceEntry
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.id)
                Text(rates)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            origin
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(String(localized: "prices.edit", bundle: .tacho), action: edit)
                .controlSize(.small)
        }
    }

    private var rates: String {
        let price = entry.price
        return String(
            format: String(localized: "prices.rates", bundle: .tacho),
            Labels.priceRate(price.input),
            Labels.priceRate(price.output),
            Labels.priceRate(price.cacheRead),
            Labels.priceRate(price.cacheWrite5m),
            Labels.priceRate(price.cacheWrite1h)
        )
    }

    @ViewBuilder private var origin: some View {
        switch PriceOrigin(entry) {
        case .page(let url, let name):
            HStack(spacing: 6) {
                Link(name, destination: url)
                    .help(entry.source ?? name)
                if let asOf = entry.asOf { Text(asOf) }
            }
        case .note(let note):
            HStack(spacing: 6) {
                Text(note)
                if let asOf = entry.asOf { Text(asOf) }
            }
        case .yours:
            Text(String(localized: "prices.yours", bundle: .tacho))
        }
    }
}

/// Where a row's price came from, as the row says it.
enum PriceOrigin: Equatable {
    /// Read off this page.
    case page(URL, name: String)
    /// Not from a page: the row says so in words.
    case note(String)
    /// The person set it.
    case yours

    init(_ entry: PriceEntry) {
        guard let source = entry.source else {
            self = .yours
            return
        }
        if let url = URL(string: source), url.scheme == "https", let host = url.host() {
            self = .page(url, name: host)
        } else {
            self = .note(source)
        }
    }
}

/// Edits a copy of a row, which is why the cards it does not show come through untouched.
struct PriceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    let takenIds: Set<String>
    let save: (PriceEntry) -> Void

    @State private var entry: PriceEntry

    init(entry: PriceEntry, isNew: Bool, takenIds: Set<String>, save: @escaping (PriceEntry) -> Void) {
        _entry = State(initialValue: entry)
        self.isNew = isNew
        self.takenIds = takenIds
        self.save = save
    }

    /// As `PriceTable` keeps ids.
    private var id: String {
        entry.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A new row under a taken id would replace that row and drop its other cards; editing the row keeps them.
    private var isTaken: Bool {
        isNew && takenIds.contains(id)
    }

    private var rates: [Double] {
        let price = entry.price
        return [price.input, price.output, price.cacheRead, price.cacheWrite5m, price.cacheWrite1h]
    }

    /// A model without a row says "no price". A new row of zeros would make it free instead, and the note would go with it.
    private var needsRate: Bool {
        isNew && rates.allSatisfy { $0 == 0 }
    }

    private var isValid: Bool {
        !id.isEmpty && !isTaken && !needsRate && rates.allSatisfy { $0.isFinite && $0 >= 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                if isNew {
                    TextField(String(localized: "prices.model", bundle: .tacho), text: $entry.id)
                    Picker(String(localized: "prices.provider", bundle: .tacho), selection: $entry.provider) {
                        ForEach(QuotaProvider.allCases, id: \.self) { Text(Labels.provider($0)).tag($0.rawValue) }
                    }
                } else {
                    LabeledContent(String(localized: "prices.model", bundle: .tacho), value: entry.id)
                }
                rate("category.input", \.input)
                rate("category.output", \.output)
                rate("category.cacheRead", \.cacheRead)
                rate("prices.cacheWrite5m", \.cacheWrite5m)
                rate("prices.cacheWrite1h", \.cacheWrite1h)
            }
            if isTaken {
                note(String(localized: "prices.taken", bundle: .tacho))
            }
            if needsRate {
                note(String(localized: "prices.needsRate", bundle: .tacho))
            }
            if entry.fast != nil || entry.longContext != nil {
                note(String(localized: "prices.otherCards", bundle: .tacho))
            }
            note(String(localized: "prices.unit", bundle: .tacho))
            HStack {
                Spacer()
                Button(String(localized: "settings.cancel", bundle: .tacho)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "prices.save", bundle: .tacho)) {
                    var row = entry
                    row.id = id
                    save(row)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func rate(_ title: String.LocalizationValue, _ field: WritableKeyPath<Price, Double>) -> some View {
        TextField(
            String(localized: title, bundle: .tacho),
            value: Binding(get: { entry.price[keyPath: field] }, set: { entry.price[keyPath: field] = $0 }),
            format: .number.precision(.fractionLength(0...6)).grouping(.never).locale(Locale(identifier: "en_US"))
        )
        .multilineTextAlignment(.trailing)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
