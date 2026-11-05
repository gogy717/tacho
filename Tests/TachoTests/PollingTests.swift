import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tacho
import TachoKit

/// Refreshes cost CPU, and idle use is budgeted, so they run only for a page on screen. Closed, the window polls nothing at all.
@MainActor @Suite(.serialized)
struct PollingTests {
    private func count(_ model: AppModel, page: Page, for wait: Duration = .milliseconds(200)) async -> Int {
        var runs = 0
        let task = Task { @MainActor in
            await model.whileShowing(page, every: .milliseconds(20)) { runs += 1 }
        }
        try? await Task.sleep(for: wait)
        task.cancel()
        await task.value
        return runs
    }

    private func model(_ sandbox: Sandbox) -> AppModel {
        AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in }
    }

    /// Other suites share the main actor, so a loop's ticks are late under load: this waits for them rather than counting a fixed time.
    private func eventually(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aVisiblePageRefreshes() async throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        model.page = .activity
        model.mainWindowVisible = true
        var runs = 0
        let task = Task { @MainActor in
            await model.whileShowing(.activity, every: .milliseconds(20)) { runs += 1 }
        }
        await eventually { runs > 2 }
        task.cancel()
        await task.value
        #expect(runs > 2)
    }

    @Test func aHiddenWindowGetsOnlyTheFirstLook() async throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        model.page = .activity
        model.mainWindowVisible = false
        #expect(await count(model, page: .activity) == 1)
    }

    @Test func anotherPageGetsOnlyTheFirstLook() async throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        model.page = .summary
        model.mainWindowVisible = true
        #expect(await count(model, page: .activity) == 1)
    }

    @Test func itResumesWhenTheWindowComesBack() async throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        model.page = .activity
        model.mainWindowVisible = false
        var runs = 0
        let task = Task { @MainActor in
            await model.whileShowing(.activity, every: .milliseconds(20)) { runs += 1 }
        }
        try? await Task.sleep(for: .milliseconds(120))
        #expect(runs == 1)
        model.mainWindowVisible = true
        await eventually { runs > 1 }
        task.cancel()
        await task.value
        #expect(runs > 1)
    }

    @Test func aLoopEndsWithItsTask() async throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        _ = await count(model, page: .summary, for: .milliseconds(60))
        #expect(model.activePolls == 0)
    }

    /// The real pages in the real window, so that this fails if a page polls by any other route than `whileShowing`, or outlives the window.
    @Test(arguments: Page.allCases)
    func nothingPollsWhenTheWindowIsClosed(page: Page) async throws {
        let sandbox = try Sandbox()
        try sandbox.seed {
            $0.askedAboutSources = true
            $0.askedAboutAnthropicQuery = true
        }
        let model = model(sandbox)
        let delegate = AppDelegate.quiet(model)
        delegate.showMainWindow(Route(page: page))
        #expect(await Tests.eventually { model.activePolls > 0 })
        #expect(model.mainWindowVisible)
        delegate.mainWindow?.close()
        // A read in flight when the window closes has to finish. A poll that outlived it would not stop: it wakes in 60 s, not 10.
        #expect(await Tests.eventually { model.activePolls == 0 })
        #expect(!model.mainWindowVisible)
        #expect(delegate.mainWindow == nil)
    }

    @Test func nothingPollsBeforeTheWindowFirstOpens() async throws {
        let sandbox = try Sandbox()
        try sandbox.seed {
            $0.askedAboutSources = true
            $0.askedAboutAnthropicQuery = true
        }
        let model = model(sandbox)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.activePolls == 0)
    }
}
