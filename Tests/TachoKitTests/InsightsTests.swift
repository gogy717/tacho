import Foundation
import Testing
@testable import TachoKit

/// The rules of `docs/design/direction-b-spec.md`, sections 8 and 11, each at its boundaries.
struct InsightsTests {
    // MARK: Fixtures

    private let now = date("2026-11-03T10:00:00Z")

    /// Seven values whose quartiles are exactly these: position 1.5, 3 and 4.5 of the sorted values.
    private func week(p25: Double, median: Double, p75: Double) -> [Double] {
        [p25, p25, p25, median, p75, p75, p75]
    }

    private func costDays(p25: Double, median: Double, p75: Double) -> [InsightInputs.UsualDay] {
        week(p25: p25, median: median, p75: p75).map { InsightInputs.UsualDay(cost: $0, output: 0) }
    }

    private func outputDays(p25: Double, median: Double, p75: Double) -> [InsightInputs.UsualDay] {
        week(p25: p25, median: median, p75: p75).map { InsightInputs.UsualDay(cost: 0, output: $0) }
    }

    private func days(_ count: Int) -> [InsightInputs.UsualDay] {
        [InsightInputs.UsualDay](repeating: InsightInputs.UsualDay(cost: 10, output: 10_000), count: count)
    }

    /// Today has use, all of it priced, at `cost`.
    private func spent(_ cost: Double, usual: [InsightInputs.UsualDay], phase: IngestProgress.Phase = .live) -> InsightInputs {
        InsightInputs(
            phase: phase,
            todayTokens: TokenCounts(input: 100, output: 10),
            todayCost: CostSummary(usd: cost, unpricedModels: [], unpricedTokens: 0),
            usualDays: usual
        )
    }

    private func todayRule(_ cost: Double, p25: Double, median: Double, p75: Double) -> TodayRule {
        Insights.compute(spent(cost, usual: costDays(p25: p25, median: median, p75: p75))).today.rule
    }

    private func limit(
        _ percent: Double,
        _ outcome: Projection.Outcome = .lastsUntilReset,
        window: QuotaWindow = .fiveHour,
        scope: String? = nil,
        stale: Bool = false,
        recent: Bool = true,
        resetsIn: TimeInterval = 3_600
    ) -> Projection {
        let snapshot = QuotaSnapshot(
            provider: .anthropic, window: window, scope: scope, usedPercent: percent,
            resetsAt: now.addingTimeInterval(resetsIn), observedAt: now, origin: .claudeCache
        )
        return Projection(
            snapshot: snapshot, estimatedPercent: percent, isEstimate: false, method: .calibrated, outcome: outcome, isStale: stale,
            resetsAt: now.addingTimeInterval(resetsIn), hasRecentData: recent
        )
    }

    private func runsOut(inSeconds seconds: TimeInterval) -> Projection.Outcome {
        .runsOut(at: now.addingTimeInterval(seconds), beforeReset: 60)
    }

    private func limitsInsight(_ limits: [Projection], queryOn: Bool = false) -> LimitsInsight {
        Insights.compute(InsightInputs(phase: .live, limits: limits, anthropicQueryEnabled: queryOn)).limits
    }

    // MARK: The usual range

    @Test(arguments: [0, 1, 6])
    func thereIsNoRangeUnderSevenDays(count: Int) {
        #expect(UsualRange.of([Double](repeating: 5, count: count)) == nil)
    }

    @Test func thereIsARangeAtSevenDays() {
        #expect(UsualRange.of(week(p25: 41, median: 76, p75: 84)) == UsualRange(p25: 41, median: 76, p75: 84))
    }

    /// Position `(n − 1) × p` on the sorted values: 1.75, 3.5 and 5.25 of eight.
    @Test func theQuartilesInterpolateOnTheSortedValues() throws {
        let range = try #require(UsualRange.of([8, 1, 7, 2, 6, 3, 5, 4]))
        #expect(range == UsualRange(p25: 2.75, median: 4.5, p75: 6.25))
    }

    @Test func onlyTheNewestFourteenDaysCount() {
        let old = [Double](repeating: 1_000, count: 6)
        let newest = [Double](repeating: 5, count: 14)
        #expect(UsualRange.of(old + newest) == UsualRange(p25: 5, median: 5, p75: 5))
    }

    @Test func aRangeOfDaysThatAllSpentNothingIsARange() {
        #expect(UsualRange.of([Double](repeating: 0, count: 7)) == UsualRange(p25: 0, median: 0, p75: 0))
    }

    @Test func theEdgesOfTheRangeAreInsideIt() {
        let range = UsualRange(p25: 10, median: 20, p75: 30)
        #expect(range.position(of: 10) == .inside)
        #expect(range.position(of: 30) == .inside)
        #expect(range.position(of: 9.99) == .below)
        #expect(range.position(of: 30.01) == .above)
    }

    // MARK: Rules H, in the order of the table

    @Test(arguments: [IngestProgress.Phase.idle, .recent])
    func h1WhileTheRecentLogsAreRead(phase: IngestProgress.Phase) {
        let usual = costDays(p25: 41, median: 76, p75: 84)
        #expect(Insights.compute(spent(400, usual: usual, phase: phase)).today.rule == .h1)
        #expect(Insights.compute(InsightInputs(phase: phase)).today.rule == .h1)
    }

    @Test func h1hWhileOlderLogsCouldStillBringTheDays() {
        #expect(Insights.compute(spent(5, usual: days(6), phase: .history)).today.rule == .h1h)
        #expect(Insights.compute(InsightInputs(phase: .history)).today.rule == .h1h)
    }

    @Test func historyWithSevenDaysAlreadyCompares() {
        let usual = costDays(p25: 41, median: 76, p75: 84)
        #expect(Insights.compute(spent(60, usual: usual, phase: .history)).today.rule == .h8)
    }

    @Test(arguments: [0, 1, 6])
    func h2CountsTodayOnceItHasUse(count: Int) {
        #expect(Insights.compute(spent(5, usual: days(count))).today.rule == .h2(soFar: count + 1))
    }

    @Test func h2ComesBeforeNothingToday() {
        #expect(Insights.compute(InsightInputs(phase: .live, usualDays: days(3))).today.rule == .h2(soFar: 3))
    }

    @Test func h2EndsAtSevenDays() {
        #expect(Insights.compute(spent(10, usual: days(7))).today.rule == .h8)
    }

