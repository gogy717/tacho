import Foundation
import Testing
@testable import Tacho
import TachoKit

/// What the Cost and Tokens pages say, from the engine's figures: spec sections 12.1 to 12.3.
struct RangeStateTests {
    private func row(_ key: String, tokens: Int, usd: Double, unpriced: Int = 0) -> BreakdownRow {
        BreakdownRow(
            key: key,
            tokens: TokenCounts(input: 0, output: tokens, reasoning: 0, cacheRead: 0, cacheWrite5m: 0),
            cost: CostSummary(usd: usd, unpricedModels: unpriced > 0 ? ["some-model"] : [], unpricedTokens: unpriced)
        )
    }

    private func labels(_ state: RangeState) -> [String] {
        state.stats.map(\.label)
    }

    private let band = UsualBands(
        hourly: (0..<24).map { UsualRange(p25: Double($0), median: Double($0) + 1, p75: Double($0) + 2) },
        daily: UsualRange(p25: 20, median: 40, p75: 70),
        now: UsualRange(p25: 41, median: 60, p75: 84)
    )

    @Test func costListsGoLargestFirstWithWhatHasNoPriceLast() {
        // The engine sorts by tokens, which is not the order of a list of money.
        let figures = WindowSamples.figures(range: .month, bySource: [
            row("Many tokens, no price", tokens: 900, usd: 0, unpriced: 900),
            row("Middle", tokens: 500, usd: 10),
            row("Top", tokens: 100, usd: 20),
        ])
        let state = RangeState(figures: figures, kind: .cost, metric: .allTokens)
        #expect(state.bySource.map(\.name) == ["Top", "Middle", "Many tokens, no price"])
        #expect(state.bySource.map(\.fraction) == [1, 0.5, 0])
    }

    @Test func anUnpricedRowNeverReadsNothing() {
        let figures = WindowSamples.figures(range: .month, byModel: [row("some-model", tokens: 900, usd: 0, unpriced: 900)])
        #expect(RangeState(figures: figures, kind: .cost, metric: .allTokens).byModel.first?.figure == "no price")
    }

    @Test func tokenListsKeepTheEnginesOrder() {
        let figures = WindowSamples.figures(range: .week, bySource: [row("Big", tokens: 900, usd: 1), row("Small", tokens: 100, usd: 9)])
        let state = RangeState(figures: figures, kind: .tokens, metric: .allTokens)
        #expect(state.bySource.map(\.name) == ["Big", "Small"])
        #expect(state.bySource.first?.figure == "900")
    }

    @Test func aCLIWithOneClientListsNone() {
        let row = row("Codex", tokens: 100, usd: 1)
        let one = WindowSamples.figures(range: .week, bySource: [row], clients: ["Codex": [row]])
        let two = WindowSamples.figures(range: .week, bySource: [row], clients: ["Codex": [row, row]])
        #expect(RangeState(figures: one, kind: .cost, metric: .allTokens).bySource.first?.clients.isEmpty == true)
        #expect(RangeState(figures: two, kind: .cost, metric: .allTokens).bySource.first?.clients.count == 2)
    }

    @Test func aRangeWithNothingInItSaysSoAndListsNothing() {
        let figures = WindowSamples.figures(range: .week, tokens: .zero, bySource: [row("Codex", tokens: 0, usd: 0)])
        let state = RangeState(figures: figures, kind: .cost, metric: .allTokens)
        #expect(state.isEmpty)
        #expect(state.chart == nil)
        #expect(state.bySource.isEmpty)
    }

    @Test func aRangeWithNothingInItKeepsWhatTheEngineSays() {
        var day = WindowSamples.figures(range: .day, tokens: .zero, columns: 24)
        day.highlights = DetailHighlights(cost: [.d1])
        let state = RangeState(figures: day, kind: .cost, metric: .allTokens, today: .h3)
        #expect(state.isEmpty)
        #expect(state.highlights == ["Nothing yet today."])
        var week = WindowSamples.figures(range: .week, tokens: .zero)
        week.highlights = DetailHighlights(weekOutput: .w6)
        #expect(RangeState(figures: week, kind: .tokens, metric: .output).highlights == ["Still reading your logs. This comparison may follow."])
    }

    @Test func costsClientsGoLargestFirstLikeTheirCLI() {
        let top = row("Claude Code", tokens: 900, usd: 90)
        let clients = [row("cli", tokens: 800, usd: 10), row("claude-desktop", tokens: 100, usd: 80)]
        let figures = WindowSamples.figures(range: .week, bySource: [top], clients: ["Claude Code": clients])
        #expect(RangeState(figures: figures, kind: .cost, metric: .allTokens).bySource.first?.clients.map(\.figure) == ["$80.00", "$10.00"])
        #expect(RangeState(figures: figures, kind: .tokens, metric: .allTokens).bySource.first?.clients.map(\.figure) == ["800", "100"])
    }

