import Foundation
import Testing
@testable import TachoKit

/// Rules D, T, K and LH of `docs/design/direction-b-spec.md`, sections 12.2 to 12.5, each at its boundaries.
struct DetailHighlightsTests {
    // MARK: Fixtures

    private let start = date("2026-11-01T00:00:00Z")

    private func priced(_ usd: Double) -> CostSummary {
        CostSummary(usd: usd, unpricedModels: [], unpricedTokens: 0)
    }

    private func column(_ usd: Double, tokens: Int? = nil) -> DetailColumn {
        DetailColumn(start: start, tokens: TokenCounts(input: tokens ?? (usd > 0 ? 100 : 0)), cost: priced(usd))
    }

    private func totals(
        _ usd: Double,
        tokens: TokenCounts = TokenCounts(input: 100, output: 100),
        byCategory: CategoryCost = .zero,
        unpriced: Int = 0,
        requests: Int = 10,
        subagent: Int = 0,
        days: Int = 7
    ) -> PeriodTotals {
        PeriodTotals(
            tokens: tokens,
            cost: CostSummary(usd: usd, unpricedModels: unpriced > 0 ? ["m"] : [], unpricedTokens: unpriced),
            costByCategory: byCategory,
            requests: requests,
            subagentRequests: subagent,
            daysWithUse: days
        )
    }

    /// A range with a full previous period.
    private func compared(_ range: DetailRange, _ usd: Double, before: Double) -> DetailFigures {
        DetailFigures(range: range, totals: totals(usd), previous: totals(before), previousIsFull: true)
    }

    private func costRules(_ figures: DetailFigures, phase: IngestProgress.Phase = .live) -> [CostHighlight] {
        Insights.highlights(of: figures, phase: phase).cost
    }

    private func tokenRules(_ figures: DetailFigures) -> [TokenHighlight] {
        Insights.highlights(of: figures, phase: .live).tokens
    }

    private func cacheRules(_ figures: DetailFigures) -> [CacheHighlight] {
        Insights.highlights(of: figures, phase: .live).cache
    }

    // MARK: Phases

    /// A page's figures are still arriving, and a partly read baseline gives wildly wrong figures.
    @Test(arguments: [IngestProgress.Phase.idle, .recent, .history])
    func onlyD1SpeaksBeforeLive(phase: IngestProgress.Phase) {
        var figures = compared(.day, 100, before: 1)
        figures.totals.tokens = TokenCounts(input: 100, cacheRead: 100)
        figures.totals.costByCategory = CategoryCost(input: 90, cacheRead: 10)
        let highlights = Insights.highlights(of: figures, phase: phase)
        #expect(highlights == DetailHighlights(cost: [.d1]))
    }

    @Test(arguments: [IngestProgress.Phase.idle, .recent, .history])
    func nothingElseSpeaksBeforeLiveOnAnyOtherRange(phase: IngestProgress.Phase) {
        for range in [DetailRange.month, .year] {
            #expect(Insights.highlights(of: compared(range, 100, before: 1), phase: phase) == DetailHighlights())
        }
    }

    @Test(arguments: [IngestProgress.Phase.idle, .recent, .history])
    func theWeekSaysW6BeforeLive(phase: IngestProgress.Phase) {
        let highlights = Insights.highlights(of: compared(.week, 100, before: 1), phase: phase)
        #expect(highlights == DetailHighlights(weekOutput: .w6, weekTokens: .w6))
    }

    // MARK: D1, D2

    @Test func d1IsAlwaysFirstOnDay() {
        #expect(costRules(DetailFigures(range: .day)) == [.d1])
    }

    private func day(_ costs: [Double], current: Int?) -> DetailFigures {
        let columns = costs.map { column($0) }
        return DetailFigures(range: .day, columns: columns, totals: totals(costs.reduce(0, +)), currentColumn: current)
    }

    @Test func d2WhenTheCurrentHourCostsTheMost() {
        #expect(costRules(day([1, 5, 9], current: 2)) == [.d1, .d2(cost: priced(9))])
    }