    @Test func h3WhenThereAreNoTokensToday() {
        #expect(Insights.compute(InsightInputs(phase: .live, usualDays: costDays(p25: 41, median: 76, p75: 84))).today.rule == .h3)
    }

    @Test func h3LooksAtTokensNotCost() {
        // Tokens with nothing to pay is use: this is not "nothing yet".
        let inputs = spent(0, usual: costDays(p25: 0, median: 0, p75: 0))
        #expect(Insights.compute(inputs).today.rule == .h8)
    }

    @Test func h6WhenTheMedianIsTooSmallForAPercent() {
        #expect(todayRule(400, p25: 0.1, median: 0.49, p75: 0.5) == .h6)
    }

    @Test func h6EndsAtTheFloor() {
        #expect(todayRule(400, p25: 0.1, median: 0.5, p75: 0.6) == .h4(times: 800))
    }

    @Test func h6WithAMedianOfZero() {
        #expect(todayRule(0.01, p25: 0, median: 0, p75: 0) == .h6)
    }

    @Test func h6ComesBeforeTheMultiple() {
        // 80,000% above a median of 0.49 is no finding.
        #expect(todayRule(400, p25: 0.4, median: 0.49, p75: 0.49) == .h6)
    }

    @Test func h4AtThreeHundredPercent() {
        #expect(todayRule(400, p25: 50, median: 100, p75: 100) == .h4(times: 4))
    }

    @Test func h4TakesThePercentAsRounded() {
        #expect(todayRule(399.5, p25: 50, median: 100, p75: 100) == .h4(times: 4))
        #expect(todayRule(399.4, p25: 50, median: 100, p75: 100) == .h5(percent: 299))
    }

    @Test func h4GivesTimesToOneDecimal() {
        #expect(todayRule(1_000, p25: 41, median: 76, p75: 84) == .h4(times: 13.2))
    }

    @Test func h5AtFivePercent() {
        #expect(todayRule(105, p25: 50, median: 100, p75: 100) == .h5(percent: 5))
    }

    /// `pct` is the rounded figure, and it is what the rule reads.
    @Test func thePercentLineFallsOnTheRoundedFigure() {
        #expect(todayRule(104.5, p25: 50, median: 100, p75: 100) == .h5(percent: 5))
        #expect(todayRule(95.5, p25: 100, median: 100, p75: 120) == .h7(percent: 5))
    }

    @Test func h5sUnderFivePercent() {
        #expect(todayRule(104.4, p25: 50, median: 100, p75: 100) == .h5s)
        #expect(todayRule(100.01, p25: 50, median: 100, p75: 100) == .h5s)
    }

    @Test func thePercentIsAgainstTheMedianNotTheEdgeOfTheRange() {
        #expect(todayRule(120, p25: 50, median: 60, p75: 119) == .h5(percent: 100))
    }

    /// A figure this size is a damaged log, and turning it into an `Int` must not trap.
    @Test(arguments: [1e300, Double.infinity])
    func aTodayBeyondAnyPercentIsNoCrash(today: Double) {
        guard case .h4 = todayRule(today, p25: 50, median: 100, p75: 100) else {
            Issue.record("expected h4")
            return
        }
    }

    @Test func h7AtFivePercentBelow() {
        #expect(todayRule(95, p25: 100, median: 100, p75: 120) == .h7(percent: 5))
    }

    @Test func h7sUnderFivePercentBelow() {
        #expect(todayRule(95.6, p25: 100, median: 100, p75: 120) == .h7s)
    }

    /// Some use today is not 100% below.
    @Test func h7StopsAtNinetyNinePercent() {
        #expect(todayRule(0.001, p25: 50, median: 100, p75: 120) == .h7(percent: 99))
    }

    @Test func h7fWhenTheMedianIsTooSmallForAPercent() {
        #expect(todayRule(0.05, p25: 0.10, median: 0.20, p75: 0.30) == .h7f)
        #expect(todayRule(0.05, p25: 0.10, median: 0.49, p75: 0.60) == .h7f)
    }

    @Test func h7fEndsAtTheFloor() {
        #expect(todayRule(0.05, p25: 0.10, median: 0.5, p75: 0.60) == .h7(percent: 90))
    }

    @Test func h8InsideTheRangeEdgesIncluded() {
        #expect(todayRule(41, p25: 41, median: 76, p75: 84) == .h8)
        #expect(todayRule(84, p25: 41, median: 76, p75: 84) == .h8)
        #expect(todayRule(76, p25: 41, median: 76, p75: 84) == .h8)
    }

    /// Section 8.2's own examples.
    @Test func theSpecsWorkedExamples() {
        #expect(todayRule(98.74, p25: 41, median: 76, p75: 84) == .h5(percent: 30))
        #expect(todayRule(400, p25: 41, median: 76, p75: 84) == .h4(times: 5.3))
        #expect(todayRule(60, p25: 41, median: 76, p75: 84) == .h8)
        #expect(todayRule(30, p25: 41, median: 76, p75: 84) == .h7(percent: 61))
        #expect(todayRule(0.05, p25: 0.10, median: 0.20, p75: 0.30) == .h7f)
    }

    /// Daily spend of $1 to $477 with a median of $54: a usual day says nothing dramatic, however far from the mean.
    @Test func aSpreadOfDaysStaysQuietInsideItsRange() {
        let spread: [Double] = [1, 3, 12, 30, 41, 54, 54, 60, 80, 120, 160, 210, 300, 477]
        let inputs = spent(100, usual: spread.map { InsightInputs.UsualDay(cost: $0, output: 0) })
        #expect(Insights.compute(inputs).today.rule == .h8)
    }

    // MARK: Rules H with unpriced models

    private func partlyPriced(_ cost: Double, usual: [InsightInputs.UsualDay]) -> InsightInputs {
        InsightInputs(
            phase: .live,
            todayTokens: TokenCounts(input: 100, output: 10),
            todayCost: CostSummary(usd: cost, unpricedModels: ["m"], unpricedTokens: 50),
            usualDays: usual
        )
    }

    @Test func h9ReplacesInsideAndBelowWhenTodayIsALowerBound() {
        let usual = costDays(p25: 41, median: 76, p75: 84)
        #expect(Insights.compute(partlyPriced(60, usual: usual)).today.rule == .h9)
        #expect(Insights.compute(partlyPriced(30, usual: usual)).today.rule == .h9)
    }

