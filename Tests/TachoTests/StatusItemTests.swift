import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tacho
import TachoKit

/// A status item macOS does not allow must not quit the app. Its removal arrives as `terminate:` with nothing behind it: no Apple event,
/// no key or click. The real log for that: `NSStatusItemChangeVisibilityAction`, then `terminate:`, then the delegate is asked.
@MainActor @Suite(.serialized)
struct StatusItemTests {
    private func delegate(_ sandbox: Sandbox, policy: @escaping (NSApplication.ActivationPolicy) -> Void = { _ in }) -> AppDelegate {
        .quiet(AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in }, policy: policy)
    }

    private func key(at time: TimeInterval) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: time, windowNumber: 0, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)
    }

    private func zhStrings() throws -> [String: String] {
        let path = try #require(Bundle.tacho.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "zh-Hans"))
        return try #require(NSDictionary(contentsOfFile: path) as? [String: String])
    }

    @Test func aTerminationNobodyAskedForIsRefused() throws {
        let sandbox = try Sandbox()
        let delegate = delegate(sandbox)
        defer { delegate.mainWindow?.close() }
        #expect(delegate.terminationReply(appleEvent: false, input: nil, now: 100) == .terminateCancel)
        #expect(delegate.model.menuBarBlocked)
    }

    @Test func refusingItOpensTheMainWindow() throws {
        let sandbox = try Sandbox()
        let delegate = delegate(sandbox)
        defer { delegate.mainWindow?.close() }
        _ = delegate.terminationReply(appleEvent: false, input: nil, now: 100)
        #expect(delegate.mainWindow != nil)
    }

    @Test func anOldKeyPressDoesNotCount() throws {
        let sandbox = try Sandbox()
        let delegate = delegate(sandbox)
        defer { delegate.mainWindow?.close() }
        #expect(delegate.terminationReply(appleEvent: false, input: key(at: 90), now: 100) == .terminateCancel)
    }

    @Test func commandQIsAQuit() throws {
        let sandbox = try Sandbox()
        let delegate = delegate(sandbox)
        #expect(delegate.terminationReply(appleEvent: false, input: key(at: 99.9), now: 100) == .terminateNow)
        #expect(!delegate.model.menuBarBlocked)
    }

    @Test func aQuitAppleEventIsAQuit() throws {
        // Logging out, restarting, and `brew uninstall` all arrive this way.
        let sandbox = try Sandbox()
        let delegate = delegate(sandbox)
        #expect(delegate.terminationReply(appleEvent: true, input: nil, now: 100) == .terminateNow)
        #expect(!delegate.model.menuBarBlocked)
    }

    @Test func aTerminationAfterTheRemovalIsRefusedToo() throws {
        // A real run saw none, but the note must not depend on that: being blocked says nothing about who asked.
        let sandbox = try Sandbox()
        let delegate = delegate(sandbox)
        defer { delegate.mainWindow?.close() }
        delegate.menuBarItemRemoved()
        #expect(delegate.terminationReply(appleEvent: false, input: nil, now: 100) == .terminateCancel)
        #expect(delegate.terminationReply(appleEvent: false, input: nil, now: 101) == .terminateCancel)
    }

    @Test func whileBlockedAQuitIsStillAQuit() throws {
        let sandbox = try Sandbox()
        var terminations = 0
        let delegate = AppDelegate.quiet(AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in }, terminate: { terminations += 1 })
        defer { delegate.mainWindow?.close() }
        delegate.menuBarItemRemoved()
        #expect(delegate.terminationReply(appleEvent: true, input: nil, now: 100) == .terminateNow)
        #expect(delegate.terminationReply(appleEvent: false, input: key(at: 99.9), now: 100) == .terminateNow)
        delegate.quit()
        #expect(terminations == 1)
        #expect(delegate.terminationReply(appleEvent: false, input: nil, now: 100) == .terminateNow)
    }

    @Test func theBindingReportsTheRemoval() throws {
        let sandbox = try Sandbox()
        let delegate = delegate(sandbox)
        defer { delegate.mainWindow?.close() }
        #expect(delegate.menuBarItemInserted.wrappedValue)
        delegate.menuBarItemInserted.wrappedValue = false
        #expect(delegate.model.menuBarBlocked)
        #expect(!delegate.menuBarItemInserted.wrappedValue)
        #expect(delegate.mainWindow != nil)
    }

    @Test func aBlockedTachoGoesInTheDock() throws {
        let sandbox = try Sandbox()
        var policies: [NSApplication.ActivationPolicy] = []
        let delegate = delegate(sandbox) { policies.append($0) }
        defer { delegate.mainWindow?.close() }
        delegate.menuBarItemRemoved()
        delegate.menuBarItemRemoved()
        #expect(policies == [.regular])
    }

    @Test func itSaysWhereToAllowItInBothLanguages() throws {
        let path = try #require(Bundle.tacho.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en"))
        let en = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
        #expect(en["blocked.body"]?.contains("System Settings > Menu Bar") == true)
        let zh = try zhStrings()
        #expect(zh["blocked.body"]?.contains("系统设置 > 菜单栏") == true)
        #expect(zh["blocked.title"]?.isEmpty == false)
    }

    @Test func theSettingsHeadingUsesTheSpecsWording() throws {
        #expect(try zhStrings()["settings.sources"] == "数据来源")
    }
}
