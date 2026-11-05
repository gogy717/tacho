import Foundation
import SwiftUI
import Testing
@testable import Tacho
import TachoKit

/// Cost and Tokens stacked by model or CLI: what the page draws from the engine's series, and what it keeps.
@MainActor
struct ChartGroupingTests {
    private let band = UsualBands(
        hourly: (0..<24).map { UsualRange(p25: Double($0), median: Double($0) + 1, p75: Double($0) + 2) },
        daily: UsualRange(p25: 20, median: 40, p75: 70)
    )

    private func series(_ key: String, input: Int = 0, output: Int = 0, usd: Double = 0) -> DetailSeries {
        let tokens = TokenCounts(input: input, output: output)
        return DetailSeries(key: key, tokens: [.zero, tokens], cost: [.zero, CostSummary(usd: usd, unpricedModels: [], unpricedTokens: 0)])
    }

    private func figures(_ series: [DetailSeries], grouping: DetailGrouping? = .model, range: DetailRange = .week) -> DetailFigures {
        var figures = WindowSamples.figures(range: range, columns: 2, bands: band)
        figures.series = series
        figures.grouping = grouping
        return figures
    }

    private func state(_ figures: DetailFigures, kind: RangePage.Kind = .tokens, metric: TokensMetric = .allTokens, grouping: DetailGrouping? = .model, colours: LayerColours = LayerColours()) -> RangeState {
        RangeState(figures: figures, kind: kind, metric: metric, grouping: grouping, colours: colours)
    }

    private var six: [DetailSeries] {
        [("a", 6), ("b", 5), ("c", 4), ("d", 3), ("e", 2), ("f", 1)].map { series($0.0, input: $0.1 * 100) }
    }

    // MARK: The chart

    @Test func typeStaysTodaysChart() {
        let chart = state(figures(six, grouping: nil), grouping: nil).chart
        #expect(chart?.layers.map(\.name) == Theme.stackOrder.map(\.name))
        #expect(chart?.usual != nil)
    }

    @Test func aGroupingStacksItsLayersTheLargestAtTheBottom() {
        let chart = state(figures(six)).chart
        #expect(chart?.layers.map(\.name) == ["a", "b", "c", "d", "e", String(localized: "chart.other", bundle: .tacho)])
        #expect(chart?.columns.map(\.values) == [[0, 0, 0, 0, 0, 0], [600, 500, 400, 300, 200, 100]])
    }

    @Test func otherIsGrey() {
        #expect(state(figures(six)).chart?.layers.last?.color == Theme.seriesOther)
    }

    /// The band is a range of the page's total, with a meaning only for what the Type view draws.
    @Test(arguments: [DetailRange.day, .week, .month])
    func theBandBelongsToTheTypeView(range: DetailRange) {
        let chart = state(figures(six, range: range)).chart
        #expect(chart?.usual == nil)
        #expect(chart?.columns.allSatisfy { $0.usual == nil } == true)
    }

    @Test func eachPageRanksByWhatItDraws() {
        let figures = figures([series("dear", input: 1, usd: 30), series("bulk", input: 900, output: 1, usd: 9), series("talker", output: 500, usd: 1)])
        #expect(state(figures, kind: .cost).chart?.layers.map(\.name) == ["dear", "bulk", "talker"])
        #expect(state(figures, metric: .allTokens).chart?.layers.map(\.name) == ["bulk", "talker", "dear"])
        #expect(state(figures, metric: .output).chart?.layers.map(\.name) == ["talker", "bulk"])
    }

    @Test func aModelIsNamedAsTheListsNameIt() {
        #expect(state(figures([series("", input: 1)])).chart?.layers.first?.name == Labels.model(""))
    }

    /// The read for a new choice has not come back, and these figures are the last one's.
    @Test func figuresOfAnotherGroupingAreNotDrawnUnderThisOne() {
        let chart = state(figures(six, grouping: .source), grouping: .model).chart
        #expect(chart?.layers.map(\.name) == Theme.stackOrder.map(\.name))
    }

    /// The note comes from the totals, so the grouping can neither lose it nor change it.
    @Test func theNoteStillNamesWhatHasNoPrice() {
        var unpriced = figures([series("a", input: 1, usd: 5)])
        unpriced.totals.cost = CostSummary(usd: 5, unpricedModels: ["mystery"], unpricedTokens: 100)
        #expect(state(unpriced, kind: .cost).note?.contains("mystery") == true)
        #expect(state(unpriced, kind: .cost).note == state(unpriced, kind: .cost, grouping: nil).note)
    }