    @Test func aboveStillHoldsWithSomeUnpriced() {
        #expect(Insights.compute(partlyPriced(98.74, usual: costDays(p25: 41, median: 76, p75: 84))).today.rule == .h5(percent: 30))
    }

    @Test func h9NamesNoVerdict() {
        #expect(Insights.compute(partlyPriced(60, usual: costDays(p25: 41, median: 76, p75: 84))).today.verdict == .none)
    }

    @Test func requestsThatNameNoModelAreUnpricedToo() {
        let inputs = InsightInputs(
            phase: .live,
            todayTokens: TokenCounts(input: 100, output: 10),
            todayCost: CostSummary(usd: 60, unpricedModels: [], unpricedTokens: 50),
            usualDays: costDays(p25: 41, median: 76, p75: 84)
        )
        #expect(Insights.compute(inputs).today.rule == .h9)
    }

    @Test func aNamedUnpricedModelIsEnoughForH9() {
        let inputs = InsightInputs(
            phase: .live,
            todayTokens: TokenCounts(input: 100, output: 10),
            todayCost: CostSummary(usd: 60, unpricedModels: ["m"], unpricedTokens: 0),
            usualDays: costDays(p25: 41, median: 76, p75: 84)
        )
        #expect(Insights.compute(inputs).today.rule == .h9)
    }

    /// Section 6.2: priced USD of 0, with tokens. Half priced at a user's price of 0 still shows `no price`, so it is not cost that is compared.
    @Test func nothingPricedIsNoPricedUSDNotEveryTokenUnpriced() {
        let inputs = InsightInputs(
            phase: .live,
            todayTokens: TokenCounts(input: 100, output: 5_000),
            todayCost: CostSummary(usd: 0, unpricedModels: ["m"], unpricedTokens: 2_000),
            usualDays: outputDays(p25: 4_000, median: 4_500, p75: 6_000)
        )
        #expect(Insights.compute(inputs).today.metric == .output)
    }

    /// Priced at nothing is priced: there is no `no price` to fall back from.
    @Test func aPriceOfZeroIsStillAPrice() {
        #expect(Insights.compute(spent(0, usual: costDays(p25: 0, median: 0, p75: 0))).today.metric == .cost)
    }

    @Test func withNothingPricedTodayCompareOutput() {
        let inputs = InsightInputs(
            phase: .live,
            todayTokens: TokenCounts(input: 100, output: 5_000),
            todayCost: CostSummary(usd: 0, unpricedModels: ["m"], unpricedTokens: 5_100),
            usualDays: outputDays(p25: 4_000, median: 4_500, p75: 6_000)
        )
        let today = Insights.compute(inputs).today
        #expect(today.metric == .output)
        #expect(today.value == 5_000)
        #expect(today.rule == .h8)
        #expect(today.range == UsualRange(p25: 4_000, median: 4_500, p75: 6_000))
    }

    /// A day with no use has nothing unpriced either: the Cost card still draws its band.
    @Test func withNoUseTodayTheMetricStaysCost() {
        let usual = (0..<7).map { InsightInputs.UsualDay(cost: 10 + Double($0), output: 5_000) }
        let today = Insights.compute(InsightInputs(phase: .live, usualDays: usual)).today
        #expect(today.metric == .cost)
        #expect(today.range?.median == 13)
    }

    @Test func outputHasItsOwnFloor() {
        func rule(median: Double) -> TodayRule {
            Insights.compute(InsightInputs(
                phase: .live,
                todayTokens: TokenCounts(input: 100, output: 900_000),
                todayCost: CostSummary(usd: 0, unpricedModels: ["m"], unpricedTokens: 900_100),
                usualDays: outputDays(p25: 10, median: median, p75: median)
            )).today.rule
        }
        #expect(rule(median: 999) == .h6)
        #expect(rule(median: 1_000) == .h4(times: 900))
    }

    @Test func outputIsNeverCalledUnpriced() {
        let inputs = InsightInputs(
            phase: .live,
            todayTokens: TokenCounts(input: 100, output: 300),
            todayCost: CostSummary(usd: 0, unpricedModels: ["m"], unpricedTokens: 400),
            usualDays: outputDays(p25: 2_000, median: 3_000, p75: 4_000)
        )
        #expect(Insights.compute(inputs).today.rule == .h7(percent: 90))
    }

    // MARK: What the Cost card draws

    @Test func theVerdictFollowsTheRule() {
        func verdict(_ cost: Double) -> TodayInsight.Verdict {
            Insights.compute(spent(cost, usual: costDays(p25: 41, median: 76, p75: 84))).today.verdict
        }
        #expect(verdict(400) == .above)
        #expect(verdict(98.74) == .above)
        #expect(verdict(84.01) == .above)
        #expect(verdict(60) == .inside)
        #expect(verdict(30) == .below)
        #expect(verdict(40.99) == .below)
    }

    @Test func thereIsNoVerdictBeforeAComparison() {
        let usual = costDays(p25: 41, median: 76, p75: 84)
        #expect(Insights.compute(spent(60, usual: usual, phase: .recent)).today.verdict == .none)
        #expect(Insights.compute(spent(60, usual: days(3))).today.verdict == .none)
        #expect(Insights.compute(InsightInputs(phase: .live, usualDays: usual)).today.verdict == .none)
    }

    @Test func todayReportsItsFigures() {
        let today = Insights.compute(spent(98.74, usual: costDays(p25: 41, median: 76, p75: 84))).today
        #expect(today.metric == .cost)
        #expect(today.value == 98.74)
        #expect(today.range == UsualRange(p25: 41, median: 76, p75: 84))
    }

    @Test func todayHasNoRangeUnderSevenDays() {
        #expect(Insights.compute(spent(5, usual: days(6))).today.range == nil)
    }

    // MARK: Rules L

    @Test func l7WithNoSnapshotsAndTheQueryOff() {
        #expect(limitsInsight([]) == LimitsInsight(rule: .l7, limit: nil))
    }

    @Test func l8WithNoSnapshotsAndTheQueryOn() {
        #expect(limitsInsight([], queryOn: true) == LimitsInsight(rule: .l8, limit: nil))
    }