    @Test func d2NeedsTheCurrentHourToLead() {
        #expect(costRules(day([9, 5, 1], current: 2)) == [.d1])
        #expect(costRules(day([9, 5, 9], current: 2)) == [.d1])
    }

    @Test func d2NeedsTwoHoursWithUse() {
        #expect(costRules(day([0, 0, 9], current: 2)) == [.d1])
    }

    @Test func d2CountsAnHourWithAnEventOfNoTokens() {
        var figures = day([0, 0, 9], current: 2)
        figures.columns[0].hasUse = true
        #expect(costRules(figures) == [.d1, .d2(cost: priced(9))])
    }

    @Test func d2NeedsToKnowTheHour() {
        #expect(costRules(day([1, 5, 9], current: nil)) == [.d1])
        #expect(costRules(day([1, 5, 9], current: 3)) == [.d1])
    }

    /// The tolerance is for D3 to D12: this one names a figure for one hour.
    @Test func d2IsLeftOutWithSomeOfTheDayUnpriced() {
        var figures = day([1, 5, 9], current: 2)
        figures.totals.cost.unpricedTokens = 1
        #expect(costRules(figures) == [.d1])
    }

    // MARK: D3, K3, K4

    private func withCache(unpriced: Int = 0, reads: Int = 900, writes: Int = 0) -> DetailFigures {
        DetailFigures(
            range: .year,
            totals: totals(
                100,
                tokens: TokenCounts(input: 100, cacheRead: reads, cacheWrite5m: writes),
                byCategory: CategoryCost(input: 50, cacheRead: 40, cacheWrite: 10),
                unpriced: unpriced
            )
        )
    }

    @Test func d3GivesCacheReadsAsSharesOfTokensAndOfCost() {
        #expect(costRules(withCache()).first == .d3(tokensPercent: 90, costPercent: 40))
    }

    /// 20 of these 1,000 tokens is 2%, where a period stops counting as known.
    @Test func d3AndK3AreLeftOutWhenCostIsNotKnown() {
        #expect(costRules(withCache(unpriced: 20)).allSatisfy { if case .d3 = $0 { false } else { true } })
        #expect(cacheRules(withCache(unpriced: 20)) == [])
    }

    @Test func d3AndK3SpeakJustUnderTheTolerance() {
        #expect(costRules(withCache(unpriced: 19)).first == .d3(tokensPercent: 90, costPercent: 40))
        #expect(cacheRules(withCache(unpriced: 19)) == [.k3(tokensPercent: 90, costPercent: 40)])
    }

    @Test func d3NeedsCacheReads() {
        #expect(costRules(withCache(reads: 0)).allSatisfy { if case .d3 = $0 { false } else { true } })
    }

    @Test func k3GivesTheSameShares() {
        #expect(cacheRules(withCache()) == [.k3(tokensPercent: 90, costPercent: 40)])
    }

    @Test func k4WithCacheWrites() {
        let rules = cacheRules(withCache(reads: 800, writes: 100))
        #expect(rules == [.k3(tokensPercent: 80, costPercent: 40), .k4(usd: 10, tokensPercent: 10, costPercent: 10)])
    }

    /// 1,100 tokens here, so 2% is 22.
    @Test func k4IsLeftOutWhenCostIsNotKnown() {
        #expect(cacheRules(withCache(unpriced: 22, writes: 100)) == [])
    }

    @Test func k4SpeaksJustUnderTheTolerance() {
        #expect(cacheRules(withCache(unpriced: 21, writes: 100)).contains(.k4(usd: 10, tokensPercent: 9, costPercent: 10)))
    }

    /// A model priced at nothing: writes of no cost are no share of a bill of none.
    @Test func k4NeedsACost() {
        var figures = withCache(writes: 100)
        figures.totals.cost.usd = 0
        #expect(cacheRules(figures) == [])
    }