    @Test func aGroupingKeepsTheListsAndTheStats() {
        let figures = figures(six)
        let grouped = state(figures), plain = state(figures, grouping: nil)
        #expect(grouped.stats == plain.stats)
        #expect(grouped.bySource == plain.bySource)
        #expect(grouped.byModel == plain.byModel)
    }

    // MARK: Colours

    private func colour(_ state: RangeState, _ name: String) -> Color? {
        state.chart?.layers.first { $0.name == name }?.color
    }

    @Test func aColourFollowsTheModelAndNotItsPlace() {
        let colours = LayerColours()
        let first = state(figures([series("a", input: 9), series("b", input: 1)]), colours: colours)
        let second = state(figures([series("a", input: 1), series("b", input: 9)]), colours: colours)
        #expect(first.chart?.layers.map(\.name) == ["a", "b"])
        #expect(second.chart?.layers.map(\.name) == ["b", "a"])
        #expect(colour(first, "a") == colour(second, "a"))
        #expect(colour(first, "b") == colour(second, "b"))
    }

    @Test func noTwoLayersShareAColour() {
        let colours = LayerColours()
        let slots = colours.slots(for: ["a", "b", "c", "d", "e"])
        #expect(Set(slots.values).count == 5)
        #expect(Set(slots.values) == Set(0..<5))
    }

    @Test func theLargestTakeTheFirstColours() {
        #expect(LayerColours().slots(for: ["a", "b"]) == ["a": 0, "b": 1])
    }

    @Test func aModelThatLeavesAChartAndComesBackKeepsItsColour() {
        let colours = LayerColours()
        let before = colours.slots(for: ["a", "b", "c"])
        _ = colours.slots(for: ["b", "c", "d"])
        #expect(colours.slots(for: ["a", "b"])["a"] == before["a"])
    }

    @Test func whenNoneIsFreeTheLongestGoneGivesItsColourUp() {
        let colours = LayerColours()
        let first = colours.slots(for: ["a", "b", "c", "d", "e"])
        _ = colours.slots(for: ["b", "c", "d", "e"])
        let slots = colours.slots(for: ["b", "c", "d", "e", "new"])
        #expect(slots["new"] == first["a"])
        for key in ["b", "c", "d", "e"] { #expect(slots[key] == first[key]) }
    }

    @Test func askingAgainChangesNothing() {
        let colours = LayerColours()
        let keys = ["a", "b", "c"]
        #expect(colours.slots(for: keys) == colours.slots(for: keys))
    }

    // MARK: The session

    @Test func eachPageKeepsItsOwnChoice() {
        let session = ChartSession()
        #expect(session.grouping(on: .cost) == nil)
        session.setGrouping(.model, on: .cost)
        session.setGrouping(.source, on: .tokens)
        #expect(session.grouping(on: .cost) == .model)
        #expect(session.grouping(on: .tokens) == .source)
        session.setGrouping(nil, on: .cost)
        #expect(session.grouping(on: .cost) == nil)
        #expect(session.grouping(on: .tokens) == .source)
    }

    @Test func bothPagesShareAModelsColour() {
        let session = ChartSession()
        let slots = session.colours(for: .model).slots(for: ["a", "b"])
        #expect(session.colours(for: .model).slots(for: ["b"])["b"] == slots["b"])
    }

    @Test func modelsAndCLIsKeepTheirOwnColours() {
        let session = ChartSession()
        _ = session.colours(for: .model).slots(for: ["a", "b"])
        #expect(session.colours(for: .source).slots(for: ["Codex"]) == ["Codex": 0])
    }

    // MARK: The cache

    @Test func aGroupingIsAnotherAsk() {
        #expect(FigureAsk(page: .cost, range: .week, grouping: .model) != FigureAsk(page: .cost, range: .week))
        #expect(FigureAsk(page: .cost, range: .week, grouping: .model) != FigureAsk(page: .cost, range: .week, grouping: .source))
        #expect(FigureAsk(page: .cost, range: .week, grouping: .model) == FigureAsk(page: .cost, range: .week, grouping: .model))
    }

    // MARK: By model

    private var rows: [FigureRow] {
        (1...8).map { FigureRow(name: "model \($0)", figure: "\($0)") }
    }

    @Test func aListOpensOnItsTopFive() {
        #expect(FigureList.visible(rows, shown: 5, isExpanded: false).count == 5)
    }

    @Test func expandedItHoldsEveryRow() {
        #expect(FigureList.visible(rows, shown: 5, isExpanded: true).map(\.name) == rows.map(\.name))
    }
}