    @Test func l6WhenNoneIsCurrent() {
        let old = limit(95, runsOut(inSeconds: 60), recent: false)
        #expect(limitsInsight([old]) == LimitsInsight(rule: .l6, limit: nil))
        #expect(limitsInsight([old], queryOn: true) == LimitsInsight(rule: .l6, limit: nil))
    }

    @Test func l1WhenThePercentRoundsToAHundred() {
        let used = limit(99.5)
        #expect(limitsInsight([used]) == LimitsInsight(rule: .l1, limit: used))
        #expect(limitsInsight([limit(99.4)]).rule == .l2)
        #expect(limitsInsight([limit(100, runsOut(inSeconds: 60))]).rule == .l1)
    }

    @Test func l2AtNinetyPercent() {
        let high = limit(90)
        #expect(limitsInsight([high]) == LimitsInsight(rule: .l2, limit: high))
        #expect(limitsInsight([limit(89.99)]).rule == .l4)
    }

    @Test func l2LeavesARunOutToL3() {
        #expect(limitsInsight([limit(95, runsOut(inSeconds: 60))]).rule == .l3)
    }

    @Test func l2PicksTheHighest() {
        let highest = limit(96, window: .weekly)
        #expect(limitsInsight([limit(91), highest, limit(93)]).limit == highest)
    }

    @Test func l3PicksTheSoonestRunOut() {
        let soonest = limit(50, runsOut(inSeconds: 60), window: .weekly)
        #expect(limitsInsight([limit(50, runsOut(inSeconds: 600)), soonest, limit(50, runsOut(inSeconds: 300))]) == LimitsInsight(rule: .l3, limit: soonest))
    }

    @Test func theMostUrgentRuleWins() {
        let used = limit(100, window: .weekly)
        let high = limit(92)
        let running = limit(40, runsOut(inSeconds: 60), scope: "Fable")
        #expect(limitsInsight([running, high, used]).rule == .l1)
        #expect(limitsInsight([running, high]).rule == .l2)
    }

    /// Of two used up, the one that keeps the person waiting longest.
    @Test func l1PicksTheLatestReset() {
        let later = limit(100, window: .weekly, resetsIn: 86_400)
        #expect(limitsInsight([limit(100), later]).limit == later)
    }

    @Test func aLimitWithoutRecentDataCannotWarn() {
        let old = limit(100, recent: false)
        let clear = limit(30)
        #expect(limitsInsight([old, clear]) == LimitsInsight(rule: .l5, limit: clear))
        #expect(limitsInsight([old, limit(95)]).rule == .l2)
    }

    /// By its data, not by a convention elsewhere that such a limit carries `.unknown`.
    @Test func anOldLimitIsNeverClearWhateverItsOutcome() {
        let clear = limit(30)
        #expect(limitsInsight([limit(10, .lastsUntilReset, recent: false), clear]).rule == .l5)
        #expect(limitsInsight([limit(10, .idle, recent: false), clear]).rule == .l5)
    }

    /// "Every limit is clear" beside `No recent quota data` would not be true. Old limits carry `.unknown`.
    @Test func l4LooksAtEveryLimitNotOnlyTheCurrent() {
        let old = limit(0, .unknown, window: .weekly, recent: false)
        let clear = limit(30)
        #expect(limitsInsight([old, clear]) == LimitsInsight(rule: .l5, limit: clear))
    }

    @Test func l4WhenEveryLimitIsClear() {
        #expect(limitsInsight([limit(30), limit(10, .idle, window: .weekly)]).rule == .l4)
    }

    @Test func l5WhenALimitIsStale() {
        #expect(limitsInsight([limit(30), limit(10, stale: true)]).rule == .l5)
    }

    @Test func l5WhenALimitHasNoForecast() {
        #expect(limitsInsight([limit(30), limit(10, .unknown)]).rule == .l5)
    }

    /// Summary's second card shows the highest estimate when nothing is at risk.
    @Test func withNothingAtRiskTheLimitIsTheHighest() {
        let highest = limit(60, window: .weekly)
        #expect(limitsInsight([limit(30), highest]).limit == highest)
        #expect(limitsInsight([limit(30, stale: true), highest]).limit == highest)
    }

    @Test func equalLimitsKeepTheirOrder() {
        let first = limit(60)
        #expect(limitsInsight([first, limit(60, window: .weekly)]).limit == first)
    }

    // MARK: Rules WL and WC

    private func summary(_ projection: Projection) -> LimitsInsight {
        limitsInsight([projection])
    }

    @Test func wl1WhenUsedUp() {
        #expect(summary(limit(99.5)).summarySay == .wl1)
        #expect(summary(limit(100, runsOut(inSeconds: 60))).summarySay == .wl1)
    }

    @Test func wl2AtNinetyPercent() {
        #expect(summary(limit(90)).summarySay == .wl2)
        #expect(summary(limit(99.4, .idle)).summarySay == .wl2)
    }

    @Test func wl3WhenItRunsOut() {
        #expect(summary(limit(95, runsOut(inSeconds: 60))).summarySay == .wl3)
        #expect(summary(limit(10, runsOut(inSeconds: 60))).summarySay == .wl3)
    }

    @Test func wl4WhenItLasts() {
        #expect(summary(limit(89.99)).summarySay == .wl4)
    }

    @Test func wl5WhenNotInUse() {
        #expect(summary(limit(30, .idle)).summarySay == .wl5)
    }

    @Test func wl6WithNoForecast() {
        #expect(summary(limit(30, .unknown)).summarySay == .wl6)
    }

    @Test func wc1WhenItRunsOut() {
        #expect(summary(limit(50, runsOut(inSeconds: 60))).summaryCentre == .wc1)
        #expect(summary(limit(100, runsOut(inSeconds: 60))).summaryCentre == .wc1)
    }

    @Test(arguments: [Projection.Outcome.lastsUntilReset, .idle, .unknown])
    func wc2Otherwise(outcome: Projection.Outcome) {
        #expect(summary(limit(50, outcome)).summaryCentre == .wc2)
    }

    /// With no current limit the card has L6, L7 or L8 and no chart.
    @Test func thereIsNoSummaryLineWithoutALimit() {
        #expect(limitsInsight([]).summarySay == nil)
        #expect(limitsInsight([]).summaryCentre == nil)
        #expect(limitsInsight([limit(95, recent: false)]).summarySay == nil)
    }

