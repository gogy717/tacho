import ServiceManagement
import SwiftUI
import TachoKit

/// Everything the person can change.
struct SettingsPage: View {
    let model: AppModel

    var body: some View {
        Form {
            if model.couldNotSave {
                Section {
                    Text(String(localized: "settings.couldNotSave", bundle: .tacho))
                }
            }
            SourcesSettings(model: model)
            RateSettings(model: model)
            AnthropicSettings(model: model)
            Section(String(localized: "settings.general", bundle: .tacho)) {
                LoginSetting()
                LanguageSetting(model: model)
                RebuildSetting(model: model)
            }
            // Last: 55 rows would otherwise push everything else out of sight.
            PricesEditor(model: model)
        }
        .formStyle(.grouped)
    }
}

extension AppModel {
    /// A preference as a control edits it. `anthropicQueryEnabled` does not go through here: only `answerConsent` turns it on.
    func setting<Value>(_ field: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { self.preferences[keyPath: field] },
            set: { value in
                var changed = self.preferences
                changed[keyPath: field] = value
                self.save(changed)
            }
        )
    }
}

/// What the rate shows, in the menu bar and the panel. Spec section 13.3.
private struct RateSettings: View {
    let model: AppModel

    private var isCost: Bool {
        model.preferences.rateMode == .cost
    }

    var body: some View {
        Section(String(localized: "settings.rate", bundle: .tacho)) {
            Picker(String(localized: "settings.rateShows", bundle: .tacho), selection: model.setting(\.rateMode)) {
                ForEach([RateMode.output, .allTokens, .cost], id: \.self) { Text(Labels.rateMode($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker(String(localized: "settings.unit", bundle: .tacho), selection: model.setting(\.rateUnit)) {
                Text(String(localized: "settings.perMinute", bundle: .tacho)).tag(RateUnit.perMinute)
                Text(String(localized: "settings.perSecond", bundle: .tacho)).tag(RateUnit.perSecond)
            }
            .pickerStyle(.segmented)
            .disabled(isCost)
            if isCost {
                SettingNote(String(localized: "settings.costPerMinute", bundle: .tacho))
            }
            Picker(String(localized: "settings.style", bundle: .tacho), selection: model.setting(\.menuBarStyle)) {
                Text(String(localized: "settings.styleRate", bundle: .tacho)).tag(MenuBarStyle.rate)
                Text(String(localized: "settings.styleIcon", bundle: .tacho)).tag(MenuBarStyle.iconOnly)
                Text(String(localized: "settings.styleFiveHour", bundle: .tacho)).tag(MenuBarStyle.fiveHourPercent)
            }
            .pickerStyle(.segmented)
        }
    }
}

/// Switching this on goes through the consent sheet, so Allow stays the only way in; switching it off applies at once.
private struct AnthropicSettings: View {
    let model: AppModel

    var body: some View {
        Section(String(localized: "settings.anthropicTitle", bundle: .tacho)) {
            Toggle(
                String(localized: "settings.anthropicQuery", bundle: .tacho),
                isOn: Binding(
                    get: { model.preferences.anthropicQueryEnabled },
                    set: { wanted in
                        if wanted {
                            model.requestConsent()
                        } else {
                            model.turnOffAnthropicQuery()
                        }
                    }
                )
            )
            ConsentFacts()
        }
    }
}

private struct LoginSetting: View {
    @State private var status = SMAppService.mainApp.status
    @State private var failure: String?

    var body: some View {
        Toggle(
            String(localized: "settings.launchAtLogin", bundle: .tacho),
            // A closure, not `change` itself: passing the method crashes the Swift 6.1 compiler.
            isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: { change($0) })
        )
        if status == .requiresApproval {
            SettingNote(String(localized: "settings.launchNeedsApproval", bundle: .tacho))
        }
        if let failure {
            SettingNote(String(format: String(localized: "settings.launchFailed", bundle: .tacho), failure))
        }
    }

    private func change(_ isOn: Bool) {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}

private struct LanguageSetting: View {
    let model: AppModel

    var body: some View {
        Picker(
            String(localized: "settings.language", bundle: .tacho),
            selection: Binding(get: { model.preferences.language }, set: { model.setLanguage($0) })
        ) {
            Text(String(localized: "settings.languageSystem", bundle: .tacho)).tag(AppLanguage.system)
            Text(String(localized: "settings.languageEnglish", bundle: .tacho)).tag(AppLanguage.en)
            Text(String(localized: "settings.languageChinese", bundle: .tacho)).tag(AppLanguage.zhHans)
        }
        if model.preferences.language != model.launchLanguage {
            SettingNote(String(localized: "settings.restart", bundle: .tacho))
        }
    }
}

private struct RebuildSetting: View {
    private enum Outcome { case running, finished, failed }

    let model: AppModel

    @State private var isConfirming = false
    @State private var outcome: Outcome?

    var body: some View {
        HStack {
            Text(String(localized: "settings.rebuild", bundle: .tacho))
            Spacer()
            if outcome == .running {
                ProgressView().controlSize(.small)
            }
            Button(String(localized: "settings.rebuildButton", bundle: .tacho)) { isConfirming = true }
                .disabled(model.engine == nil || outcome == .running)
        }
        .confirmationDialog(String(localized: "settings.rebuildTitle", bundle: .tacho), isPresented: $isConfirming) {
            Button(String(localized: "settings.rebuildButton", bundle: .tacho), role: .destructive) {
                Task { await rebuild() }
            }
            Button(String(localized: "settings.cancel", bundle: .tacho), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.rebuildWarning", bundle: .tacho))
        }
        if model.engine == nil {
            SettingNote(String(localized: "popover.unavailable", bundle: .tacho))
        } else if outcome == .finished {
            SettingNote(String(localized: "settings.rebuildDone", bundle: .tacho))
        } else if outcome == .failed {
            SettingNote(String(localized: "settings.rebuildFailed", bundle: .tacho))
        }
    }

    private func rebuild() async {
        outcome = .running
        do {
            try await model.rebuildIndex()
            outcome = .finished
        } catch {
            outcome = .failed
        }
    }
}

private struct SettingNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
