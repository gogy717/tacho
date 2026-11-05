import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tacho
import TachoKit

/// A page keeps the last answer it was given, and shows that on the way back. A different ask never borrows it. The three ways the
/// answer goes stale each drop it.
@MainActor @Suite(.serialized)
struct FigureCacheTests {
    private struct ReadFailed: Error {}

    @MainActor private final class Seen {
        var notes: [PageNote] = []
        var asks: [ShownAsk] = []
    }

    private func model(_ sandbox: Sandbox) -> AppModel {
        AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in }
    }

    private func week(_ usd: Double) -> DetailFigures {
        WindowSamples.figures(range: .week, usd: usd)
    }

    private func show(_ view: some View, _ seen: Seen) -> NSWindow {
        let root = view
            .onPreferenceChange(PageNoteKey.self) { note in
                MainActor.assumeIsolated { seen.notes.append(note) }
            }
            .onPreferenceChange(ShownAskKey.self) { ask in
                MainActor.assumeIsolated { if let ask { seen.asks.append(ask) } }
            }
            .frame(width: 1040, height: 668)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        Tests.hide(window)
        return window
    }

    private func close(_ window: NSWindow) async {
        window.contentViewController = nil
        window.orderOut(nil)
        await Task.yield()
    }

    // MARK: What was asked

    @Test func aDifferentAskIsNotTheSameAnswer() {
        let model = AppModel(home: URL(fileURLWithPath: "/nonexistent"), defaults: MemoryDefaults(suiteName: nil)!) { _ in }
        let answer = FigureAnswer.detail(week(12))
        model.remember(answer, for: FigureAsk(page: .cost, range: .week))
        #expect(model.remembered(FigureAsk(page: .cost, range: .week)) == answer)
        #expect(model.remembered(FigureAsk(page: .cost, range: .month)) == nil)
        #expect(model.remembered(FigureAsk(page: .tokens, range: .week)) == nil)
        #expect(model.remembered(FigureAsk(page: .cache, range: .week)) == nil)
        #expect(model.remembered(FigureAsk(page: .speed, range: .week, model: "claude-opus-5-5")) == nil)
        #expect(model.remembered(FigureAsk(page: .calendar, span: .week)) == nil)
    }

    @Test func rememberedFiguresStayWithinABound() {
        let model = AppModel(home: URL(fileURLWithPath: "/nonexistent"), defaults: MemoryDefaults(suiteName: nil)!) { _ in }
        let asks = (0..<30).map { FigureAsk(page: .cost, range: .day, model: "\($0)") }
        for (index, ask) in asks.enumerated() {
            model.remember(.detail(WindowSamples.figures(range: .day, usd: Double(index))), for: ask)
        }
        let kept = asks.filter { model.remembered($0) != nil }
        #expect(kept == Array(asks.suffix(12)))
    }

    // MARK: Invalidation

    @Test func aNewDayDropsRememberedFigures() {
        let model = AppModel(home: URL(fileURLWithPath: "/nonexistent"), defaults: MemoryDefaults(suiteName: nil)!) { _ in }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let ask = FigureAsk(page: .tokens, range: .week)
        model.remember(.detail(week(4)), for: ask, now: today, calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        #expect(model.remembered(ask, now: tomorrow, calendar: calendar) == nil)
        #expect(model.remembered(ask, now: today, calendar: calendar) == nil)
    }

    @Test func aPreferencesChangeDropsRememberedFigures() throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        let ask = FigureAsk(page: .cache, range: .week)
        model.remember(.detail(week(4)), for: ask)
        var changed = model.preferences
        changed.enabledSources = []
        model.save(changed)
        #expect(model.remembered(ask) == nil)
    }

    @Test func aRebuildDropsRememberedFigures() async throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        let ask = FigureAsk(page: .speed, range: .week)
        model.remember(.speed(SpeedFigures(range: .week)), for: ask)
        try await model.rebuildIndex()
        #expect(model.remembered(ask) == nil)
    }

    // MARK: A page

    @Test(arguments: [Page.tokens, .cache])
    func aRevisitShowsTheRememberedFiguresAndDoesNotWait(page: Page) async throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        model.remember(.detail(week(12)), for: FigureAsk(page: page, range: .week))
        let seen = Seen()
        let read: DetailRead = { _ in
            try await Task.sleep(for: .milliseconds(400))
            return self.week(99)
        }
        let view: AnyView = page == .tokens
            ? AnyView(RangePage(model: model, kind: .tokens, read: read))
            : AnyView(CachePage(model: model, read: read))
        let window = show(view.environment(\.figureHold, .seconds(5)), seen)
        #expect(await Tests.eventually { seen.asks.contains { $0.page == page && $0.range == "week" && $0.marker == "12" } })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!seen.notes.contains(.waiting))
        await close(window)
    }

    @Test func aNewRangeNeverShowsTheOldRangesFigures() async throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        model.remember(.detail(week(12)), for: FigureAsk(page: .cost, range: .week))
        let seen = Seen()
        let read: DetailRead = { range in
            try await Task.sleep(for: .milliseconds(80))
            return WindowSamples.figures(range: range, usd: 5)
        }
        let window = show(RangePage(model: model, kind: .cost, read: read).environment(\.figureHold, .seconds(5)), seen)
        #expect(await Tests.eventually { seen.asks.contains { $0.range == "month" && $0.marker == "5" } })
        #expect(seen.asks.allSatisfy { $0.range != "week" })
        await close(window)
    }

    @Test func aSlowFirstReadShowsThePlaceholder() async throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        let seen = Seen()
        let read: DetailRead = { range in
            // Stay out until the placeholder has been drawn. A loaded run can take a while to start the view's task,
            // and returning earlier would remove the placeholder before it appeared.
            let deadline = ContinuousClock.now.advanced(by: .seconds(25))
            while ContinuousClock.now < deadline, !seen.notes.contains(.waiting) {
                try await Task.sleep(for: .milliseconds(20))
            }
            return WindowSamples.figures(range: range, usd: 5)
        }
        let window = show(RangePage(model: model, kind: .cost, read: read).environment(\.figureHold, .milliseconds(20)), seen)
        #expect(await Tests.eventually(within: .seconds(30)) { seen.notes.contains(.waiting) })
        #expect(await Tests.eventually(within: .seconds(30)) {
            seen.asks.contains { $0.range == "month" && $0.marker == "5" } && seen.notes.last == PageNote.none
        })
        await close(window)
    }

    @Test func aFastFirstReadShowsNoPlaceholder() async throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        let seen = Seen()
        let read: DetailRead = { range in WindowSamples.figures(range: range, usd: 5) }
        let window = show(RangePage(model: model, kind: .cost, read: read).environment(\.figureHold, .seconds(5)), seen)
        #expect(await Tests.eventually { seen.asks.contains { $0.range == "month" && $0.marker == "5" } })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!seen.notes.contains(.waiting))
        await close(window)
    }

    @Test func aFailedRereadStillShowsTheProblem() async throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        model.remember(.detail(week(12)), for: FigureAsk(page: .tokens, range: .week))
        let seen = Seen()
        let read: DetailRead = { _ in throw ReadFailed() }
        let window = show(RangePage(model: model, kind: .tokens, read: read), seen)
        #expect(await Tests.eventually { seen.notes.contains(.problem) })
        await close(window)
    }

    @Test func thePlaceholderWaitsBeforeItShows() {
        #expect(PagePlaceholder.hold == .milliseconds(150))
        #expect(PagePlaceholder.shimmer(reduceMotion: true) == nil)
        #expect(PagePlaceholder.shimmer(reduceMotion: false) != nil)
    }

    // MARK: Warming

    @Test func aTickDoesNotWarmAndAClosedWindowDoesNot() async throws {
        let sandbox = try Sandbox()
        try sandbox.seed {
            $0.askedAboutSources = true
            $0.askedAboutAnthropicQuery = true
        }
        let model = model(sandbox)
        model.tick(WindowSamples.dashboard(), at: Date())
        try? await Task.sleep(for: .milliseconds(200))
        #expect(model.remembered(FigureAsk(page: .cost, range: .month)) == nil)
        #expect(model.activePolls == 0)
    }

    @Test func anOpenLiveWindowWarmsTheDefaultRangesOnce() async throws {
        let sandbox = try Sandbox()
        try sandbox.seed {
            $0.askedAboutSources = true
            $0.askedAboutAnthropicQuery = true
        }
        let model = model(sandbox)
        model.mainWindowVisible = true
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.remembered(FigureAsk(page: .cost, range: .month)) == nil)
        model.apply(WindowSamples.dashboard())
        let cost = FigureAsk(page: .cost, range: .month)
        let tokens = FigureAsk(page: .tokens, range: .week)
        let cache = FigureAsk(page: .cache, range: .week)
        let speed = FigureAsk(page: .speed, range: .week)
        #expect(await Tests.eventually {
            model.remembered(cost) != nil && model.remembered(tokens) != nil && model.remembered(cache) != nil && model.remembered(speed) != nil
        })
        #expect(model.activePolls == 0)
        var changed = model.preferences
        changed.enabledSources = []
        model.save(changed)
        #expect(model.remembered(cost) == nil)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(model.remembered(cost) == nil)
        #expect(model.remembered(tokens) == nil)
    }

    @Test func aLiveAppWarmsWhenTheWindowOpens() async throws {
        let sandbox = try Sandbox()
        try sandbox.seed {
            $0.askedAboutSources = true
            $0.askedAboutAnthropicQuery = true
        }
        let model = model(sandbox)
        model.apply(WindowSamples.dashboard())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.remembered(FigureAsk(page: .cost, range: .month)) == nil)
        model.mainWindowVisible = true
        #expect(await Tests.eventually { model.remembered(FigureAsk(page: .cost, range: .month)) != nil })
        #expect(model.activePolls == 0)
    }
}