    @Test func k3AndK4AreLeftOutWithNothingPriced() {
        var figures = withCache(writes: 100)
        figures.totals.cost = CostSummary(usd: 0, unpricedModels: ["m"], unpricedTokens: 1_100)
        #expect(cacheRules(figures) == [])
    }

    // MARK: D4 to D6, D9 to D11

    @Test func d4AtFivePercentUp() {
        #expect(costRules(compared(.week, 105, before: 100)).contains(.d4(percent: 5)))
    }

    @Test func d5AtFivePercentDown() {
        #expect(costRules(compared(.week, 95, before: 100)).contains(.d5(percent: 5)))
    }

    @Test func d6WithinFivePercent() {
        #expect(costRules(compared(.week, 104.4, before: 100)).contains(.d6))
        #expect(costRules(compared(.week, 95.6, before: 100)).contains(.d6))
    }

    @Test func theLineFallsOnTheRoundedPercent() {
        #expect(costRules(compared(.week, 104.5, before: 100)).contains(.d4(percent: 5)))
    }

    @Test func d9ToD11TakeTheMonth() {
        #expect(costRules(compared(.month, 105, before: 100)).contains(.d9(percent: 5)))
        #expect(costRules(compared(.month, 95, before: 100)).contains(.d10(percent: 5)))
        #expect(costRules(compared(.month, 100, before: 100)).contains(.d11))
    }

    /// Some use is not 100% down, as in H7.
    @Test func d5StopsAtNinetyNineWithAnyCost() {
        #expect(costRules(compared(.week, 0.001, before: 1_000)).contains(.d5(percent: 99)))
    }

    @Test func d5SaysAllOfItWithNoCost() {
        #expect(costRules(compared(.week, 0, before: 1_000)).contains(.d5(percent: 100)))
    }

    private func isComparison(_ rule: CostHighlight) -> Bool {
        switch rule {
        case .d4, .d5, .d6, .d9, .d10, .d11: true
        default: false
        }
    }

    @Test(arguments: [DetailRange.week, .month])
    func thereIsNoComparisonWithoutAFullPreviousPeriod(range: DetailRange) {
        var figures = compared(range, 100, before: 100)
        figures.previousIsFull = false
        #expect(!costRules(figures).contains(where: isComparison))
    }

    @Test(arguments: [DetailRange.week, .month])
    func thereIsNoComparisonWithoutAPreviousPeriod(range: DetailRange) {
        var figures = compared(range, 100, before: 100)
        figures.previous = nil
        #expect(!costRules(figures).contains(where: isComparison))
    }

    @Test func thereIsNoComparisonWithNothingBefore() {
        #expect(!costRules(compared(.week, 100, before: 0)).contains(where: isComparison))
    }

    /// 4 of these 200 tokens is 2%: past that a lower bound cannot support a comparison, in either period.
    @Test func thereIsNoComparisonPastTheToleranceInEitherPeriod() {
        var now = compared(.week, 100, before: 50)
        now.totals.cost.unpricedTokens = 4
        #expect(!costRules(now).contains(where: isComparison))
        var before = compared(.week, 100, before: 50)
        before.previous?.cost.unpricedTokens = 4
        #expect(!costRules(before).contains(where: isComparison))
    }

    /// A local model will never have a price, and its sliver must not silence the page for good.
    @Test func aSliverOfUnpricedTokensDoesNotStopAComparison() {
        var figures = compared(.week, 100, before: 50)
        figures.totals.cost.unpricedTokens = 3
        figures.previous?.cost.unpricedTokens = 3
        #expect(costRules(figures).contains(.d4(percent: 100)))
    }

    /// Nothing at all is no lower bound: a week of no use really is 100% down.
    @Test func aPeriodOfNoTokensCountsAsKnown() {
        var figures = compared(.week, 0, before: 100)
        figures.totals.tokens = .zero
        #expect(costRules(figures).contains(.d5(percent: 100)))
    }