    @Test func costsDaySaysTheRateNow() {
        let figures = WindowSamples.figures(range: .day, columns: 24, bands: band)
        let state = RangeState(figures: figures, kind: .cost, metric: .allTokens, rate: "$1.20/min")
        #expect(labels(state) == ["Today", "Now", "Usual range"])
        #expect(state.stats[1].value == "$1.20/min")
        #expect(state.stats[2].value == "$41.00 to $84.00")
    }

    @Test func aWeekSaysItsUsualRangeByTheDay() {
        let state = RangeState(figures: WindowSamples.figures(range: .week, bands: band), kind: .cost, metric: .allTokens, rate: "$1.20/min")
        #expect(labels(state) == ["Last 7 days", "Usual range"])
        #expect(state.stats[1].value == "$20.00 to $70.00 a day")
    }

    @Test func aYearHasNoUsualRange() {
        #expect(labels(RangeState(figures: WindowSamples.figures(range: .year, columns: 12), kind: .cost, metric: .allTokens)) == ["Last 12 months"])
    }

    private func usedToday(_ range: DetailRange, daysOfUse: Int, usedColumn: Int, currentColumn: Int) -> DetailFigures {
        var figures = WindowSamples.figures(range: range, tokens: .zero, columns: range == .day ? 24 : 7, daysOfUse: daysOfUse)
        figures.totals.tokens = WindowSamples.tokens
        for index in figures.columns.indices { figures.columns[index].hasUse = index == usedColumn }
        figures.currentColumn = currentColumn
        return figures
    }

    /// As the panel has it: today counts once it has use, so that a card and the page beside it agree.
    @Test func todayCountsOnceItHasUse() {
        let week = usedToday(.week, daysOfUse: 0, usedColumn: 6, currentColumn: 6)
        #expect(RangeState(figures: week, kind: .cost, metric: .allTokens).stats.last?.value == "needs 6 more days of use")
    }

    @Test func aDayWithNoUseYetDoesNotCount() {
        let week = usedToday(.week, daysOfUse: 0, usedColumn: 5, currentColumn: 6)
        #expect(RangeState(figures: week, kind: .cost, metric: .allTokens).stats.last?.value == "needs 7 more days of use")
    }

    /// Day's columns are hours: the one under way can be empty on a day with use.
    @Test func onDayAnyHourOfTodayCounts() {
        let day = usedToday(.day, daysOfUse: 2, usedColumn: 3, currentColumn: 10)
        #expect(day.todayHasUse)
        #expect(RangeState(figures: day, kind: .tokens, metric: .allTokens).stats.last?.value == "needs 4 more days of use")
    }

    /// Today is under way, so the last day is still one more.
    @Test func itNeverAsksForNoDays() {
        let week = usedToday(.week, daysOfUse: 6, usedColumn: 6, currentColumn: 6)
        #expect(RangeState(figures: week, kind: .cost, metric: .allTokens).stats.last?.value == "needs 1 more day of use")
    }

    @Test func aYearHasNoDayInIt() {
        #expect(!usedToday(.year, daysOfUse: 2, usedColumn: 3, currentColumn: 3).todayHasUse)
    }

    @Test func underSevenDaysItSaysHowManyAreLeft() {
        let few = WindowSamples.figures(range: .week, daysOfUse: 4)
        #expect(RangeState(figures: few, kind: .cost, metric: .allTokens).stats.last?.value == "needs 3 more days of use")
        let almost = WindowSamples.figures(range: .week, daysOfUse: 6)
        #expect(RangeState(figures: almost, kind: .cost, metric: .allTokens).stats.last?.value == "needs 1 more day of use")
    }

    @Test func whileOlderLogsAreComingNoDayIsCalledMissing() {
        let few = WindowSamples.figures(range: .week, daysOfUse: 4)
        #expect(RangeState(figures: few, kind: .cost, metric: .allTokens, isReading: true).stats.last?.value == "still reading logs")
    }

    @Test func tokensSwapsItsFirstTwoFiguresWithTheMetric() {
        let figures = WindowSamples.figures(range: .week)
        let all = RangeState(figures: figures, kind: .tokens, metric: .allTokens)
        let output = RangeState(figures: figures, kind: .tokens, metric: .output)
        #expect(all.stats[0].value == "100k")
        #expect(all.stats[1].label == "Output")
        #expect(output.stats[0].value == "1.0k")
        #expect(output.stats[1].label == "All tokens")
    }

