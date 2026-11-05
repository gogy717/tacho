import Foundation
import Testing
@testable import Tacho
import TachoKit

/// The first-launch order: nothing is read until the chooser has an answer, and then only what was chosen.
@MainActor @Suite(.serialized)
struct SetupFlowTests {
    @Test func notWatchedListsWhatWasNotFoundAndNothingDetected() throws {
        let sandbox = try Sandbox()
        let names = SourceChooser.notWatched(detected: [.claudeCode], home: sandbox.home).map(\.name)
        #expect(!names.contains(Source.claudeCode.displayName))
        #expect(names.contains(Source.codex.displayName))
    }

    @Test func withEverySourceDetectedNothingIsListed() throws {
        let sandbox = try Sandbox()
        #expect(SourceChooser.notWatched(detected: Source.allCases, home: sandbox.home).isEmpty)
    }

    private func model(_ sandbox: Sandbox, _ log: LaunchLog) -> AppModel {
        AppModel(home: sandbox.home, defaults: sandbox.defaults) { await log.record($0) }
    }

    @Test func aNilAnswerNeverReachesEngineStart() async throws {
        let sandbox = try Sandbox()
        let log = LaunchLog()
        let model = model(sandbox, log)
        model.start()
        model.answerSources(nil)
        model.start()
        await model.settled()
        #expect(await log.count == 0)
    }

    @Test func noAnswerMeansNoEngineAtAll() async throws {
        let sandbox = try Sandbox(installed: [".claude"])
        let log = LaunchLog()
        let model = model(sandbox, log)
        model.start()
        await model.settled()
        #expect(await log.count == 0)
        #expect(model.engine == nil)
        #expect(!FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent("Library/Application Support/Tacho/tacho.sqlite").path))
    }

    @Test func settingsSavedBeforeTheAnswerReachNoEngine() async throws {
        let sandbox = try Sandbox(installed: [".claude"])
        let log = LaunchLog()
        let model = model(sandbox, log)
        var changed = model.preferences
        changed.rateUnit = .perSecond
        model.save(changed)
        await model.settled()
        #expect(model.engine == nil)
        #expect(await log.count == 0)
    }

    @Test func theChosenSourcesAreInForceWhenTheEngineStarts() async throws {
        let sandbox = try Sandbox(installed: [".claude", ".codex", ".grok"])
        let log = LaunchLog()
        let model = model(sandbox, log)
        model.start()
        model.answerSources([.claudeCode, .grok])
        await model.settled()
        #expect(await log.count == 1)
        #expect(await log.enabled == [[.claudeCode, .grok]])
    }

    @Test func theEngineStartsOnce() async throws {
        let sandbox = try Sandbox(installed: [".claude"])
        let log = LaunchLog()
        let model = model(sandbox, log)
        model.answerSources([.claudeCode])
        model.start()
        model.start()
        await model.settled()
        #expect(await log.count == 1)
    }

    @Test func uncheckedAndUndetectedStayOff() throws {
        let sandbox = try Sandbox(installed: [".claude", ".codex"])
        let model = model(sandbox, LaunchLog())
        model.answerSources([.codex])
        #expect(model.preferences.enabledSources == [.codex])
        #expect(model.preferences.askedAboutSources)
    }

    @Test func anEmptyChoiceIsAnAnswer() async throws {
        let sandbox = try Sandbox(installed: [".claude"])
        let log = LaunchLog()
        let model = model(sandbox, log)
        model.answerSources([])
        await model.settled()
        #expect(model.preferences.enabledSources.isEmpty)
        #expect(model.preferences.askedAboutSources)
        #expect(await log.enabled == [[]])
    }

    @Test func aLaterLaunchStartsByItself() async throws {
        let sandbox = try Sandbox(installed: [".claude"])
        try sandbox.seed {
            $0.askedAboutSources = true
            $0.askedAboutAnthropicQuery = true
            $0.enabledSources = [.claudeCode]
        }
        let log = LaunchLog()
        let model = model(sandbox, log)
        #expect(model.setupStep == nil)
        model.start()
        await model.settled()
        #expect(await log.enabled == [[.claudeCode]])
    }