    /// Exactly on the line, in the units the rule is written in.
    @Test func theToleranceIsTwoPercentOfTokens() {
        #expect(Insights.unpricedTolerance == 0.02)
        let tokens = TokenCounts(input: 10_000)
        #expect(Insights.isCostKnown(totals(1, tokens: tokens, unpriced: 199)))
        #expect(!Insights.isCostKnown(totals(1, tokens: tokens, unpriced: 200)))
        #expect(Insights.isCostKnown(totals(1, tokens: tokens, unpriced: 0)))
    }

    // MARK: D7, D8

    private func week(_ costs: [Double]) -> DetailFigures {
        DetailFigures(range: .week, columns: costs.map { column($0) }, totals: totals(costs.reduce(0, +)))
    }

    @Test func d7WhenTheTopTwoDaysHoldHalf() {
        #expect(costRules(week([30, 20, 10, 10, 10, 10, 10])) == [.d7(days: 2, percent: 50)])
    }

    /// Summed in another order, `totals` can differ from the columns in the last place.
    @Test func d7SaysAllOfItEvenWhenTotalsDifferInTheLastPlace() {
        var figures = week([0.1, 0.2, 0, 0, 0, 0, 0])
        figures.totals.cost.usd = 0.30000000000000010
        #expect(costRules(figures) == [.d7(days: 2, percent: 100)])
    }

    @Test func d7NotUnderHalf() {
        #expect(costRules(week([29, 20, 11, 10, 10, 10, 10])) == [])
    }

    @Test func d7WithOneDay() {
        #expect(costRules(week([0, 0, 40, 0, 0, 0, 0])) == [.d7(days: 1, percent: 100)])
    }

    @Test func d7IsLeftOutWhenCostIsNotKnown() {
        var figures = week([30, 20, 10, 10, 10, 10, 10])
        figures.totals.cost.unpricedTokens = 4
        #expect(costRules(figures) == [])
    }

    @Test func d7SpeaksJustUnderTheTolerance() {
        var figures = week([30, 20, 10, 10, 10, 10, 10])
        figures.totals.cost.unpricedTokens = 3
        #expect(costRules(figures) == [.d7(days: 2, percent: 50)])
    }

    @Test func d7IsLeftOutWithNoCost() {
        #expect(costRules(week([0, 0, 0, 0, 0, 0, 0])) == [])
    }

    /// Today is under way, so it is not one of the days that carried the week, though what it has cost so far is part of the week.
    @Test func d7LeavesOutTheDayUnderWay() {
        var figures = week([0, 0, 0, 0, 0, 40, 10])
        figures.currentColumn = 6
        #expect(costRules(figures) == [.d7(days: 1, percent: 80)])
    }

    private func outputShare(_ now: Double, before: Double) -> DetailFigures {
        var figures = compared(.week, 100, before: 100)
        figures.totals.costByCategory = CategoryCost(input: 100 - now, output: now)
        figures.previous?.costByCategory = CategoryCost(input: 100 - before, output: before)
        return figures
    }

    @Test func d8AtThreePoints() {
        #expect(costRules(outputShare(43, before: 40)).contains(.d8(fromPercent: 40, toPercent: 43)))
        #expect(costRules(outputShare(37, before: 40)).contains(.d8(fromPercent: 40, toPercent: 37)))
    }

    /// The sentence prints rounded shares, so those are what must differ by 3.
    @Test func d8ReadsTheFiguresItPrints() {
        #expect(costRules(outputShare(42, before: 40)).allSatisfy { if case .d8 = $0 { false } else { true } })
        #expect(costRules(outputShare(42.6, before: 40.4)).contains(.d8(fromPercent: 40, toPercent: 43)))
    }

    @Test func d8IsLeftOutPastTheTolerance() {
        var figures = outputShare(50, before: 40)
        figures.previous?.cost.unpricedTokens = 4
        #expect(costRules(figures).allSatisfy { if case .d8 = $0 { false } else { true } })
    }

