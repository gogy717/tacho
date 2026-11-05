import AppKit
import SwiftUI
import TachoKit

/// What each source has read, whether it is read and counted, and where it lives.
struct SourcesSettings: View {
    private static let refreshInterval: Duration = .seconds(5)

    let model: AppModel

    @State private var statuses: Loaded<[SourceStatus]> = .loading

    var body: some View {
        Section {
            switch statuses {
            case .loading: ProgressView().frame(maxWidth: .infinity)
            case .failed: ProblemNote(model: model)
            case .ready(let statuses):
                ForEach(statuses, id: \.source) { SourceSettingsRow(status: $0, model: model) }
            }
            ForEach(SourceRoots.unsupportedDetected(home: model.home), id: \.self) { name in
                LabeledContent(name, value: String(localized: "settings.noRecords", bundle: .tacho))
            }
        } header: {
            Text(String(localized: "settings.sources", bundle: .tacho))
        } footer: {
            Text(String(localized: "quota.footnote", bundle: .tacho))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: model.preferences) {
            await model.settled()
            await model.whileShowing(.settings, every: Self.refreshInterval) {
                if let engine = model.engine {
                    let latest = await engine.statuses()
                    if !Task.isCancelled { statuses = .ready(latest) }
                } else if let unstarted = model.statusesBeforeEngine {
                    statuses = .ready(unstarted)
                } else {
                    statuses = .failed
                }
            }
        }
    }
}

/// One source.
struct SourceSettingsRow: View {
    let status: SourceStatus
    let model: AppModel

    private var paths: [String] {
        model.preferences.roots.roots[status.source] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(status.source.displayName)
                    .font(.body.weight(.medium))
                Text(String(localized: status.detected ? "settings.found" : "settings.notFound", bundle: .tacho))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Checkboxes: in a form, a switch stretches to fill the row, which pulls these two apart.
                Group {
                    Toggle(String(localized: "settings.read", bundle: .tacho), isOn: membership(\.enabledSources))
                    Toggle(String(localized: "settings.quota", bundle: .tacho), isOn: membership(\.quotaSources))
                }
                .toggleStyle(.checkbox)
                .fixedSize()
            }
            Text(figures)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            ForEach(paths, id: \.self) { path in
                HStack {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                    Spacer()
                    Button(String(localized: "settings.removePath", bundle: .tacho)) { remove(path) }
                        .controlSize(.small)
                }
            }
            Button(String(localized: "settings.addPath", bundle: .tacho), action: choosePath)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private var figures: String {
        let update = status.lastUpdate.map {
            String(format: String(localized: "settings.lastUpdate", bundle: .tacho), $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Labels.locale)))
        }
        return [
            String(format: String(localized: "settings.files", bundle: .tacho), status.files),
            String(format: String(localized: "settings.events", bundle: .tacho), status.events),
            String(format: String(localized: "settings.skipped", bundle: .tacho), status.skipped),
            update ?? String(localized: "settings.noUpdate", bundle: .tacho),
        ].joined(separator: " · ")
    }

    private func membership(_ field: WritableKeyPath<Preferences, Set<Source>>) -> Binding<Bool> {
        Binding(
            get: { model.preferences[keyPath: field].contains(status.source) },
            set: { isOn in
                var changed = model.preferences
                if isOn {
                    changed[keyPath: field].insert(status.source)
                } else {
                    changed[keyPath: field].remove(status.source)
                }
                model.save(changed)
            }
        )
    }

    /// OpenCode's root is its database file; every other root is a directory. The CLIs keep theirs hidden, so hidden files are shown.
    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = status.source != .opencode
        panel.canChooseFiles = status.source == .opencode
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let path = panel.url?.path, !paths.contains(path) else { return }
        var changed = model.preferences
        changed.roots.roots[status.source, default: []].append(path)
        model.save(changed)
    }

    private func remove(_ path: String) {
        var changed = model.preferences
        changed.roots.roots[status.source]?.removeAll { $0 == path }
        model.save(changed)
    }
}