    @Test func theAnswerSurvivesARestart() throws {
        let sandbox = try Sandbox(installed: [".claude", ".codex"])
        let first = model(sandbox, LaunchLog())
        first.answerSources([.codex])
        let second = model(sandbox, LaunchLog())
        #expect(second.preferences.askedAboutSources)
        #expect(second.preferences.enabledSources == [.codex])
        #expect(second.engine != nil)
    }

    @Test func noneDetectedKeepsTheDefaultsAndAsksAgain() throws {
        let sandbox = try Sandbox()
        let first = model(sandbox, LaunchLog())
        #expect(first.detectedSources.isEmpty)
        first.answerSources(nil)
        #expect(first.preferences.enabledSources == Set(Source.allCases))
        #expect(!first.preferences.askedAboutSources)
        let second = model(sandbox, LaunchLog())
        #expect(second.setupStep == .sources)
    }

    @Test func noneDetectedSaysSoInsteadOfNoFigures() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox, LaunchLog())
        #expect(Labels.setupNote(model) == String(localized: "setup.waiting", bundle: .tacho))
        model.answerSources(nil)
        #expect(Labels.setupNote(model) == String(localized: "setup.none", bundle: .tacho))
        #expect(!model.isFailing)
    }

    @Test func detectedMeansARootExists() throws {
        let sandbox = try Sandbox(installed: [".claude", ".local/share/opencode/opencode.db"])
        let model = model(sandbox, LaunchLog())
        #expect(Set(model.detectedSources) == [.claudeCode, .opencode])
    }

    @Test func aSecondAnswerChangesNothing() async throws {
        let sandbox = try Sandbox(installed: [".claude", ".codex"])
        let log = LaunchLog()
        let model = model(sandbox, log)
        model.answerSources([.claudeCode])
        let engine = model.engine
        model.answerSources([.codex])
        await model.settled()
        #expect(model.engine === engine)
        #expect(model.preferences.enabledSources == [.claudeCode])
        #expect(await log.count == 1)
    }

    @Test func aPathOutsideTheDefaultsCanStillBeAdded() throws {
        // Spec §5.3: a menu bar app cannot see CLAUDE_CONFIG_DIR, so a CLI elsewhere is found only through Settings, and Settings has to
        // offer that with no engine to ask.
        let sandbox = try Sandbox()
        let model = model(sandbox, LaunchLog())
        model.answerSources(nil)
        let statuses = try #require(model.statusesBeforeEngine)
        #expect(statuses.map(\.source) == Source.allCases)
        #expect(statuses.allSatisfy { !$0.detected })
        #expect(statuses.first { $0.source == .claudeCode }?.roots == model.preferences.roots.roots[.claudeCode])
    }

    @Test func addingAPathThatExistsBringsTheChooserBack() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox, LaunchLog())
        model.answerSources(nil)
        #expect(model.setupStep == .consent)
        let elsewhere = sandbox.home.appendingPathComponent("elsewhere/claude")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        var changed = model.preferences
        changed.roots.roots[.claudeCode, default: []].append(elsewhere.path)
        model.save(changed)
        #expect(model.setupStep == .sources)
        #expect(model.detectedSources == [.claudeCode])
    }

    @Test func aPathThatDoesNotExistChangesNothing() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox, LaunchLog())
        model.answerSources(nil)
        var changed = model.preferences
        changed.roots.roots[.claudeCode, default: []].append(sandbox.home.appendingPathComponent("nowhere").path)
        model.save(changed)
        #expect(model.setupStep == .consent)
    }

    @Test func thereAreNoRowsOfItsOwnOnceAnswered() throws {
        // The engine has the figures then, and a failed one is a problem to say, not an empty list to show.
        let sandbox = try Sandbox(installed: [".claude"], noEngine: true)
        let model = model(sandbox, LaunchLog())
        model.answerSources([.claudeCode])
        #expect(model.statusesBeforeEngine == nil)
    }

    @Test func theChooserComesBeforeTheConsent() throws {
        let sandbox = try Sandbox(installed: [".claude"], noEngine: true)
        let model = model(sandbox, LaunchLog())
        #expect(model.setupStep == .sources)
        model.answerSources([.claudeCode])
        #expect(model.setupStep == .consent)
        model.answerConsent(allow: false)
        #expect(model.setupStep == nil)
    }

    @Test func theConsentStillFollowsWhenNothingWasFound() throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox, LaunchLog())
        model.answerSources(nil)
        #expect(model.setupStep == .consent)
    }

    @Test func anEarlierConsentIsNotAskedAgain() throws {
        let sandbox = try Sandbox(installed: [".claude"], noEngine: true)
        try sandbox.seed { $0.askedAboutAnthropicQuery = true }
        let model = model(sandbox, LaunchLog())
        #expect(model.setupStep == .sources)
        model.answerSources([.claudeCode])
        #expect(model.setupStep == nil)
    }

    @Test func theChooserOpensTheWindowAtLaunch() throws {
        let sandbox = try Sandbox()
        try sandbox.seed { $0.askedAboutAnthropicQuery = true }
        #expect(model(sandbox, LaunchLog()).opensMainWindowAtLaunch)
    }

    @Test func theReadyStepFollowsTheConsent() throws {
        let sandbox = try Sandbox(installed: [".claude"])
        let model = model(sandbox, LaunchLog())
        model.answerSources([.claudeCode])
        #expect(model.setupStep == .consent)
        model.answerConsent(allow: false)
        #expect(model.setupStep == .ready)
        model.finishSetup()
        #expect(model.setupStep == nil)
    }

    @Test func theReadyStepComesStraightAfterTheChooserWhenConsentWasAnswered() throws {
        let sandbox = try Sandbox(installed: [".claude"])
        try sandbox.seed { $0.askedAboutAnthropicQuery = true }
        let model = model(sandbox, LaunchLog())
        model.answerSources([.claudeCode])
        #expect(model.setupStep == .ready)
    }

    @Test func settingsNeverBringsTheReadyStepBack() throws {
        let sandbox = try Sandbox(installed: [".claude"])
        let model = model(sandbox, LaunchLog())
        model.answerSources([.claudeCode])
        model.answerConsent(allow: false)
        model.finishSetup()
        model.requestConsent()
        #expect(model.setupStep == .consent)
        model.answerConsent(allow: false)
        #expect(model.setupStep == nil)
    }

    @Test func nothingFoundMeansNoReadyStep() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox, LaunchLog())
        model.answerSources(nil)
        model.answerConsent(allow: false)
        #expect(model.setupStep == nil)
    }

    @Test func aFailedEngineMeansNoReadyStep() throws {
        let sandbox = try Sandbox(installed: [".claude"], noEngine: true)
        let model = model(sandbox, LaunchLog())
        model.answerSources([.claudeCode])
        model.answerConsent(allow: false)
        #expect(model.setupStep == nil)
    }

    @Test func theReadyStepDoesNotOutliveALaunch() throws {
        let sandbox = try Sandbox(installed: [".claude"])
        let first = model(sandbox, LaunchLog())
        first.answerSources([.claudeCode])
        first.answerConsent(allow: false)
        #expect(first.setupStep == .ready)
        #expect(model(sandbox, LaunchLog()).setupStep == nil)
    }

    @Test func aFailedEngineIsAProblemOnceAnswered() throws {
        let sandbox = try Sandbox(installed: [".claude"], noEngine: true)
        let model = model(sandbox, LaunchLog())
        #expect(!model.isFailing)
        model.answerSources([.claudeCode])
        #expect(model.isFailing)
        #expect(Labels.setupNote(model) == nil)
    }
}