    // MARK: Rules W

    private func weekRule(
        _ last: Int,
        before: Int,
        days count: Int = 14,
        phase: IngestProgress.Phase = .live
    ) -> WeekRule {
        Insights.compute(InsightInputs(phase: phase, usualDays: days(count), outputLastSevenDays: last, outputSevenDaysBefore: before)).week
    }

    @Test func w4CountsTheDays() {
        #expect(weekRule(100, before: 100, days: 13) == .w4(soFar: 13))
        #expect(weekRule(0, before: 0, days: 0) == .w4(soFar: 0))
        #expect(weekRule(100, before: 0, days: 1) == .w4(soFar: 1))
    }

    /// Older days may still arrive, so nothing may say days are missing until the phase is `.live`.
    @Test(arguments: [IngestProgress.Phase.idle, .recent, .history])
    func w6ReplacesW4WhileLogsAreRead(phase: IngestProgress.Phase) {
        #expect(weekRule(100, before: 100, days: 13, phase: phase) == .w6)
    }

    /// A week against the one before needs both whole. `.recent` reads the newest days and `.history` the rest, so neither is until `.live`.
    @Test(arguments: [IngestProgress.Phase.idle, .recent, .history])
    func w6WithFourteenDaysToo(phase: IngestProgress.Phase) {
        #expect(weekRule(1, before: 10_000, phase: phase) == .w6)
        #expect(weekRule(100, before: 0, phase: phase) == .w6)
    }

    /// The week before, half read: a true figure would be nothing like this.
    @Test func aWeekBeforeStillBeingReadIsNoBasisForAPercent() {
        #expect(weekRule(70_000, before: 1, phase: .history) == .w6)
        #expect(weekRule(70_000, before: 35_000, phase: .history) == .w6)
    }

    /// Nothing may say days are missing before `.live`.
    @Test func w5WaitsForLive() {
        #expect(weekRule(100, before: 0, phase: .history) == .w6)
        #expect(weekRule(100, before: 0, phase: .live) == .w5)
    }

    @Test func theWeekComparesOnceAllTheLogsAreIn() {
        #expect(weekRule(100, before: 100, phase: .live) == .w3)
    }

    @Test func w5WithNothingInTheSevenDaysBefore() {
        #expect(weekRule(100, before: 0) == .w5)
        #expect(weekRule(0, before: 0) == .w5)
    }

    @Test func w1AtFivePercentUp() {
        #expect(weekRule(105, before: 100) == .w1(percent: 5))
        #expect(weekRule(1_000, before: 100) == .w1(percent: 900))
    }

    @Test func w2AtFivePercentDown() {
        #expect(weekRule(95, before: 100) == .w2(percent: 5))
    }

    @Test func theWeeksPercentLineFallsOnTheRoundedFigureToo() {
        #expect(weekRule(1_045, before: 1_000) == .w1(percent: 5))
        #expect(weekRule(955, before: 1_000) == .w2(percent: 5))
    }

    @Test func w3UnderFivePercentEitherWay() {
        #expect(weekRule(100, before: 100) == .w3)
        #expect(weekRule(1_044, before: 1_000) == .w3)
        #expect(weekRule(956, before: 1_000) == .w3)
    }

    @Test func w2SaysAHundredOnlyOfNothing() {
        #expect(weekRule(0, before: 100) == .w2(percent: 100))
        #expect(weekRule(1, before: 10_000) == .w2(percent: 99))
    }

    @Test func moreThanFourteenDaysCompareToo() {
        #expect(weekRule(100, before: 100, days: 20) == .w3)
    }

    // MARK: Rules P1 to P4

    private func outputRule(_ output: Int, days usual: [InsightInputs.UsualDay], phase: IngestProgress.Phase = .live) -> OutputRule {
        Insights.compute(InsightInputs(phase: phase, todayTokens: TokenCounts(output: output), usualDays: usual)).output.rule
    }

    @Test func p1AboveTheRange() {
        #expect(outputRule(4_001, days: outputDays(p25: 2_000, median: 3_000, p75: 4_000)) == .p1)
    }

    @Test func p2InsideItEdgesIncluded() {
        let usual = outputDays(p25: 2_000, median: 3_000, p75: 4_000)
        #expect(outputRule(4_000, days: usual) == .p2)
        #expect(outputRule(2_000, days: usual) == .p2)
    }

    @Test func p3BelowIt() {
        #expect(outputRule(1_999, days: outputDays(p25: 2_000, median: 3_000, p75: 4_000)) == .p3)
    }

    @Test func p4SaysWhatIsLeft() {
        #expect(outputRule(10, days: days(0)) == .p4(daysLeft: 6))
        #expect(outputRule(10, days: days(1)) == .p4(daysLeft: 5))
        #expect(outputRule(10, days: days(4)) == .p4(daysLeft: 2))
    }

    @Test func p4sWithOneDayLeft() {
        #expect(outputRule(10, days: days(6)) == .p4s)
    }

    @Test(arguments: [IngestProgress.Phase.idle, .recent, .history])
    func theOutputCardDoesNotCountDaysWhileLogsAreRead(phase: IngestProgress.Phase) {
        #expect(outputRule(10, days: days(3), phase: phase) == .readingLogs)
    }

    /// H1 says today is still rising, so this card must not call it below usual.
    @Test(arguments: [IngestProgress.Phase.idle, .recent])
    func theOutputCardComparesNothingWhileTheNewestLogsAreRead(phase: IngestProgress.Phase) {
        #expect(outputRule(10, days: outputDays(p25: 2_000, median: 3_000, p75: 4_000), phase: phase) == .readingLogs)
    }

    /// The needle would draw what the sentence holds back.
    @Test(arguments: [IngestProgress.Phase.idle, .recent])
    func thereIsNoRangeToDrawWhileTheNewestLogsAreRead(phase: IngestProgress.Phase) {
        let usual = (0..<7).map { InsightInputs.UsualDay(cost: 40 + Double($0), output: 3_000 + Double($0)) }
        let results = Insights.compute(InsightInputs(
            phase: phase,
            todayTokens: TokenCounts(input: 100, output: 10),
            todayCost: CostSummary(usd: 1, unpricedModels: [], unpricedTokens: 0),
            usualDays: usual,
            speed: InsightInputs.Speed(model: "m", today: 1, dailyMedians: week(p25: 40, median: 50, p75: 60))
        ))
        #expect(results.today.range == nil)
        #expect(results.output.range == nil)
        #expect(results.speed?.range == nil)
    }