    @Test func d8NeedsAFullPreviousPeriod() {
        var figures = outputShare(50, before: 40)
        figures.previousIsFull = false
        #expect(costRules(figures).allSatisfy { if case .d8 = $0 { false } else { true } })
    }

    // MARK: D12, D13

    private func month(_ costs: [Double], usual: UsualRange? = UsualRange(p25: 10, median: 20, p75: 30)) -> DetailFigures {
        DetailFigures(
            range: .month,
            columns: costs.map { column($0) },
            totals: totals(costs.reduce(0, +)),
            usualCost: UsualBands(daily: usual)
        )
    }

    @Test func d12CountsTheDaysAboveTheRange() {
        #expect(costRules(month([31, 30.01, 30])).contains(.d12(days: 2)))
    }

    @Test func d12NeedsOneDayAboveIt() {
        #expect(!costRules(month([30, 20, 10])).contains { if case .d12 = $0 { true } else { false } })
    }

    /// 4 of these 200 tokens is 2%: a day of models left out is a lower bound, so it may be above the range unseen.
    @Test func d12IsLeftOutWhenCostIsNotKnown() {
        var figures = month([99, 99])
        figures.columns[0].cost.unpricedTokens = 4
        #expect(!costRules(figures).contains { if case .d12 = $0 { true } else { false } })
    }

    @Test func d12SpeaksJustUnderTheTolerance() {
        var figures = month([99, 99])
        figures.columns[0].cost.unpricedTokens = 3
        #expect(costRules(figures).contains(.d12(days: 2)))
    }

    /// A day so far is not what it will be, so today is neither above the range nor inside it yet.
    @Test func d12LeavesOutTheDayUnderWay() {
        var figures = month([31, 20, 99])
        figures.currentColumn = 2
        #expect(costRules(figures).contains(.d12(days: 1)))
    }

    /// Its tolerance is of the days it counts, so a local model used today does not silence it.
    @Test func d12GoesByTheUnpricedTokensOfItsDays() {
        var figures = month([99, 99])
        figures.currentColumn = 1
        figures.columns[1].cost.unpricedTokens = 100
        figures.totals.cost.unpricedTokens = 100
        #expect(costRules(figures).contains(.d12(days: 1)))
    }

    @Test func d12NeedsARange() {
        #expect(!costRules(month([99, 99, 99], usual: nil)).contains { if case .d12 = $0 { true } else { false } })
    }

    /// A day with an event of no tokens is a day of use: section 8.1 asks for one event.
    @Test func d13LeavesOutADayWithAnEventOfNoTokens() {
        var figures = month([20, 0, 0])
        figures.columns[1].hasUse = true
        #expect(costRules(figures).contains(.d13(days: 1)))
    }

    @Test func d13CountsTheDaysWithNoUse() {
        #expect(costRules(month([20, 0, 0])).contains(.d13(days: 2)))
        #expect(!costRules(month([20, 20, 20])).contains { if case .d13 = $0 { true } else { false } })
    }

    /// Today is under way: nothing in it yet does not make it a day with no use.
    @Test func d13LeavesOutTheDayUnderWay() {
        var figures = month([20, 0, 0])
        figures.currentColumn = 2
        #expect(costRules(figures).contains(.d13(days: 1)))
    }

    @Test func aDayOfUnpricedTokensIsADayWithUse() {
        var figures = month([20, 20])
        figures.columns[1] = DetailColumn(start: start, tokens: TokenCounts(input: 5), cost: CostSummary(usd: 0, unpricedModels: ["m"], unpricedTokens: 5))
        #expect(!costRules(figures).contains { if case .d13 = $0 { true } else { false } })
    }

    // MARK: D14, D15

    private func year(_ columns: [DetailColumn], days: Int = 40) -> DetailFigures {
        DetailFigures(range: .year, columns: columns, totals: totals(10, days: days))
    }

    @Test func d14NamesTheBusiestMonthAndD15TheDays() {
        let busiest = DetailColumn(start: date("2026-06-01T00:00:00Z"), tokens: TokenCounts(input: 5), cost: priced(90))
        #expect(costRules(year([column(10), busiest, column(30)])) == [.d14(month: busiest.start, cost: priced(90)), .d15(days: 40)])
    }

