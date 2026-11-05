import Foundation
import Testing
@testable import Tacho
import TachoKit

/// What the Cache page says: spec section 12.4.
struct CacheStateTests {
    @Test func itSaysTheRateWhatItKeptAndWhatItCost() {
        let state = CacheState(figures: WindowSamples.figures(range: .week))
        #expect(state.stats.map(\.label) == ["Hit rate", "Kept off the bill", "Paid to write the cache"])
        #expect(state.stats[1].value == "about $864")
        #expect(state.stats[2].value == "$25.00")
    }

    @Test func nothingPricedReadsNoPriceAndNeverNothing() {
        var figures = WindowSamples.figures(range: .week, usd: 0)
        figures.cacheSaving = CostSummary(usd: 0, unpricedModels: ["some-model"], unpricedTokens: 500)
        let state = CacheState(figures: figures)
        #expect(state.stats[1].value == "no price")
        #expect(state.stats[2].value == "no price")
    }

    @Test func aColumnWithNoPromptTokensKeepsItsPlaceWithNothingToPlot() throws {
        // Dropped, it took its axis label with it: a quiet month lost nearly all its dates.
        var figures = WindowSamples.figures(range: .month, columns: 30)
        figures.columns[9].tokens = .zero
        let trend = try #require(CacheState(figures: figures).trend)
        #expect(trend.count == 30)
        #expect(trend[9].hitRate == nil)
        #expect(trend[9].axis != nil)
    }

    @Test func aMonthsAxisNamesEveryWeekNotEveryDay() throws {
        let trend = try #require(CacheState(figures: WindowSamples.figures(range: .month, columns: 30)).trend)
        #expect(trend.count == 30)
        #expect(trend.compactMap(\.axis).count == 4)
        #expect(trend[0].axis == nil)
    }

    @Test func theSameRangeIsCountedTwoWays() throws {
        let ways = try #require(CacheState(figures: WindowSamples.figures(range: .week)).twoWays)
        #expect(ways.legend.first?.text == "Cache read: 97% of tokens, 46% of cost")
        #expect(ways.byTokens.count == 4)
        #expect(ways.byCost.count == 4)
    }

    @Test func aCLIWithNoPromptTokensIsNotGivenARate() {
        let used = BreakdownRow(key: "Claude Code", tokens: WindowSamples.tokens, cost: WindowSamples.usd(10))
        let unused = BreakdownRow(key: "Codex", tokens: .zero, cost: .zero)
        let state = CacheState(figures: WindowSamples.figures(range: .week, bySource: [used, unused]))
        #expect(state.byCLI.map(\.name) == ["Claude Code"])
    }

    @Test func itSaysRulesKInTheEnginesOrder() {
        var figures = WindowSamples.figures(range: .week)
        figures.highlights = DetailHighlights(cache: [.k2(rate: 97.8), .k3(tokensPercent: 97, costPercent: 46)])
        #expect(CacheState(figures: figures).highlights == ["Your hit rate held near 97.8% this week.", "Cache reads are 97% of your tokens but 46% of your cost."])
    }

    @Test func aRangeWithNothingInItKeepsWhatTheEngineSays() {
        var figures = WindowSamples.figures(range: .week, tokens: .zero)
        figures.highlights = DetailHighlights(cache: [.k2(rate: 97.8)])
        #expect(CacheState(figures: figures).highlights == ["Your hit rate held near 97.8% this week."])
    }

    @Test func aRangeWithNothingInItSaysSo() {
        let state = CacheState(figures: WindowSamples.figures(range: .week, tokens: .zero))
        #expect(state.isEmpty)
        #expect(state.stats.isEmpty)
    }
}