    @Test func theOutputCardComparesOnceTheNewestLogsAreIn() {
        #expect(outputRule(10, days: outputDays(p25: 2_000, median: 3_000, p75: 4_000), phase: .history) == .p3)
    }

    /// Both are true, side by side: nothing yet today, and that is below the usual range.
    @Test func noUseTodaySaysBoth() {
        let results = Insights.compute(InsightInputs(phase: .live, usualDays: outputDays(p25: 2_000, median: 3_000, p75: 4_000)))
        #expect(results.today.rule == .h3)
        #expect(results.output.rule == .p3)
    }

    @Test func theOutputCardReportsItsFigures() {
        let output = Insights.compute(InsightInputs(
            phase: .live, todayTokens: TokenCounts(output: 2_500), usualDays: outputDays(p25: 2_000, median: 3_000, p75: 4_000)
        )).output
        #expect(output.value == 2_500)
        #expect(output.range == UsualRange(p25: 2_000, median: 3_000, p75: 4_000))
    }

    /// The Cost card's rule can be about cost while this one is about output: each has its own range.
    @Test func cardsCompareTheirOwnMetric() {
        let usual = (0..<7).map { InsightInputs.UsualDay(cost: 10 + Double($0), output: 5_000 + Double($0)) }
        let results = Insights.compute(InsightInputs(
            phase: .live,
            todayTokens: TokenCounts(input: 100, output: 9_000),
            todayCost: CostSummary(usd: 12, unpricedModels: [], unpricedTokens: 0),
            usualDays: usual
        ))
        #expect(results.today.rule == .h8)
        #expect(results.output.rule == .p1)
    }

    // MARK: Rules P5 to P7

    private func cacheRule(reads: Int, saving: CostSummary) -> CacheRule? {
        Insights.compute(InsightInputs(phase: .live, todayTokens: TokenCounts(cacheRead: reads), cacheSaving: saving)).cache
    }

    @Test func thereIsNoCacheSayWithNoCacheReads() {
        #expect(cacheRule(reads: 0, saving: .zero) == nil)
    }

    @Test func p5WhenTheSavingIsKnown() {
        #expect(cacheRule(reads: 100, saving: CostSummary(usd: 12.5, unpricedModels: [], unpricedTokens: 0)) == .p5(usd: 12.5))
    }

    @Test func p6WithSomeUnpriced() {
        #expect(cacheRule(reads: 100, saving: CostSummary(usd: 12.5, unpricedModels: ["m"], unpricedTokens: 99)) == .p6(usd: 12.5))
    }

    @Test func p6FromEitherSignOfSomeUnpriced() {
        #expect(cacheRule(reads: 100, saving: CostSummary(usd: 12.5, unpricedModels: [], unpricedTokens: 1)) == .p6(usd: 12.5))
        #expect(cacheRule(reads: 100, saving: CostSummary(usd: 12.5, unpricedModels: ["m"], unpricedTokens: 0)) == .p6(usd: 12.5))
    }

    /// No figure for a model with no price.
    @Test func p7WithNothingPriced() {
        #expect(cacheRule(reads: 100, saving: CostSummary(usd: 0, unpricedModels: ["m"], unpricedTokens: 100)) == .p7)
    }

    // MARK: Rules P4 and P8 to P10

    private func speedInsight(_ today: Double, medians: [Double], phase: IngestProgress.Phase = .live) -> SpeedInsight? {
        Insights.compute(InsightInputs(phase: phase, speed: InsightInputs.Speed(model: "m", today: today, dailyMedians: medians))).speed
    }

    @Test func thereIsNoSpeedSayWithNoSamples() {
        #expect(Insights.compute(InsightInputs(phase: .live)).speed == nil)
    }

    @Test func p8InsideItsRangeEdgesIncluded() {
        let medians = week(p25: 40, median: 50, p75: 60)
        #expect(speedInsight(40, medians: medians)?.rule == .p8)
        #expect(speedInsight(60, medians: medians)?.rule == .p8)
    }

    @Test func p9AboveIt() {
        #expect(speedInsight(60.1, medians: week(p25: 40, median: 50, p75: 60))?.rule == .p9)
    }

    @Test func p10BelowIt() {
        #expect(speedInsight(39.9, medians: week(p25: 40, median: 50, p75: 60))?.rule == .p10)
    }

    @Test func aModelsDaysCountForTheSpeedCard() {
        #expect(speedInsight(50, medians: [])?.rule == .p4(daysLeft: 7))
        #expect(speedInsight(50, medians: [50, 50, 50, 50, 50])?.rule == .p4(daysLeft: 2))
        #expect(speedInsight(50, medians: [Double](repeating: 50, count: 6))?.rule == .p4s)
    }

    @Test(arguments: [IngestProgress.Phase.idle, .recent, .history])
    func theSpeedCardDoesNotCountDaysWhileLogsAreRead(phase: IngestProgress.Phase) {
        #expect(speedInsight(50, medians: [50], phase: phase)?.rule == .readingLogs)
    }

    @Test(arguments: [IngestProgress.Phase.idle, .recent])
    func theSpeedCardComparesNothingWhileTheNewestLogsAreRead(phase: IngestProgress.Phase) {
        #expect(speedInsight(1, medians: week(p25: 40, median: 50, p75: 60), phase: phase)?.rule == .readingLogs)
    }

    @Test func aRangeIsARangeWhileLogsAreRead() {
        #expect(speedInsight(50, medians: week(p25: 40, median: 50, p75: 60), phase: .history)?.rule == .p8)
    }

    @Test func theSpeedCardReportsItsFigures() {
        let speed = speedInsight(50, medians: week(p25: 40, median: 50, p75: 60))
        #expect(speed?.model == "m")
        #expect(speed?.value == 50)
        #expect(speed?.range == UsualRange(p25: 40, median: 50, p75: 60))
    }

    // MARK: Rule P12

    private func cliShare(_ sources: [InsightInputs.SourceToday]) -> CLIShareInsight? {
        Insights.compute(InsightInputs(phase: .live, sources: sources)).clis
    }