    @Test func d14CarriesWhatItLeftOut() {
        let partly = CostSummary(usd: 90, unpricedModels: ["m"], unpricedTokens: 7)
        let busiest = DetailColumn(start: start, tokens: TokenCounts(input: 5), cost: partly)
        #expect(costRules(year([busiest])).first == .d14(month: start, cost: partly))
    }

    /// No figure for a model with no price.
    @Test func d14IsLeftOutWithNothingPriced() {
        let unpriced = DetailColumn(start: start, tokens: TokenCounts(input: 5), cost: CostSummary(usd: 0, unpricedModels: ["m"], unpricedTokens: 5))
        #expect(costRules(year([unpriced])) == [.d15(days: 40)])
    }

    @Test func nothingIsSaidOfAnEmptyYear() {
        #expect(costRules(DetailFigures(range: .year)) == [])
    }

    // MARK: First three

    @Test func theCostPageSaysAtMostThreeInOrder() {
        var figures = compared(.month, 105, before: 100)
        figures.columns = [column(99), column(0)]
        figures.usualCost = UsualBands(daily: UsualRange(p25: 10, median: 20, p75: 30))
        figures.totals.tokens = TokenCounts(input: 100, cacheRead: 100)
        figures.totals.costByCategory = CategoryCost(input: 100, cacheRead: 5)
        #expect(costRules(figures) == [.d3(tokensPercent: 50, costPercent: 5), .d9(percent: 5), .d12(days: 1)])
    }

    // MARK: T1, T2

    private func row(_ key: String, output: Int, reasoning: Int) -> BreakdownRow {
        BreakdownRow(key: key, tokens: TokenCounts(output: output, reasoning: reasoning), cost: .zero)
    }

    @Test func t1IsOfTheSourcesThatRecordThinkingOnly() {
        let figures = DetailFigures(
            range: .week,
            totals: totals(10, requests: 0),
            bySource: [row("a", output: 100, reasoning: 25), row("b", output: 900, reasoning: 0)]
        )
        #expect(tokenRules(figures) == [.t1(percent: 25)])
    }

    @Test func t1NeedsThinking() {
        let figures = DetailFigures(range: .week, totals: totals(10, requests: 0), bySource: [row("a", output: 100, reasoning: 0)])
        #expect(tokenRules(figures) == [])
    }

    @Test func t2GivesSubagentsShareOfRequests() {
        #expect(tokenRules(DetailFigures(range: .day, totals: totals(10, requests: 200, subagent: 76))) == [.t2(percent: 38)])
    }

    @Test func t2SaysNoneOfThem() {
        #expect(tokenRules(DetailFigures(range: .day, totals: totals(10, requests: 200, subagent: 0))) == [.t2(percent: 0)])
    }

    @Test func t2NeedsRequests() {
        #expect(tokenRules(DetailFigures(range: .day, totals: totals(10, requests: 0))) == [])
    }

    // MARK: K1, K2

    private func hitRate(_ now: Int, before: Int, full: Bool = true) -> DetailFigures {
        DetailFigures(
            range: .week,
            totals: totals(0, tokens: TokenCounts(input: 1_000 - now, cacheRead: now)),
            previous: totals(0, tokens: TokenCounts(input: 1_000 - before, cacheRead: before)),
            previousIsFull: full
        )
    }

    @Test func k1AtHalfAPoint() {
        #expect(cacheRules(hitRate(905, before: 900)) == [.k1(from: 90, to: 90.5)])
        #expect(cacheRules(hitRate(895, before: 900)) == [.k1(from: 90, to: 89.5)])
    }

    @Test func k2UnderHalfAPoint() {
        #expect(cacheRules(hitRate(904, before: 900)) == [.k2(rate: 90.4)])
    }

    @Test func k1AndK2NeedAFullPreviousPeriod() {
        #expect(cacheRules(hitRate(905, before: 900, full: false)) == [])
    }

