import Foundation
import Observation
import Testing
@testable import Tacho
import TachoKit

/// What a look at the figures moves on. The page must hear only of what it draws, and the toolbar only of the rate's words.
@MainActor
struct SummaryFeedTests {
    private final class Flag: @unchecked Sendable {
        var isSet = false
    }

    private let preferences = Preferences.defaults(home: URL(fileURLWithPath: "/nonexistent"))

    private func figures(perMinute: Int = 1_000, usd: Double = 1, series: [TokenCounts] = []) -> Dashboard {
        var figures = WindowSamples.dashboard(usd: usd)
        figures.isIdle = false
        figures.perMinute = perMinute
        figures.outputPerMinute = perMinute
        figures.series = series
        return figures
    }

    private func state(_ figures: Dashboard, menuBarBlocked: Bool = false, now: Date = WindowSamples.now) -> SummaryState {
        SummaryState(dashboard: figures, insights: nil, day: nil, week: .loading, preferences: preferences, menuBarBlocked: menuBarBlocked, now: now)
    }

    /// Whether `change` tells anything reading what `read` reads.
    private func tells(_ read: @escaping () -> Void, by change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking(read) { flag.isSet = true }
        change()
        return flag.isSet
    }

    @Test func theFirstLookDrawsThePage() {
        let feed = SummaryFeed()
        let first = state(figures())
        feed.take(first)
        #expect(feed.drawn == first)
        #expect(feed.rate?.headline == first.rate.headline)
    }

    @Test func aLookThatFindsNothingNewTellsNoOne() {
        let feed = SummaryFeed()
        feed.take(state(figures()))
        #expect(!tells({ _ = feed.drawn; _ = feed.rate }, by: { feed.take(state(figures())) }))
    }

    @Test func aRateThatMovesReachesTheToolbarAlone() {
        let feed = SummaryFeed()
        feed.take(state(figures()))
        #expect(!tells({ _ = feed.drawn }, by: { feed.take(state(figures(perMinute: 9_000))) }))
        #expect(feed.rate?.headline == state(figures(perMinute: 9_000)).rate.headline)
    }

    @Test func aRateThatMovesTellsTheToolbar() {
        let feed = SummaryFeed()
        feed.take(state(figures()))
        #expect(tells({ _ = feed.rate }, by: { feed.take(state(figures(perMinute: 9_000))) }))
    }

    /// The toolbar's words are the same, and an update to it costs as much as one to the page.
    @Test func aChartThatMovesAloneLeavesTheToolbar() {
        let feed = SummaryFeed()
        feed.take(state(figures()))
        let moved = figures(series: [WindowSamples.tokens])
        #expect(!tells({ _ = feed.rate }, by: { feed.take(state(moved)) }))
    }

    /// As with the chart: what a minute leaves out is shown only under the pointer, and the toolbar has no chart.
    @Test func aMinuteLeftUnpricedAloneLeavesTheToolbar() {
        var inCost = preferences
        inCost.rateMode = .cost
        func state(_ figures: Dashboard) -> SummaryState {
            SummaryState(dashboard: figures, insights: nil, day: nil, week: .loading, preferences: inCost, menuBarBlocked: false, now: WindowSamples.now)
        }
        var moved = figures()
        moved.costSeries = [CategoryCost(unpricedTokens: 500)]
        let feed = SummaryFeed()
        feed.take(state(figures()))
        #expect(!tells({ _ = feed.rate }, by: { feed.take(state(moved)) }))
    }

    @Test func aPageThatShowsTheRateFollowsIt() {
        let feed = SummaryFeed()
        feed.take(state(figures(), menuBarBlocked: true))
        let faster = state(figures(perMinute: 9_000), menuBarBlocked: true)
        feed.take(faster)
        #expect(feed.drawn == faster)
    }

    /// It draws the chart too, so a chart moving alone is a change to it.
    @Test func aPageThatShowsTheRateFollowsItsChart() {
        let feed = SummaryFeed()
        feed.take(state(figures(), menuBarBlocked: true))
        let moved = state(figures(series: [WindowSamples.tokens]), menuBarBlocked: true)
        feed.take(moved)
        #expect(feed.drawn == moved)
    }

    @Test func aChangeThePageShowsMovesIt() {
        let feed = SummaryFeed()
        feed.take(state(figures()))
        let later = state(figures(usd: 2))
        feed.take(later)
        #expect(feed.drawn == later)
    }

    /// The subtitle says the time.
    @Test func theNextMinuteMovesThePage() {
        let feed = SummaryFeed()
        feed.take(state(figures()))
        let later = state(figures(), now: WindowSamples.now.addingTimeInterval(60))
        feed.take(later)
        #expect(feed.drawn == later)
    }

    /// Old figures must not stay on the page.
    @Test func losingTheFiguresEmptiesThePage() {
        let feed = SummaryFeed()
        feed.take(state(figures()))
        feed.take(nil)
        #expect(feed.drawn == nil)
        #expect(feed.rate == nil)
    }

    @Test func theFiguresComingBackFillIt() {
        let feed = SummaryFeed()
        feed.take(state(figures()))
        feed.take(nil)
        let back = state(figures())
        feed.take(back)
        #expect(feed.drawn == back)
    }
}