    @Test func thereIsNoCLISayWithNoUse() {
        #expect(cliShare([]) == nil)
        #expect(cliShare([InsightInputs.SourceToday(source: .codex, cost: 0, tokens: 0)]) == nil)
    }

    @Test func p12GivesTheTopCostShare() {
        let share = cliShare([
            InsightInputs.SourceToday(source: .codex, cost: 25, tokens: 900),
            InsightInputs.SourceToday(source: .claudeCode, cost: 75, tokens: 100),
        ])
        #expect(share == CLIShareInsight(source: .claudeCode, percent: 75, basis: .cost))
    }

    @Test func p12UsesTokensWhenNothingIsPriced() {
        let share = cliShare([
            InsightInputs.SourceToday(source: .codex, cost: 0, tokens: 900),
            InsightInputs.SourceToday(source: .claudeCode, cost: 0, tokens: 100),
        ])
        #expect(share == CLIShareInsight(source: .codex, percent: 90, basis: .tokens))
    }

    /// As H9: with tokens left out of the cost, a share of it says too much. Codex at $10 is not all of today.
    @Test func p12UsesTokensWhenAnySourceHasUnpricedUse() {
        let share = cliShare([
            InsightInputs.SourceToday(source: .codex, cost: 10, tokens: 100_000),
            InsightInputs.SourceToday(source: .claudeCode, cost: 0, tokens: 900_000, unpricedTokens: 900_000),
        ])
        #expect(share == CLIShareInsight(source: .claudeCode, percent: 90, basis: .tokens))
    }

    @Test func aSingleCLIHasItAll() {
        #expect(cliShare([InsightInputs.SourceToday(source: .pi, cost: 5, tokens: 10)])?.percent == 100)
    }

    @Test func aCostBeyondAnyFigureIsNoCrash() {
        let share = cliShare([
            InsightInputs.SourceToday(source: .codex, cost: .infinity, tokens: 1),
            InsightInputs.SourceToday(source: .claudeCode, cost: 1, tokens: 1),
        ])
        #expect(share?.source == .codex)
    }

    @Test func aCLIThatIsNotAllIsNotCalledAHundredPercent() {
        let share = cliShare([
            InsightInputs.SourceToday(source: .codex, cost: 1, tokens: 1),
            InsightInputs.SourceToday(source: .claudeCode, cost: 9_999, tokens: 1),
        ])
        #expect(share?.percent == 99)
    }

    @Test func equalCLIsKeepTheirOrder() {
        let share = cliShare([
            InsightInputs.SourceToday(source: .codex, cost: 5, tokens: 1),
            InsightInputs.SourceToday(source: .claudeCode, cost: 5, tokens: 1),
        ])
        #expect(share?.source == .codex)
    }

    // MARK: Rule P13

    private func cachePercent(_ tokens: TokenCounts) -> Int? {
        Insights.compute(InsightInputs(phase: .live, todayTokens: tokens)).cacheReadPercent
    }

    @Test func thereIsNoShareWithNoTokens() {
        #expect(cachePercent(.zero) == nil)
    }

    @Test func p13GivesTheShareOfCacheReads() {
        #expect(cachePercent(TokenCounts(input: 20, cacheRead: 80)) == 80)
        #expect(cachePercent(TokenCounts(input: 100)) == 0)
        #expect(cachePercent(TokenCounts(cacheRead: 100)) == 100)
    }

    @Test func aShareIsNotRoundedIntoAClaimItCannotMake() {
        #expect(cachePercent(TokenCounts(input: 1, cacheRead: 9_999)) == 99)
        #expect(cachePercent(TokenCounts(input: 9_999, cacheRead: 1)) == 1)
    }

    // MARK: Rule P14