    @Test func k1AndK2AreForTheWeek() {
        var figures = hitRate(905, before: 900)
        figures.range = .month
        #expect(cacheRules(figures) == [])
    }

    @Test func k1AndK2NeedPromptTokensInBoth() {
        var figures = hitRate(905, before: 900)
        figures.previous?.tokens = .zero
        #expect(cacheRules(figures) == [])
    }

    // MARK: Rules W on a page

    @Test func theWeekComparesBothMetrics() {
        var figures = DetailFigures(
            range: .week,
            totals: totals(0, tokens: TokenCounts(input: 1_000, output: 105)),
            previous: totals(0, tokens: TokenCounts(input: 1_000, output: 100)),
            daysOfUse: 14
        )
        figures.previousIsFull = true
        let highlights = Insights.highlights(of: figures, phase: .live)
        #expect(highlights.weekOutput == .w1(percent: 5))
        #expect(highlights.weekTokens == .w3)
    }

    @Test func theWeekNeedsFourteenDaysOfUse() {
        let figures = DetailFigures(range: .week, totals: totals(0), previous: totals(0), daysOfUse: 13)
        #expect(Insights.highlights(of: figures, phase: .live).weekOutput == .w4(soFar: 13))
    }

    @Test func noOtherRangeHasRulesW() {
        for range in [DetailRange.day, .month, .year] {
            let highlights = Insights.highlights(of: DetailFigures(range: range, daysOfUse: 14), phase: .live)
            #expect(highlights.weekOutput == nil)
            #expect(highlights.weekTokens == nil)
        }
    }

    // MARK: Rules LH

    /// `resetsAt` is the forecast's reset, later than the snapshot's once that has passed.
    private func limit(
        _ percent: Double = 50,
        method: Projection.Method = .calibrated,
        recent: Double? = nil,
        window: Double? = nil,
        hasRecentData: Bool = true,
        resetsAt: Date? = nil
    ) -> Projection {
        let snapshot = QuotaSnapshot(
            provider: .anthropic, window: .weekly, usedPercent: percent, resetsAt: start, observedAt: start.addingTimeInterval(-600), origin: .claudeCache
        )
        return Projection(
            snapshot: snapshot, estimatedPercent: percent, isEstimate: false, method: method, outcome: .lastsUntilReset, isStale: false,
            resetsAt: resetsAt ?? start, hasRecentData: hasRecentData, recentPercentPerHour: recent, windowPercentPerHour: window
        )
    }

    private func windows(_ peaks: [Double], current: Double? = 10) -> LimitHistory {
        var windows = peaks.enumerated().map { LimitHistory.Window(resetsAt: start.addingTimeInterval(-604_800 * Double(peaks.count - $0.offset)), peak: $0.element) }
        if let current { windows.append(LimitHistory.Window(resetsAt: start, peak: current)) }
        return LimitHistory(windows: windows)
    }

    @Test func lh1AtOnePointOneTimesTheAverage() {
        #expect(windows([]).highlights(for: limit(recent: 1.1, window: 1)) == [.lh1(recent: 1.1, average: 1)])
        #expect(windows([]).highlights(for: limit(recent: 1.09, window: 1)) == [])
    }

    @Test func lh2AtPointNineTimesTheAverage() {
        #expect(windows([]).highlights(for: limit(recent: 0.9, window: 1)) == [.lh2(recent: 0.9, average: 1)])
        #expect(windows([]).highlights(for: limit(recent: 0.91, window: 1)) == [])
    }

    /// A weekly pace can be 0.3% an hour.
    @Test func pacesTakeOneDecimal() {
        #expect(windows([]).highlights(for: limit(recent: 0.34, window: 0.24)) == [.lh1(recent: 0.3, average: 0.2)])
        #expect(windows([]).highlights(for: limit(recent: 0.24, window: 0.34)) == [.lh2(recent: 0.2, average: 0.3)])
    }

