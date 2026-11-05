import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tacho
import TachoKit

/// Every page that shows figures from the dashboard.
private let pagesWithFigures = [Page.summary, .limits, .cost, .tokens, .speed]

/// The window's pages stay off the one-second tick. With Summary open, redrawing it every second was 1.5 of the 3.68 points the
/// real app measured, against a budget of 2. So these host the real page in a real window and count what a tick costs it: a pass
/// here is what a read of something that moves each second comes to, whichever view in the page does the reading.
@MainActor @Suite(.serialized)
struct PageRedrawTests {
    private final class CountingHost<Content: View>: NSHostingView<Content> {
        var passes = 0

        override func layout() {
            passes += 1
            super.layout()
        }
    }

    private static let quiet = WindowSamples.dashboard(
        quotas: [WindowSamples.projection(percent: 64)],
        sources: [WindowSamples.source(.codex, today: WindowSamples.tokens, usd: 1)],
        today: WindowSamples.tokens
    )

    /// Until the page has stopped laying out, for a second and more than one look. Not a fixed wait: in a loaded full run the end of the
    /// first layout came after one, and counted against the ticks. A page that never settles fails below, on what it did after this.
    private func settle(_ host: CountingHost<some View>) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        var last = host.passes
        var quietSince = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if host.passes != last {
                last = host.passes
                quietSince = .now
            } else if ContinuousClock.now - quietSince >= .milliseconds(1_300) {
                return
            }
        }
    }

    /// The real page in a real window, settled: then `act`, and how many passes that came to. A page reads the figures in its first
    /// body, before its first look, and that one read fires once whenever they next move. So they move here first.
    private func passes(
        on page: Page,
        from start: Dashboard = Self.quiet,
        menuBarBlocked: Bool = false,
        route: Route? = nil,
        limitRead: LimitRead? = nil,
        act: (AppModel, NSWindow) async -> Void
    ) async throws -> Int {
        let sandbox = try Sandbox()
        let model = AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in }
        model.page = page
        model.mainWindowVisible = true
        model.menuBarBlocked = menuBarBlocked
        model.tick(start, at: WindowSamples.now)
        if let route { model.open(route) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        Tests.hide(window)
        defer { window.orderOut(nil) }

        func run(_ host: CountingHost<some View>) async -> Int {
            window.contentView = host
            await settle(host)
            var warmer = start
            warmer.series = [WindowSamples.tokens]
            model.tick(warmer, at: WindowSamples.now)
            await settle(host)
            let settled = host.passes
            await act(model, window)
            return host.passes - settled
        }
        // The engine's figures name the range that was asked. A day kept under Month would be refused, and the page would stay empty.
        let read: DetailRead = { range in WindowSamples.figures(range: range) }
        return switch page {
        case .limits: await run(CountingHost(rootView: LimitsPage(model: model, read: limitRead)))
        case .cost: await run(CountingHost(rootView: RangePage(model: model, kind: .cost, read: read)))
        case .tokens: await run(CountingHost(rootView: RangePage(model: model, kind: .tokens, read: read)))
        case .speed: await run(CountingHost(rootView: SpeedPage(model: model, read: { range, _ in SpeedFigures(range: range) })))
        default: await run(CountingHost(rootView: SummaryPage(model: model)))
        }
    }

    /// Each is the figures, and how many seconds after `WindowSamples.now` they were read.
    private func passes(
        on page: Page,
        from start: Dashboard = Self.quiet,
        menuBarBlocked: Bool = false,
        ticks: [(Dashboard, TimeInterval)]
    ) async throws -> Int {
        try await passes(on: page, from: start, menuBarBlocked: menuBarBlocked) { model, _ in
            for (figures, seconds) in ticks {
                model.tick(figures, at: WindowSamples.now.addingTimeInterval(seconds))
                try? await Task.sleep(for: .milliseconds(150))
            }
            // Longer than a page takes to look at the figures, or nothing here could fail.
            try? await Task.sleep(for: .milliseconds(1_300))
        }
    }

    /// Within one minute of `WindowSamples.now`.
    private static let seconds: [TimeInterval] = [1, 2, 3, 4, 5]

    @Test(arguments: pagesWithFigures) func aTickWithNoChangeRedrawsNothing(page: Page) async throws {
        #expect(try await passes(on: page, ticks: Self.seconds.map { (Self.quiet, $0) }) == 0)
    }

    /// While a pace holds, a forecast's moment moves on with the clock, so no two ticks are equal. It was so on 56 of 100 real ticks.
    @Test(arguments: pagesWithFigures) func aForecastThatOnlySlidesRedrawsNothing(page: Page) async throws {
        func sliding(_ seconds: TimeInterval) -> Dashboard {
            var figures = Self.quiet
            figures.quotas = [WindowSamples.projection(
                percent: 64,
                outcome: .runsOut(at: WindowSamples.now + 4_200 + seconds, beforeReset: 5_100 - seconds)
            )]
            return figures
        }
        #expect(try await passes(on: page, from: sliding(0), ticks: Self.seconds.map { (sliding($0), $0) }) == 0)
    }

    /// An event entering or leaving a window moves all of this, and none of what the page draws. The words of the rate stay the same
    /// here: when they change, Summary's toolbar has them, in a pass of its own. See `SummaryFeedTests`.
    private static func moved(_ seconds: TimeInterval) -> Dashboard {
        var figures = quiet
        figures.isIdle = false
        figures.perMinute = 1_000
        figures.perSecond = 1_000.0 / 60
        figures.outputPerMinute = 1_000
        figures.lastMinute = TokenCounts(input: Int(seconds), output: 1_000, reasoning: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0)
        figures.series = [figures.lastMinute]
        figures.latestRequest = WindowSamples.now.addingTimeInterval(seconds)
        figures.sources[0].perMinute = Int(seconds)
        return figures
    }

    @Test(arguments: pagesWithFigures) func aRateThatMovesRedrawsNothing(page: Page) async throws {
        #expect(try await passes(on: page, from: Self.moved(0), ticks: Self.seconds.map { (Self.moved($0), $0) }) == 0)
    }

    /// Cost's Day draws the rate itself. The words stay the same here, so nothing should move.
    @Test func aRateThatMovesRedrawsNothingOnCostsDay() async throws {
        let count = try await passes(on: .cost, from: Self.moved(0), route: Route(page: .cost, range: .day)) { model, _ in
            for second in Self.seconds {
                model.tick(Self.moved(second), at: WindowSamples.now.addingTimeInterval(second))
                try? await Task.sleep(for: .milliseconds(150))
            }
            try? await Task.sleep(for: .milliseconds(1_300))
        }
        #expect(count == 0)
    }

    /// The control for the pages that take nothing else from the dashboard: older logs coming in changes what they say.
    @Test(arguments: [Page.cost, .tokens, .speed]) func theLogsFinishingIsDrawn(page: Page) async throws {
        var reading = Self.quiet
        reading.progress.phase = .history
        #expect(try await passes(on: page, from: reading, ticks: [(Self.quiet, 1)]) > 0)
    }

    /// Words that do change reach the page, in the stats' own view.
    @Test func aRateThatChangesItsWordsIsDrawnOnCostsDay() async throws {
        var faster = Self.moved(1)
        faster.costPerMinute = WindowSamples.usd(9)
        let count = try await passes(on: .cost, from: Self.moved(0), route: Route(page: .cost, range: .day)) { model, _ in
            model.tick(faster, at: WindowSamples.now.addingTimeInterval(1))
            try? await Task.sleep(for: .milliseconds(1_300))
        }
        #expect(count > 0)
    }

    /// With the menu bar blocked the page is the only place the rate can go.
    @Test func aPageThatShowsTheRateIsRedrawnForIt() async throws {
        var faster = Self.moved(1)
        faster.perMinute = 9_000
        faster.outputPerMinute = 9_000
        #expect(try await passes(on: .summary, from: Self.moved(0), menuBarBlocked: true, ticks: [(faster, 1)]) > 0)
    }

    /// A person's own change does not wait for the next look.
    @Test func aRateModePickedIsDrawnAtOnce() async throws {
        let count = try await passes(on: .summary) { model, _ in
            model.setRateMode(.cost)
            try? await Task.sleep(for: .milliseconds(200))
        }
        #expect(count > 0)
    }

    /// While the window is hidden nothing looks. It must not come back showing what it left, which may be figures that have since failed.
    @Test func aWindowComingBackIsUpToDateAtOnce() async throws {
        let quotas = [WindowSamples.projection(percent: 64), WindowSamples.projection(window: .weekly, percent: 41)]
        var both = Self.quiet
        both.quotas = quotas
        var onlyWeekly = Self.quiet
        onlyWeekly.quotas = [quotas[1]]
        let weekly = Labels.limitName(quotas[1].snapshot)
        var subtitles: [String] = []
        _ = try await passes(on: .limits, from: both) { model, window in
            model.mainWindowVisible = false
            model.tick(onlyWeekly, at: WindowSamples.now.addingTimeInterval(1))
            try? await Task.sleep(for: .milliseconds(1_300))
            subtitles.append(window.subtitle)
            model.mainWindowVisible = true
            try? await Task.sleep(for: .milliseconds(150))
            subtitles.append(window.subtitle)
        }
        #expect(subtitles.first != weekly)
        #expect(subtitles.last == weekly)
    }

    /// Summary's subtitle says the time.
    @Test func summaryComingBackIsUpToDateAtOnce() async throws {
        var subtitles: [String] = []
        _ = try await passes(on: .summary) { model, window in
            model.mainWindowVisible = false
            model.tick(Self.quiet, at: WindowSamples.now.addingTimeInterval(120))
            try? await Task.sleep(for: .milliseconds(1_300))
            subtitles.append(window.subtitle)
            model.mainWindowVisible = true
            try? await Task.sleep(for: .milliseconds(150))
            subtitles.append(window.subtitle)
        }
        #expect(subtitles.count == 2)
        #expect(subtitles.first != subtitles.last)
    }

    /// Cost's Day says the rate now, and a look at it stops with the window. By what is drawn, as the stats redraw on their own.
    @Test func costsRateComingBackIsUpToDateAtOnce() async throws {
        var faster = Self.moved(1)
        faster.costPerMinute = WindowSamples.usd(9)
        var pictures: [Data?] = []
        _ = try await passes(on: .cost, from: Self.moved(0), route: Route(page: .cost, range: .day)) { model, window in
            model.mainWindowVisible = false
            model.tick(faster, at: WindowSamples.now.addingTimeInterval(1))
            try? await Task.sleep(for: .milliseconds(1_300))
            pictures.append(window.contentView.flatMap(Self.picture))
            model.mainWindowVisible = true
            try? await Task.sleep(for: .milliseconds(150))
            pictures.append(window.contentView.flatMap(Self.picture))
        }
        #expect(pictures.first != nil)
        #expect(pictures.first != pictures.last)
    }

    /// Old figures must not stay on the page: Summary's feed has the same test.
    @Test func losingTheFiguresEmptiesLimits() async throws {
        var subtitle: String?
        _ = try await passes(on: .limits) { model, window in
            model.tickFailed(at: WindowSamples.now.addingTimeInterval(1))
            try? await Task.sleep(for: .milliseconds(1_300))
            subtitle = window.subtitle
        }
        #expect(subtitle == "")
    }

    private final class Reads {
        var asked: [LimitKey] = []
        var release = false
    }

    private static let record = LimitHistory(
        readings: [.init(time: WindowSamples.now - 1_000, percent: 50)],
        windows: (0..<6).map { .init(resetsAt: WindowSamples.now - Double(6 - $0) * 18_000, peak: 40) }
    )

    /// What the page looks like, as a pass says only that something moved.
    private static func picture(of view: NSView) -> Data? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.tiffRepresentation
    }

    /// A read is news, and nothing else will move the page: a look finds nothing new in the model. This holds one back until the page has
    /// gone quiet. By what is drawn: `record` is in the first body, so a pass comes either way.
    @Test func aRecordIsDrawnAsItArrives() async throws {
        let reads = Reads()
        let read: LimitRead = { _ in
            while !reads.release { try? await Task.sleep(for: .milliseconds(20)) }
            return Self.record
        }
        var pictures: [Data?] = []
        _ = try await passes(on: .limits, limitRead: read) { _, window in
            pictures.append(window.contentView.flatMap(Self.picture))
            reads.release = true
            try? await Task.sleep(for: .milliseconds(300))
            pictures.append(window.contentView.flatMap(Self.picture))
        }
        #expect(pictures.first != nil)
        #expect(pictures.first != pictures.last)
    }

    /// With the figures gone there was no knowing which limit to read for, and a read that read for another would hold it until the
    /// next minute. The page reads again when what it is about moves.
    @Test func aPickedLimitGetsItsRecordWhenTheFiguresComeBack() async throws {
        let quotas = [WindowSamples.projection(percent: 64), WindowSamples.projection(window: .weekly, percent: 41)]
        var both = Self.quiet
        both.quotas = quotas
        let reads = Reads()
        let read: LimitRead = { snapshot in
            reads.asked.append(LimitKey(snapshot))
            return Self.record
        }
        let weekly = LimitKey(quotas[1].snapshot)
        _ = try await passes(on: .limits, from: both, route: Route(page: .limits, limit: weekly), limitRead: read) { model, _ in
            model.tickFailed(at: WindowSamples.now.addingTimeInterval(1))
            try? await Task.sleep(for: .milliseconds(1_300))
            reads.asked = []
            model.tick(both, at: WindowSamples.now.addingTimeInterval(2))
            try? await Task.sleep(for: .milliseconds(1_300))
        }
        #expect(reads.asked.contains(weekly))
    }

    /// By what is drawn, not by a pass: `selected` is in the body, so a click makes one either way. The subtitle comes from the state.
    @Test func aLimitPickedIsDrawnAtOnce() async throws {
        let quotas = [WindowSamples.projection(percent: 64), WindowSamples.projection(window: .weekly, percent: 41)]
        var figures = Self.quiet
        figures.quotas = quotas
        let weekly = Labels.limitName(quotas[1].snapshot)
        var subtitles: [String] = []
        _ = try await passes(on: .limits, from: figures) { model, window in
            subtitles.append(window.subtitle)
            model.open(Route(page: .limits, limit: LimitKey(quotas[1].snapshot)))
            try? await Task.sleep(for: .milliseconds(150))
            subtitles.append(window.subtitle)
        }
        #expect(subtitles.first != weekly)
        #expect(subtitles.last == weekly)
    }

    /// The control: nothing above could pass by a page that is never redrawn.
    @Test(arguments: [Page.summary, .limits]) func aNewFigureIsDrawn(page: Page) async throws {
        var changed = Self.quiet
        changed.today.cost = WindowSamples.usd(12.5)
        changed.quotas = [WindowSamples.projection(percent: 71)]
        #expect(try await passes(on: page, ticks: [(changed, 1)]) > 0)
    }

    @Test(arguments: [Page.summary, .limits]) func theNextMinuteIsDrawn(page: Page) async throws {
        #expect(try await passes(on: page, ticks: [(Self.quiet, 60)]) > 0)
    }
}
