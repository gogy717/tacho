import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tacho
import TachoKit

/// One window, owned by the delegate, reached the same way from everywhere. Sizes are the window's own: `fittingSize` hid the empty popover.
@MainActor @Suite(.serialized)
struct MainWindowTests {
    private func delegate(_ sandbox: Sandbox) -> AppDelegate {
        .quiet(AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in })
    }

    private func answered(_ sandbox: Sandbox) throws {
        try sandbox.seed {
            $0.askedAboutSources = true
            $0.askedAboutAnthropicQuery = true
        }
    }

    @Test func itOpensAtItsFullSize() async throws {
        let sandbox = try Sandbox()
        try answered(sandbox)
        let delegate = delegate(sandbox)
        delegate.showMainWindow()
        defer { delegate.mainWindow?.close() }
        let window = try #require(delegate.mainWindow)
        #expect(await Tests.eventually { window.contentView?.frame.size == NSSize(width: 1240, height: 720) })
    }

    @Test func aTestWindowLeavesNoFrameForOthersToOpenAt() throws {
        let sandbox = try Sandbox()
        try answered(sandbox)
        let delegate = delegate(sandbox)
        delegate.showMainWindow()
        defer { delegate.mainWindow?.close() }
        let window = try #require(delegate.mainWindow)
        #expect(window.frameAutosaveName.isEmpty)
    }

    @Test func theAppItselfKeepsItsFrame() throws {
        let sandbox = try Sandbox()
        let model = AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in }
        #expect(AppDelegate(model: model, present: Tests.hide, setActivationPolicy: { _ in }, terminate: {}).savesWindowFrame)
    }

    @Test func everyRouteReachesTheSameWindow() throws {
        let sandbox = try Sandbox()
        try answered(sandbox)
        let delegate = delegate(sandbox)
        delegate.showMainWindow()
        defer { delegate.mainWindow?.close() }
        let first = delegate.mainWindow
        delegate.showMainWindow(Route(page: .settings))
        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true) == false)
        #expect(delegate.mainWindow === first)
        #expect(delegate.model.page == .settings)
    }

    @Test func aReopenOpensItAgainAfterItClosed() throws {
        let sandbox = try Sandbox()
        try answered(sandbox)
        let delegate = delegate(sandbox)
        delegate.showMainWindow()
        delegate.mainWindow?.close()
        #expect(delegate.mainWindow == nil)
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        defer { delegate.mainWindow?.close() }
        #expect(delegate.mainWindow != nil)
    }

    @Test func theAppOutlivesItsWindow() throws {
        let sandbox = try Sandbox()
        #expect(!delegate(sandbox).applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @Test func firstLaunchShowsOneSheetThroughBothQuestions() async throws {
        let sandbox = try Sandbox(installed: [".claude", ".codex"], noEngine: true)
        let delegate = delegate(sandbox)
        delegate.showMainWindow()
        defer { delegate.mainWindow?.close() }
        let window = try #require(delegate.mainWindow)
        #expect(await Tests.eventually { (window.attachedSheet?.frame.height ?? 0) > 150 })
        let chooser = try #require(window.attachedSheet)
        #expect(chooser.frame.width == 460)
        delegate.model.answerSources([.claudeCode])
        #expect(await Tests.eventually { (window.attachedSheet?.frame.height ?? 0) > 250 })
        // The same sheet, grown: not a second one.
        #expect(window.attachedSheet === chooser)
        delegate.model.answerConsent(allow: false)
        #expect(await Tests.eventually { window.attachedSheet == nil })
    }

    @Test func noCLIStillGetsAReadableChooser() async throws {
        let sandbox = try Sandbox(noEngine: true)
        let delegate = delegate(sandbox)
        delegate.showMainWindow()
        defer { delegate.mainWindow?.close() }
        let window = try #require(delegate.mainWindow)
        #expect(await Tests.eventually { (window.attachedSheet?.frame.height ?? 0) > 100 })
    }

    @Test func theBlockedNoteKeepsTheWindowsSize() async throws {
        let sandbox = try Sandbox()
        try answered(sandbox)
        let delegate = delegate(sandbox)
        delegate.menuBarItemRemoved()
        defer { delegate.mainWindow?.close() }
        let window = try #require(delegate.mainWindow)
        #expect(await Tests.eventually { window.contentView?.frame.size == NSSize(width: 1240, height: 720) })
    }
}
