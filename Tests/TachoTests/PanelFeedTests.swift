import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tacho
import TachoKit

/// The panel's slower figures cost a query, so they are read when it opens and at most once a minute, never on the 1 s tick.
@MainActor @Suite(.serialized)
struct PanelFeedTests {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }

    private nonisolated static let answer = PanelInsights(results: InsightResults(
        today: TodayInsight(rule: .h8, metric: .cost, value: 1, range: nil, verdict: .inside),
        limits: LimitsInsight(rule: .l5, limit: nil),
        week: .w3,
        output: OutputInsight(rule: .p2, value: 1, range: nil),
        cache: nil,
        speed: nil,
        clis: nil,
        cacheReadPercent: nil,
        when: nil
    ))

    private struct Unreadable: Error {}

    /// There is no engine until the first-launch answer, so these start from one.
    private func model(_ sandbox: Sandbox, reads: Reads, fails: Bool = false) throws -> AppModel {
        try sandbox.seed { $0.askedAboutSources = true }
        let model = AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in }
        #expect(model.engine != nil)
        model.readInsights = { _, _ in
            reads.add()
            if fails { throw Unreadable() }
            return Self.answer
        }
        return model
    }

    @Test func anAnswerIsKept() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let model = try model(sandbox, reads: reads)
        await model.refreshInsights(now: Date(timeIntervalSince1970: 1_000))
        #expect(model.insights == Self.answer)
    }

    @Test func atMostOnceAMinute() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let model = try model(sandbox, reads: reads)
        let start = Date(timeIntervalSince1970: 1_000)
        await model.refreshInsights(now: start)
        await model.refreshInsights(now: start.addingTimeInterval(59))
        #expect(reads.count == 1)
        await model.refreshInsights(now: start.addingTimeInterval(60))
        #expect(reads.count == 2)
    }

    @Test func aFailedReadLeavesNoOldAnswer() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let model = try model(sandbox, reads: reads)
        let start = Date(timeIntervalSince1970: 1_000)
        await model.refreshInsights(now: start)
        model.readInsights = { _, _ in throw Unreadable() }
        await model.refreshInsights(now: start.addingTimeInterval(60))
        #expect(model.insights == nil)
    }

    @Test func aFailedReadIsNotRetriedEverySecond() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let model = try model(sandbox, reads: reads, fails: true)
        let start = Date(timeIntervalSince1970: 1_000)
        await model.refreshInsights(now: start)
        await model.refreshInsights(now: start.addingTimeInterval(1))
        #expect(reads.count == 1)
    }

    @Test func beforeTheFirstAnswerThereIsNothingToRead() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let model = AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in }
        model.readInsights = { _, _ in
            reads.add()
            return Self.answer
        }
        await model.refreshInsights(now: Date(timeIntervalSince1970: 1_000))
        #expect(reads.count == 0)
    }

    @Test func theTickNeverReads() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let model = try model(sandbox, reads: reads)
        model.start()
        // The tick is one second. A loaded full run can hold the main actor longer than a fixed sleep.
        #expect(await Tests.eventually(within: .seconds(30)) { model.dashboard != nil })
        #expect(reads.count == 0)
    }

    @Test func theLoopEndsWithItsTask() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let model = try model(sandbox, reads: reads)
        let task = Task { @MainActor in await model.whilePanelOpen() }
        _ = await Tests.eventually { reads.count == 1 }
        #expect(model.activePolls == 1)
        task.cancel()
        await task.value
        #expect(model.activePolls == 0)
    }

    // What the slower figures may say depends on every log being in, so crossing `.live` cannot wait for the minute.
    private func dashboard(_ phase: IngestProgress.Phase) -> Dashboard {
        Dashboard(
            perMinute: 0, perSecond: 0, isIdle: true, lastMinute: .zero, series: [], sources: [], quotas: [],
            today: TodaySummary(tokens: .zero, cost: .zero, speeds: []), alert: .none,
            progress: IngestProgress(phase: phase, filesDone: 0, filesTotal: 0), outputPerMinute: 0, costPerMinute: .zero
        )
    }

    /// An open panel, past its first read.
    private func openPanel(_ model: AppModel, reads: Reads) async -> Task<Void, Never> {
        let task = Task { @MainActor in await model.whilePanelOpen() }
        _ = await Tests.eventually { reads.count == 1 }
        return task
    }

    private func close(_ task: Task<Void, Never>) async {
        task.cancel()
        await task.value
    }

    @Test func reachingLiveReadsAtOnceWhileThePanelIsOpen() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let model = try model(sandbox, reads: reads)
        model.apply(dashboard(.history))
        let panel = await openPanel(model, reads: reads)
        model.apply(dashboard(.live))
        _ = await Tests.eventually { reads.count == 2 }
        #expect(reads.count == 2)
        await close(panel)
    }

    @Test func leavingLiveDropsTheAnswer() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let model = try model(sandbox, reads: reads)
        model.apply(dashboard(.live))
        await model.refreshInsights(now: Date(timeIntervalSince1970: 1_000))
        #expect(model.insights != nil)
        model.apply(dashboard(.history))
        #expect(model.insights == nil)
    }

    @Test func leavingLiveReadsAgainWhileThePanelIsOpen() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let model = try model(sandbox, reads: reads)
        // Counted on the way in and answered on the way out, with room between, as under load.
        model.readInsights = { _, _ in
            reads.add()
            try await Task.sleep(for: .milliseconds(50))
            return Self.answer
        }
        model.apply(dashboard(.live))
        let panel = await openPanel(model, reads: reads)
        model.apply(dashboard(.history))
        // The answer, not the count: the count rises first. Leaving `.live` has just cleared any earlier answer.
        _ = await Tests.eventually { model.insights == Self.answer }
        #expect(model.insights == Self.answer)
        #expect(reads.count == 2)
        await close(panel)
    }

    @Test func aClosedPanelWaitsToBeOpenedButNotForTheMinute() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let model = try model(sandbox, reads: reads)
        let start = Date(timeIntervalSince1970: 1_000)
        model.apply(dashboard(.history))
        await model.refreshInsights(now: start)
        model.apply(dashboard(.live))
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads.count == 1)
        await model.refreshInsights(now: start.addingTimeInterval(1))
        #expect(reads.count == 2)
    }

    @Test func stayingOnOneSideIsNoReasonToRead() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let model = try model(sandbox, reads: reads)
        model.apply(dashboard(.live))
        let panel = await openPanel(model, reads: reads)
        for _ in 0..<5 { model.apply(dashboard(.live)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads.count == 1)
        await close(panel)
    }

    @Test func anAnswerReadBeforeARebuildIsNotShownDuringIt() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let model = try model(sandbox, reads: reads)
        model.apply(dashboard(.live))
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        model.readInsights = { _, _ in
            reads.add()
            for await _ in gate { break }
            return Self.answer
        }
        let read = Task { @MainActor in await model.refreshInsights(now: Date(timeIntervalSince1970: 1_000)) }
        _ = await Tests.eventually { reads.count == 1 }
        model.apply(dashboard(.history))
        release.yield()
        await read.value
        #expect(model.insights == nil)
    }

    // The engine never reads the rate mode, and being told anything makes it throw away its day's caches.
    @Test func pickingARateModeLeavesTheEngineAlone() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let applied = Reads()
        let model = try model(sandbox, reads: reads)
        model.applyToEngine = { _, _ in applied.add() }
        model.setRateMode(.cost)
        #expect(model.preferences.rateMode == .cost)
        await model.settled()
        #expect(applied.count == 0)
    }

    @Test func aRateModeIsStillKeptForTheNextLaunch() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        try model(sandbox, reads: reads).setRateMode(.cost)
        let next = AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in }
        #expect(next.preferences.rateMode == .cost)
    }

    /// Through `save`, as the Settings page's rate picker and every other display setting go.
    @Test func displaySettingsLeaveTheEngineAlone() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let applied = Reads()
        let model = try model(sandbox, reads: reads)
        model.applyToEngine = { _, _ in applied.add() }
        let changes: [(inout Preferences) -> Void] = [
            { $0.rateMode = .cost },
            { $0.rateUnit = .perSecond },
            { $0.menuBarStyle = .iconOnly },
            { $0.language = .zhHans },
            { $0.pinnedCards = [.when] },
        ]
        for change in changes {
            var changed = model.preferences
            change(&changed)
            #expect(changed != model.preferences)
            model.save(changed)
        }
        await model.settled()
        #expect(applied.count == 0)
    }

    @Test func aChangeTheEngineReadsReachesIt() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let applied = Reads()
        let model = try model(sandbox, reads: reads)
        model.applyToEngine = { _, _ in applied.add() }
        var changed = model.preferences
        changed.enabledSources = [.codex]
        #expect(changed != model.preferences)
        model.save(changed)
        await model.settled()
        #expect(applied.count == 1)
    }

    /// With no engine at all, since one of these allows the Anthropic query.
    @Test func everySettingTheEngineReadsCounts() {
        let old = Preferences.defaults(home: URL(fileURLWithPath: "/one"))
        let changes: [(inout Preferences) -> Void] = [
            { $0.enabledSources = [.codex] },
            { $0.quotaSources = [.codex] },
            { $0.roots = Preferences.defaults(home: URL(fileURLWithPath: "/two")).roots },
            { $0.anthropicQueryEnabled = true },
            { $0.priceOverrides = ["acme-coder-2": PriceEntry(id: "acme-coder-2", provider: "acme", price: Price(input: 1, output: 2, cacheRead: 0.1, cacheWrite5m: 1.25, cacheWrite1h: 2))] },
        ]
        for change in changes {
            var new = old
            change(&new)
            #expect(new != old)
            #expect(AppModel.reachesEngine(from: old, to: new))
        }
    }

    @Test func aSettingNobodyListedReachesTheEngine() {
        let old = Preferences.defaults(home: URL(fileURLWithPath: "/one"))
        var new = old
        new.askedAboutSources.toggle()
        #expect(AppModel.reachesEngine(from: old, to: new))
    }

    @Test func nothingChangedIsNothingToTell() {
        let same = Preferences.defaults(home: URL(fileURLWithPath: "/one"))
        #expect(!AppModel.reachesEngine(from: same, to: same))
    }

    // Through a real window: closing the panel has to stop the reads, whatever SwiftUI does with the view.
    private func window(_ model: AppModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PopoverView(model: model, open: { _ in }, quit: {}))
        return window
    }

    @Test func aHostedPanelReadsOnlyWhileItsWindowIsUp() async throws {
        let sandbox = try Sandbox()
        let reads = Reads()
        let model = try model(sandbox, reads: reads)
        let window = window(model)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(reads.count == 0)

        window.alphaValue = 0
        window.orderFront(nil)
        _ = await Tests.eventually { reads.count == 1 }
        #expect(reads.count == 1)
        #expect(model.activePolls == 1)

        window.orderOut(nil)
        _ = await Tests.eventually { model.activePolls == 0 }
        #expect(model.activePolls == 0)
    }
}