    /// `0.3% against 0.3%` cannot read as running ahead, or as slowing.
    @Test func pacesThatPrintTheSameSayNothing() {
        #expect(windows([]).highlights(for: limit(recent: 0.34, window: 0.26)) == [])
        #expect(windows([]).highlights(for: limit(recent: 0.26, window: 0.34)) == [])
    }

    @Test func lh1AndLH2NeedACalibratedForecast() {
        #expect(windows([]).highlights(for: limit(method: .windowAverage, recent: 5, window: 1)) == [])
    }

    @Test func lh1AndLH2NeedBothPacesAboveZero() {
        #expect(windows([]).highlights(for: limit(recent: 0, window: 1)) == [])
        #expect(windows([]).highlights(for: limit(recent: 1, window: 0)) == [])
        #expect(windows([]).highlights(for: limit(recent: nil, window: 1)) == [])
        #expect(windows([]).highlights(for: limit(recent: 1, window: nil)) == [])
    }

    @Test func lh3NeedsFiveWindowsBeforeThisOne() {
        #expect(windows([60, 70, 80, 90, 100]).highlights(for: limit(10)) == [.lh3(medianPercent: 80)])
        #expect(windows([60, 70, 80, 90]).highlights(for: limit(10)) == [])
    }

    /// This window has not reached its peak: it is what is being compared with the others.
    @Test func lh3LeavesOutThisWindow() {
        #expect(windows([60, 70, 80, 90], current: 100).highlights(for: limit(10)) == [])
        #expect(windows([60, 70, 80, 90, 100], current: 5).highlights(for: limit(10)) == [.lh3(medianPercent: 80)])
    }

    /// No snapshot since the last reset: the window the snapshot was in has finished, so it is one of the peaks, and this window is the
    /// one the forecast's reset ends.
    @Test func aWindowWithNoSnapshotSinceItsResetHasFinished() {
        let history = windows([60, 70, 80, 90], current: 100)
        let nextReset = start.addingTimeInterval(604_800)
        #expect(history.highlights(for: limit(95, resetsAt: nextReset)) == [.lh3(medianPercent: 80), .lh4])
        #expect(history.highlights(for: limit(10, resetsAt: nextReset)) == [.lh3(medianPercent: 80)])
    }

    @Test func aWindowWithin60SecondsIsThisOne() {
        var history = windows([60, 70, 80, 90, 100], current: nil)
        history.windows.append(LimitHistory.Window(resetsAt: start.addingTimeInterval(59), peak: 5))
        #expect(history.highlights(for: limit(10)) == [.lh3(medianPercent: 80)])
    }

    /// Older windows may still arrive, so the median and the line above it are of part of the record.
    @Test func lh3AndLH4WaitForTheWholeRecord() {
        var history = windows([60, 70, 80, 90, 100])
        history.isFullyRead = false
        #expect(history.highlights(for: limit(99)) == [])
    }

    /// The pace comes from the limit, not the record.
    @Test func thePaceSpeaksWhileTheRecordIsRead() {
        var history = windows([60, 70, 80, 90, 100])
        history.isFullyRead = false
        #expect(history.highlights(for: limit(recent: 2, window: 1)) == [.lh1(recent: 2, average: 1)])
    }

    @Test func lh4AboveTheP75OfThosePeaks() {
        let history = windows([60, 70, 80, 90, 100])
        #expect(history.highlights(for: limit(90.1)) == [.lh3(medianPercent: 80), .lh4])
        #expect(history.highlights(for: limit(90)) == [.lh3(medianPercent: 80)])
    }

    @Test func aLimitWithNoRecentDataIsNotPastAnything() {
        let history = windows([60, 70, 80, 90, 100])
        #expect(history.highlights(for: limit(99, recent: 5, window: 1, hasRecentData: false)) == [.lh3(medianPercent: 80)])
    }

    @Test func noWindowsNoPaceNoHighlights() {
        #expect(LimitHistory().highlights(for: limit()) == [])
    }
}