    /// A grid of tokens, the given cells set.
    private func grid(_ cells: [(row: Int, hour: Int, tokens: Int)]) -> [[Int]] {
        var grid = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 7)
        for cell in cells { grid[cell.row][cell.hour] = cell.tokens }
        return grid
    }

    private func whenRule(_ grid: [[Int]], days count: Int = 14, phase: IngestProgress.Phase = .live) -> WhenRule? {
        Insights.compute(InsightInputs(phase: phase, usualDays: days(count), hourOfWeek: grid)).when
    }

    @Test func thereIsNoWhenSayWithNoTokens() {
        #expect(whenRule([]) == nil)
        #expect(whenRule(grid([])) == nil)
    }

    @Test func p14GivesTheBusiestDayAndItsOwnThreeHours() {
        // Two separate facts: the day is row 3, but the hours sum over every day.
        let rule = whenRule(grid([(3, 2, 500), (1, 9, 300), (2, 10, 300), (4, 11, 300)]))
        #expect(rule == .p14(weekdayRow: 3, fromHour: 9, toHour: 12))
    }

    @Test func aThreeHourBlockCanCrossMidnight() {
        #expect(whenRule(grid([(1, 23, 100), (1, 0, 100), (1, 1, 100)])) == .p14(weekdayRow: 1, fromHour: 23, toHour: 2))
    }

    @Test func equalBlocksAndDaysTakeTheEarliest() {
        #expect(whenRule(grid([(1, 6, 100), (2, 12, 100)])) == .p14(weekdayRow: 1, fromHour: 4, toHour: 7))
    }

    @Test func p14NeedsFourteenDays() {
        let some = grid([(1, 6, 100)])
        #expect(whenRule(some, days: 13) == .needsDays(daysLeft: 1))
        #expect(whenRule(some, days: 1) == .needsDays(daysLeft: 13))
        #expect(whenRule(some, days: 14) == .p14(weekdayRow: 1, fromHour: 4, toHour: 7))
    }

    @Test(arguments: [IngestProgress.Phase.idle, .recent, .history])
    func theWhenCardDoesNotCountDaysWhileLogsAreRead(phase: IngestProgress.Phase) {
        #expect(whenRule(grid([(1, 6, 100)]), days: 3, phase: phase) == .readingLogs)
    }

    /// The grid is every log there is, so it is not whole until they all are.
    @Test(arguments: [IngestProgress.Phase.idle, .recent, .history])
    func theWhenCardNamesNoBusiestDayWhileLogsAreRead(phase: IngestProgress.Phase) {
        #expect(whenRule(grid([(1, 6, 100)]), days: 14, phase: phase) == .readingLogs)
    }

    @Test func theWhenCardNamesItOnceAllTheLogsAreIn() {
        #expect(whenRule(grid([(1, 6, 100)]), days: 14, phase: .live) == .p14(weekdayRow: 1, fromHour: 4, toHour: 7))
    }

    @Test func aGridOfAnotherShapeIsNoCrash() {
        #expect(whenRule([[1, 2, 3]]) == .p14(weekdayRow: 0, fromHour: 0, toHour: 3))
        #expect(whenRule([[Int](repeating: 1, count: 30)]) == .p14(weekdayRow: 0, fromHour: 0, toHour: 3))
    }

    @Test func aRowPastTheWeekIsNotARowToName() {
        var nine = grid([(1, 6, 100)])
        nine += [[Int](repeating: 500, count: 24), [Int](repeating: 500, count: 24)]
        #expect(whenRule(nine) == .p14(weekdayRow: 1, fromHour: 4, toHour: 7))
    }

    @Test func figuresTooLargeToAddUpAreNoCrash() {
        #expect(whenRule(grid([(1, 6, Int.max), (2, 6, Int.max)])) == .p14(weekdayRow: 1, fromHour: 4, toHour: 7))
    }

    // MARK: Whole results

    /// A new install: nothing read yet, nothing to say beyond that.
    @Test func aNewInstallWhileReading() {
        let results = Insights.compute(InsightInputs(phase: .idle))
        #expect(results.today.rule == .h1)
        #expect(results.limits.rule == .l7)
        #expect(results.week == .w6)
        #expect(results.output.rule == .readingLogs)
        #expect(results.cache == nil)
        #expect(results.speed == nil)
        #expect(results.clis == nil)
        #expect(results.cacheReadPercent == nil)
        #expect(results.when == nil)
    }

    /// Every log read, and none of them had anything.
    @Test func noDataAtAll() {
        let results = Insights.compute(InsightInputs(phase: .live))
        #expect(results.today.rule == .h2(soFar: 0))
        #expect(results.today.value == 0)
        #expect(results.today.range == nil)
        #expect(results.week == .w4(soFar: 0))
        #expect(results.output.rule == .p4(daysLeft: 7))
    }

    /// The first day with use is today, and it counts: a card showing tokens must not say none have been seen.
    @Test func aFirstDay() {
        let results = Insights.compute(spent(5, usual: []))
        #expect(results.today.rule == .h2(soFar: 1))
        #expect(results.today.value == 5)
        #expect(results.today.range == nil)
        #expect(results.week == .w4(soFar: 1))
        #expect(results.output.rule == .p4(daysLeft: 6))
    }

    /// Today counts towards the sentence and not towards the range, which is taken over finished days.
    @Test func theSeventhDayStillHasNoRange() {
        let results = Insights.compute(spent(5, usual: days(6)))
        #expect(results.today.rule == .h2(soFar: 7))
        #expect(results.today.range == nil)
        #expect(results.output.rule == .p4s)
    }

    /// The sum of "so far" and "more days" is what the sentence asks for, until the last day.
    @Test(arguments: 0...5)
    func soFarAndLeftAddUp(count: Int) throws {
        let results = Insights.compute(spent(5, usual: days(count)))
        guard case .h2(let soFar) = results.today.rule else { throw Failure.unexpected }
        let left: Int
        switch results.output.rule {
        case .p4(let daysLeft): left = daysLeft
        case .p4s: left = 1
        default: throw Failure.unexpected
        }
        #expect(soFar + left == UsualRange.minimumDays)
    }

    private enum Failure: Error { case unexpected }

    @Test func aDayWithNoUseDoesNotCount() {
        let results = Insights.compute(InsightInputs(phase: .live, usualDays: days(3)))
        #expect(results.today.rule == .h2(soFar: 3))
        #expect(results.week == .w4(soFar: 3))
        #expect(results.output.rule == .p4(daysLeft: 4))
    }

    @Test func aWeekCountsTodayUpToTheDayItCanCompare() {
        #expect(Insights.compute(spent(5, usual: days(13))).week == .w4(soFar: 14))
        #expect(Insights.compute(spent(5, usual: days(14))).week != .w4(soFar: 15))
    }

    @Test func theSpeedCardCountsTodayWithTheOthers() {
        let speed = InsightInputs.Speed(model: "m", today: 50, dailyMedians: [])
        var inputs = spent(5, usual: [])
        inputs.speed = speed
        #expect(Insights.compute(inputs).speed?.rule == .p4(daysLeft: 6))
        var last = spent(5, usual: [])
        last.speed = InsightInputs.Speed(model: "m", today: 50, dailyMedians: [50, 50, 50, 50, 50, 50])
        #expect(Insights.compute(last).speed?.rule == .p4s)
    }

    @Test func theWhenCardCountsTodayWithTheOthers() {
        var hours = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 7)
        hours[1][9] = 100
        var inputs = spent(5, usual: [])
        inputs.hourOfWeek = hours
        #expect(Insights.compute(inputs).when == .needsDays(daysLeft: 13))
        var last = spent(5, usual: days(13))
        last.hourOfWeek = hours
        #expect(Insights.compute(last).when == .needsDays(daysLeft: 1))
    }

    // MARK: Who the quota advice is for

    @Test func theClaudeAdviceIsOnlyForClaude() {
        #expect(limitsInsight([]).rule == .l7)
        #expect(Insights.compute(InsightInputs(phase: .live, watchesClaude: false)).limits.rule == .l9)
    }

    /// With no Claude Code the query has nothing to read, so there is no first reading to wait for.
    @Test func thereIsNothingToWaitForWithoutClaude() {
        #expect(limitsInsight([], queryOn: true).rule == .l8)
        #expect(Insights.compute(InsightInputs(phase: .live, anthropicQueryEnabled: true, watchesClaude: false)).limits.rule == .l9)
    }

    /// One day before today, and today.
    @Test func aSingleDayOfHistory() {
        let results = Insights.compute(spent(5, usual: days(1)))
        #expect(results.today.rule == .h2(soFar: 2))
        #expect(results.week == .w4(soFar: 2))
        #expect(results.output.rule == .p4(daysLeft: 5))
    }

    @Test func theSameInputsGiveTheSameResults() {
        let inputs = spent(98.74, usual: costDays(p25: 41, median: 76, p75: 84))
        #expect(Insights.compute(inputs) == Insights.compute(inputs))
    }
}
