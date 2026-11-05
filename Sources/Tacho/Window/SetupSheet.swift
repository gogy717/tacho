import SwiftUI
import TachoKit

/// The first-launch questions, one after the other in one sheet: the CLIs to watch, then the Anthropic query.
struct SetupSheet: View {
    let model: AppModel

    var body: some View {
        switch model.setupStep {
        case .sources:
            SourceChooser(
                detected: model.detectedSources,
                notWatched: SourceChooser.notWatched(detected: model.detectedSources, home: model.home)
            ) { model.answerSources($0) }
        case .consent:
            ConsentSheet { model.answerConsent(allow: $0) }
        case .ready:
            ReadyStep(progress: model.dashboard?.progress, menuBarBlocked: model.menuBarBlocked) { model.finishSetup() }
        case nil:
            // On its way out: the last answer is in, and no other question should flash up in the sheet as it closes.
            Color.clear.frame(width: 460, height: 120)
        }
    }
}

/// The CLIs found on this Mac, all ticked. Nothing is read until this is answered, so that the answer means something.
struct SourceChooser: View {
    /// A row of what cannot be chosen, and why.
    struct NotWatched: Equatable, Identifiable {
        var name: String
        var reason: String

        var id: String { name }
    }

    let detected: [Source]
    /// From whether a path exists and nothing more: nothing is read until this sheet is answered, so a count of files is no option here.
    let notWatched: [NotWatched]
    let answer: (Set<Source>?) -> Void

    @State private var checked: Set<Source>

    init(detected: [Source], notWatched: [NotWatched] = [], answer: @escaping (Set<Source>?) -> Void) {
        self.detected = detected
        self.notWatched = notWatched
        self.answer = answer
        _checked = State(initialValue: Set(detected))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if detected.isEmpty {
                note("setup.none")
            } else {
                Text(String(localized: "setup.title", bundle: .tacho))
                    .font(.title3.weight(.semibold))
                note("setup.intro")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(detected, id: \.self) { source in
                        Toggle(source.displayName, isOn: isChecked(source))
                            .toggleStyle(.checkbox)
                    }
                }
                if !notWatched.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "setup.notWatched", bundle: .tacho))
                            .font(Theme.Style.cardTitle)
                            .foregroundStyle(.secondary)
                        ForEach(notWatched) { row in
                            HStack {
                                Text(row.name)
                                Spacer()
                                Text(row.reason)
                            }
                            .font(Theme.Style.small)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                note("setup.later")
            }
            HStack {
                Spacer()
                // No default button: a stray Return must not answer for the person.
                Button(String(localized: "setup.continue", bundle: .tacho)) {
                    answer(detected.isEmpty ? nil : checked)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }

    static func notWatched(detected: [Source], home: URL) -> [NotWatched] {
        let notFound = String(localized: "settings.notFound", bundle: .tacho)
        let noRecords = String(localized: "settings.noRecords", bundle: .tacho)
        return Source.allCases.filter { !detected.contains($0) }.map { NotWatched(name: $0.displayName, reason: notFound) }
            + SourceRoots.unsupportedDetected(home: home).map { NotWatched(name: $0, reason: noRecords) }
    }

    private func note(_ key: String.LocalizationValue) -> some View {
        Text(String(localized: key, bundle: .tacho))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func isChecked(_ source: Source) -> Binding<Bool> {
        Binding(
            get: { checked.contains(source) },
            set: { isOn in
                if isOn {
                    checked.insert(source)
                } else {
                    checked.remove(source)
                }
            }
        )
    }
}

/// The last step: the answers are in, reading has begun, and this says where Tacho went. Done closes it and answers nothing, so it alone may
/// take the default action. Spec section 14.
struct ReadyStep: View {
    /// nil until the first figures arrive.
    let progress: IngestProgress?
    let menuBarBlocked: Bool
    let done: () -> Void

    private var line: String {
        guard let progress else { return String(localized: "progress.starting", bundle: .tacho) }
        return Labels.progress(progress) ?? String(localized: "ready.finished", bundle: .tacho)
    }

    /// nil while the amount is not known yet.
    private var fraction: Double? {
        guard let progress else { return nil }
        if progress.phase == .live { return 1 }
        return progress.filesTotal > 0 ? Double(progress.filesDone) / Double(progress.filesTotal) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "ready.title", bundle: .tacho))
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(line)
                    .font(Theme.Style.small)
                    .monospacedDigit()
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
            Text(String(localized: "ready.rise", bundle: .tacho))
                .font(Theme.Style.small)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "ready.where", bundle: .tacho))
                    .font(Theme.Style.cardTitle)
                    .foregroundStyle(.secondary)
                if menuBarBlocked {
                    Text(String(localized: "ready.blocked", bundle: .tacho))
                        .font(Theme.Style.small)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(String(localized: "ready.menuBar", bundle: .tacho), systemImage: "gauge.with.needle")
                        .font(Theme.Style.small)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(String(localized: "ready.usual", bundle: .tacho))
                    .font(Theme.Style.small)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(String(localized: "common.done", bundle: .tacho), action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