    @Test func outputIsOneLayerAndEverythingElseFour() {
        let figures = WindowSamples.figures(range: .week)
        #expect(RangeState(figures: figures, kind: .tokens, metric: .output).chart?.layers.map(\.name) == [TokenCategory.output.name])
        #expect(RangeState(figures: figures, kind: .tokens, metric: .allTokens).chart?.layers.map(\.name) == Theme.stackOrder.map(\.name))
        #expect(RangeState(figures: figures, kind: .cost, metric: .output).chart?.layers.map(\.name) == Theme.stackOrder.map(\.name))
    }

    @Test func aDaysBandIsPerHourAWeeksIsOneAndAYearHasNone() throws {
        let day = try #require(RangeState(figures: WindowSamples.figures(range: .day, columns: 24, bands: band), kind: .cost, metric: .allTokens).chart)
        #expect(day.usual == nil)
        #expect(day.columns[3].usual == 3...5)
        let week = try #require(RangeState(figures: WindowSamples.figures(range: .week, bands: band), kind: .cost, metric: .allTokens).chart)
        #expect(week.usual == 20...70)
        #expect(week.columns[3].usual == nil)
        let year = try #require(RangeState(figures: WindowSamples.figures(range: .year, columns: 12, bands: band), kind: .cost, metric: .allTokens).chart)
        #expect(year.usual == nil)
        #expect(year.columns[3].usual == nil)
    }

    @Test func thinkingShowsOnlyWhereItIsRecordedAndUnderOutput() throws {
        var tokens = WindowSamples.tokens
        #expect(RangeState(figures: WindowSamples.figures(range: .week, tokens: tokens), kind: .tokens, metric: .allTokens).byTypeRows[1].clients.isEmpty)
        tokens.reasoning = 300
        let rows = RangeState(figures: WindowSamples.figures(range: .week, tokens: tokens), kind: .tokens, metric: .allTokens).byTypeRows
        #expect(rows.map(\.name) == ["Input", "Output", "Cache read", "Cache write, 5 min", "Cache write, 1 h"])
        #expect(rows[1].clients.map(\.name) == ["of which thinking"])
    }

    @Test func tokensSaysRulesWOnTheMetricShownThenRulesT() {
        var figures = WindowSamples.figures(range: .week)
        figures.highlights = DetailHighlights(tokens: [.t2(percent: 38)], weekOutput: .w1(percent: 20), weekTokens: .w2(percent: 8))
        #expect(RangeState(figures: figures, kind: .tokens, metric: .output).highlights == ["20% up on last week.", "Sub-agents made 38% of requests."])
        #expect(RangeState(figures: figures, kind: .tokens, metric: .allTokens).highlights == ["8% down on last week.", "Sub-agents made 38% of requests."])
    }

    @Test func costSaysRulesDInTheEnginesOrder() {
        var figures = WindowSamples.figures(range: .month)
        figures.highlights = DetailHighlights(cost: [.d9(percent: 12), .d13(days: 3)])
        #expect(RangeState(figures: figures, kind: .cost, metric: .allTokens).highlights == ["12% up on the previous 30 days.", "3 days had no use."])
    }

    @Test func aMedianIsTheEnginesAndNamedByItsRange() {
        var week = WindowSamples.figures(range: .week)
        week.medianCost = 41.8
        #expect(labels(RangeState(figures: week, kind: .cost, metric: .allTokens)) == ["Last 7 days", "Median day", "Usual range"])
        var year = WindowSamples.figures(range: .year, columns: 12)
        year.medianCost = 410
        let state = RangeState(figures: year, kind: .cost, metric: .allTokens)
        #expect(labels(state) == ["Last 12 months", "Median month"])
        #expect(state.stats[1].value == "$410")
    }

    @Test func withNoMedianTheStatIsLeftOut() {
        #expect(labels(RangeState(figures: WindowSamples.figures(range: .week), kind: .cost, metric: .allTokens)) == ["Last 7 days", "Usual range"])
    }

    @Test func ruleD1IsTheSentenceFromCostToday() {
        var day = WindowSamples.figures(range: .day, columns: 24)
        day.highlights = DetailHighlights(cost: [.d1])
        #expect(RangeState(figures: day, kind: .cost, metric: .allTokens, today: .h5(percent: 30)).highlights == ["30% above your usual by this time of day."])
        // With no answer yet there is no sentence to repeat.
        #expect(RangeState(figures: day, kind: .cost, metric: .allTokens).highlights.isEmpty)
    }

    @Test func costByTypeNamesEachShareBesideItsColour() {
        let state = RangeState(figures: WindowSamples.figures(range: .week), kind: .cost, metric: .allTokens)
        #expect(state.byType.count == 4)
        #expect(state.byTypeLegend.map(\.text) == ["Cache read 46%", "Cache write 25%", "Output 28%", "Input 1%"])
    }
}
