import Foundation
import TachoKit
import Testing

/// What the pages read, on a plain import: `ReportsTests` and `DetailHighlightsTests` import for testing, so they would pass with any of this internal,
/// and the app would not build.
struct PageSurfaceTests {
    private let start = date("2026-11-01T00:00:00Z")

    private var limit: Projection {
        let snapshot = QuotaSnapshot(
            provider: .anthropic, window: .weekly, usedPercent: 100, resetsAt: start, observedAt: start.addingTimeInterval(-600), origin: .claudeCache
        )
        return Projection(
            snapshot: snapshot, estimatedPercent: 100, isEstimate: false, method: .calibrated, outcome: .lastsUntilReset, isStale: false, resetsAt: start,
            hasRecentData: true, recentPercentPerHour: 2, windowPercentPerHour: 1
        )
    }

    @Test func theFiguresShowTheirRulesAndMedian() {
        let highlights = DetailHighlights(
            cost: [.d1, .d4(percent: 5), .d14(month: start, cost: .zero)],
            tokens: [.t1(percent: 1), .t2(percent: 2)],
            cache: [.k1(from: 90, to: 91), .k2(rate: 90), .k3(tokensPercent: 1, costPercent: 2), .k4(usd: 1, tokensPercent: 1, costPercent: 2)],
            weekOutput: .w3,
            weekTokens: .w1(percent: 5)
        )
        let figures = DetailFigures(range: .week, medianCost: 2, previousIsFull: true, currentColumn: 3, highlights: highlights)
        #expect(figures.medianCost == 2)
        #expect(figures.previousIsFull)
        #expect(figures.currentColumn == 3)
        #expect(figures.highlights.cost.count == 3)
        #expect(figures.highlights.tokens.count == 2)
        #expect(figures.highlights.cache.count == 4)
        #expect(figures.highlights.weekOutput == .w3)
        #expect(figures.highlights.weekTokens == .w1(percent: 5))
    }

    @Test func aColumnAndARecordSayWhatTheyHold() {
        #expect(DetailColumn(start: start, hasUse: true).hasUse)
        #expect(LimitHistory(isFullyRead: false).isFullyRead == false)
    }

    @Test func aLimitsRecordGivesItsRules() {
        #expect(LimitHistory().highlights(for: limit) == [LimitHighlight.lh1(recent: 2, average: 1)])
    }

    @Test func thePageCanAskWhetherALimitIsUsedUp() {
        #expect(Insights.isUsedUp(limit))
    }
}
