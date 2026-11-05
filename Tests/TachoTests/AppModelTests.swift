import Foundation
import Testing
@testable import Tacho
import TachoKit

/// No `Engine` in here: `noEngine` means no fetcher can exist, whatever a test allows.
@MainActor @Suite(.serialized)
struct AppModelTests {
    private func model(_ sandbox: Sandbox) -> AppModel {
        AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in }
    }

    private func answeredSources(_ sandbox: Sandbox) throws {
        try sandbox.seed { $0.askedAboutSources = true }
    }

    @Test func allowIsWhatTurnsTheQueryOn() throws {
        let sandbox = try Sandbox(noEngine: true)
        try answeredSources(sandbox)
        let model = model(sandbox)
        #expect(model.isAskingConsent)
        #expect(model.opensMainWindowAtLaunch)
        model.answerConsent(allow: true)
        #expect(model.preferences.anthropicQueryEnabled)
        #expect(model.preferences.askedAboutAnthropicQuery)
        #expect(!model.isAskingConsent)
        #expect(!model.opensMainWindowAtLaunch)
    }

    @Test func notNowAnswersWithoutTurningItOn() throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        model.answerConsent(allow: false)
        #expect(!model.preferences.anthropicQueryEnabled)
        #expect(model.preferences.askedAboutAnthropicQuery)
        #expect(!model.isAskingConsent)
    }

    @Test func aSecondClickOnContinueCannotAllow() throws {
        // Continue and Allow nearly coincide when the sheet swaps, so the second click of a double-click lands on Allow.
        let sandbox = try Sandbox(installed: [".claude"], noEngine: true)
        let model = model(sandbox)
        model.answerSources([.claudeCode])
        model.answerConsent(allow: true)
        #expect(!model.preferences.anthropicQueryEnabled)
        #expect(model.setupStep == .consent)
    }

    @Test func nothingFoundIsNoDifferent() throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        model.answerSources(nil)
        model.answerConsent(allow: true)
        #expect(!model.preferences.anthropicQueryEnabled)
    }

    @Test func allowWorksOnceTheSheetHasSettled() async throws {
        let sandbox = try Sandbox(installed: [".claude"], noEngine: true)
        let model = model(sandbox)
        model.answerSources([.claudeCode])
        try? await Task.sleep(for: .milliseconds(650))
        model.answerConsent(allow: true)
        #expect(model.preferences.anthropicQueryEnabled)
        #expect(model.setupStep == nil)
    }

    @Test func notNowNeedsNoPause() throws {
        let sandbox = try Sandbox(installed: [".claude"], noEngine: true)
        let model = model(sandbox)
        model.answerSources([.claudeCode])
        model.answerConsent(allow: false)
        #expect(model.setupStep == nil)
    }

    @Test func theChooserCannotTurnTheQueryOn() throws {
        let sandbox = try Sandbox(installed: [".claude"], noEngine: true)
        let model = model(sandbox)
        model.answerSources([.claudeCode])
        #expect(!model.preferences.anthropicQueryEnabled)
        #expect(!model.preferences.askedAboutAnthropicQuery)
    }

    @Test func settingsAsksAgainAndSwitchingOffIsImmediate() throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        model.answerConsent(allow: false)
        model.requestConsent()
        #expect(model.isAskingConsent)
        #expect(!model.preferences.anthropicQueryEnabled)
        model.answerConsent(allow: false)
        #expect(!model.preferences.anthropicQueryEnabled)
        #expect(!model.isAskingConsent)
        model.requestConsent()
        model.answerConsent(allow: true)
        #expect(model.preferences.anthropicQueryEnabled)
        model.turnOffAnthropicQuery()
        #expect(!model.preferences.anthropicQueryEnabled)
    }

    @Test func consentSurvivesARestart() throws {
        let sandbox = try Sandbox(noEngine: true)
        model(sandbox).answerConsent(allow: true)
        let second = model(sandbox)
        #expect(second.preferences.anthropicQueryEnabled)
        #expect(!second.isAskingConsent)
    }

    @Test func thePageArgumentPicksThePage() throws {
        for page in Page.allCases {
            let sandbox = try Sandbox(noEngine: true)
            sandbox.defaults.set(page.rawValue, forKey: "TachoPage")
            #expect(model(sandbox).page == page)
        }
        #expect(Page.allCases.map(\.rawValue) == ["summary", "limits", "cost", "tokens", "cache", "speed", "activity", "calendar", "settings"])
    }

    @Test func theOpenArgumentOpensTheWindow() throws {
        let sandbox = try Sandbox(noEngine: true)
        try sandbox.seed {
            $0.askedAboutSources = true
            $0.askedAboutAnthropicQuery = true
        }
        #expect(!model(sandbox).opensMainWindowAtLaunch)
        sandbox.defaults.set(true, forKey: "TachoOpenMainWindow")
        #expect(model(sandbox).opensMainWindowAtLaunch)
    }

    @Test func languageGoesToTheAppsDefaults() throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        model.setLanguage(.zhHans)
        #expect(sandbox.defaults.object(forKey: "AppleLanguages") as? [String] == ["zh-Hans"])
        #expect(model.preferences.language != model.launchLanguage)
        model.setLanguage(.en)
        #expect(sandbox.defaults.object(forKey: "AppleLanguages") as? [String] == ["en"])
        model.setLanguage(.system)
        #expect(sandbox.defaults.object(forKey: "AppleLanguages") == nil)
        #expect(model.preferences.language == model.launchLanguage)
    }
}
