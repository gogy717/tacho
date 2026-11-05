import Foundation
import Testing
@testable import Tacho
import TachoKit

/// What the panel does with `Insights.compute`'s answer: spec §4.4, §7 and §8. Which rule fires is TachoKit's; these hand it results.
@MainActor
struct PanelInsightTests {
    private let now = Date(timeIntervalSince1970: 1_793_800_000)
    private let range = UsualRange(p25: 41, median: 76, p75: 84)

    private func dashboard(output: Int = 12_400, usd: Double = 98.74, unpriced: Int = 0, speeds: [ModelSpeed] = []) -> Dashboard {
        let cost = CostSummary(usd: usd, unpricedModels: [], unpricedTokens: unpriced)
        let tokens = TokenCounts(input: 10, output: output, cacheRead: 90)
        let row = SourceRow(source: .claudeCode, clients: [], perMinute: 0, today: tokens, todayCost: cost, lastActivity: nil, isActive: false, costLastHour: .zero, hasQuota: true)
        return Dashboard(perMinute: 0, perSecond: 0, isIdle: true, lastMinute: .zero, series: [], sources: [row], quotas: [], today: TodaySummary(tokens: tokens, cost: cost, speeds: speeds), alert: .none, progress: IngestProgress(phase: .live, filesDone: 0, filesTotal: 0), outputPerMinute: 0, costPerMinute: .zero)
    }

    private func results(
        today: TodayInsight? = nil,
        limits: LimitsInsight = LimitsInsight(rule: .l5, limit: nil),
        output: OutputInsight = OutputInsight(rule: .p2, value: 12_400, range: nil),
        cache: CacheRule? = nil,
        speed: SpeedInsight? = nil,
        clis: CLIShareInsight? = nil
    ) -> InsightResults {
        InsightResults(
            today: today ?? TodayInsight(rule: .h8, metric: .cost, value: 60, range: range, verdict: .inside),
            limits: limits,
            week: .w3,
            output: output,
            cache: cache,
            speed: speed,
            clis: clis,
            cacheReadPercent: nil,
            when: nil
        )
    }

    private func state(_ dashboard: Dashboard, _ results: InsightResults?) -> PanelState {
        state(dashboard, panel: results.map { PanelInsights(results: $0) })
    }

    private func state(_ dashboard: Dashboard, panel: PanelInsights?, pinned: [PinnedCard]? = nil) -> PanelState {
        var preferences = Preferences.defaults(home: URL(fileURLWithPath: "/nowhere"))
        if let pinned { preferences.pinnedCards = pinned }
        return PanelState(dashboard: dashboard, preferences: preferences, insights: panel, now: now)
    }

    private func tile(_ id: String, _ state: PanelState) throws -> PanelState.Tile {
        try #require(state.tiles.first { $0.id == id })
    }

    // The Cost today card: spec §4.4.
    @Test func theSentenceIsTheRulesOwn() {
        let today = TodayInsight(rule: .h5(percent: 30), metric: .cost, value: 98.74, range: range, verdict: .above)
        #expect(state(dashboard(), results(today: today)).today.sentence == Labels.sentence(.h5(percent: 30)))
    }

    @Test func withNoAnswerYetTheCardMakesNoComparison() {
        let today = state(dashboard(), nil).today
        #expect(today.sentence == " ")
        #expect(today.usual == nil)
    }

    @Test func theCaptionGivesTheMedianAndTheTime() {
        let today = state(dashboard(), results()).today
        #expect(today.usual == "usually about $76.00 by \(Labels.clock(now))")
    }

    /// "no price so far" would say a price may yet come. Until the answer turns the card to output, it just has none.
    @Test func nothingPricedWithNoAnswerIsNoPrice() {
        #expect(state(dashboard(usd: 0, unpriced: 9), nil).today.value == "no price")
    }

    @Test func nothingPricedWithAnAnswerIsOutputSoFar() {
        let insight = TodayInsight(rule: .h8, metric: .output, value: 12_400, range: nil, verdict: .inside)
        #expect(state(dashboard(usd: 0, unpriced: 9), results(today: insight)).today.value == "12.4k so far")
    }

    @Test func somePricedWithNoAnswerIsSoFar() {
        #expect(state(dashboard(usd: 98.74, unpriced: 9), nil).today.value == "$98.74+ so far")
    }

    @Test func noUseTodayStillGivesTheCaption() {
        let today = TodayInsight(rule: .h3, metric: .cost, value: 0, range: range, verdict: .none)
        let shown = state(dashboard(usd: 0), results(today: today)).today
        #expect(shown.value == "$0.00 so far")
        #expect(shown.usual == "usually about $76.00 by \(Labels.clock(now))")
    }

    @Test func underSevenDaysSaysThereIsNoRangeYet() {
        let today = TodayInsight(rule: .h2(soFar: 3), metric: .cost, value: 60, range: nil, verdict: .none)
        #expect(state(dashboard(), results(today: today)).today.usual == "no usual range yet")
    }

    @Test func whileReadingThereIsNoCaption() {
        for rule in [TodayRule.h1, .h1h] {
            let today = TodayInsight(rule: rule, metric: .cost, value: 60, range: nil, verdict: .none)
            #expect(state(dashboard(), results(today: today)).today.usual == nil)
        }
    }

    @Test func nothingPricedTurnsTheCardToOutput() {
        let insight = TodayInsight(rule: .h8, metric: .output, value: 12_400, range: UsualRange(p25: 9_000, median: 11_500, p75: 15_000), verdict: .inside)
        let today = state(dashboard(), results(today: insight)).today
        #expect(today.title == String(localized: "card.outputToday", bundle: .tacho))
        #expect(today.isOutput)
        #expect(today.value == "12.4k so far")
        #expect(today.usual == "usually about 11.5k by \(Labels.clock(now))")
        #expect(today.help == String(localized: "today.outputHelp", bundle: .tacho))
    }

    @Test func aCostCardStaysACostCard() {
        let today = state(dashboard(), results()).today
        #expect(today.title == String(localized: "card.costToday", bundle: .tacho))
        #expect(!today.isOutput)
        #expect(today.help == nil)
    }

    // The Limits card: spec §8.3.
    @Test func theLimitsSentenceIsTheRulesOwn() {
        let limits = state(dashboard(), results(limits: LimitsInsight(rule: .l4, limit: nil))).limits
        #expect(limits.say == String(localized: "limit.say.clear", bundle: .tacho))
        #expect(limits.tone == .plain)
    }

    @Test func withNoAnswerYetTheLimitsCardSaysNothing() {
        let limits = state(dashboard(), nil).limits
        #expect(limits.say == nil)
        #expect(limits.tone == .plain)
    }

    // The pinned cards: spec §7 and §8.4.
    @Test func theOutputCardSaysAndDrawsTheScale() throws {
        let output = OutputInsight(rule: .p1, value: 12_400, range: UsualRange(p25: 9_000, median: 11_500, p75: 12_000))
        let shown = try tile("output", state(dashboard(), results(output: output)))
        #expect(shown.say == Labels.say(.p1))
        #expect(shown.mark == PanelState.Tile.Mark.needle(value: 12_400, p25: 9_000, p75: 12_000))
    }

    @Test func withNoRangeThereIsNoScale() throws {
        let output = OutputInsight(rule: .p4(daysLeft: 5), value: 12_400, range: nil)
        let shown = try tile("output", state(dashboard(), results(output: output)))
        #expect(shown.say == Labels.say(.p4(daysLeft: 5)))
        #expect(shown.mark == PanelState.Tile.Mark.none)
    }

    @Test func aCardWithNoValueHasNoSayAndNoMark() throws {
        let output = OutputInsight(rule: .p2, value: 0, range: range)
        let shown = try tile("output", state(dashboard(output: 0), results(output: output)))
        #expect(shown.value == String(localized: "card.noData", bundle: .tacho))
        #expect(shown.say == nil)
        #expect(shown.mark == PanelState.Tile.Mark.none)
    }

    @Test func theCacheCardSaysWhatWasKept() throws {
        let shown = try tile("cache", state(dashboard(), results(cache: .p5(usd: 864))))
        #expect(shown.say == Labels.say(.p5(usd: 864)))
    }

    @Test func theSpeedCardFollowsTheInsightsModel() throws {
        let speeds = [ModelSpeed(model: "claude-opus-5-5", tokensPerSecond: 71, samples: 40, approximate: false), ModelSpeed(model: "claude-sonnet-5-5", tokensPerSecond: 120, samples: 90, approximate: false)]
        let insight = SpeedInsight(rule: .p9, model: "claude-opus-5-5", value: 71, range: UsualRange(p25: 40, median: 50, p75: 60))
        let shown = try tile("speed", state(dashboard(speeds: speeds), results(speed: insight)))
        #expect(shown.value == Labels.speed(speeds[0]))
        #expect(shown.say == Labels.say(.p9, model: "claude-opus-5-5"))
        #expect(shown.mark == PanelState.Tile.Mark.needle(value: 71, p25: 40, p75: 60))
    }

    /// With no row to say how the figure was timed, it does not claim to be exact.
    @Test func aSpeedWithNoRowToSayHowItWasTimedIsMarked() throws {
        let insight = SpeedInsight(rule: .p9, model: "claude-opus-5-5", value: 71, range: nil)
        #expect(try tile("speed", state(dashboard(speeds: []), results(speed: insight))).value == "≈ 71 tok/s")
    }

    @Test func theCLIsCardUsesTheRulesPercent() throws {
        let clis = CLIShareInsight(source: .codex, percent: 64, basis: .cost)
        let shown = try tile("clis", state(dashboard(), results(clis: clis)))
        #expect(shown.say == "Codex: 64% of cost")
    }

    @Test func theCLIsCardSaysWhatTheShareIsOf() throws {
        let clis = CLIShareInsight(source: .codex, percent: 64, basis: .tokens)
        let shown = try tile("clis", state(dashboard(), results(clis: clis)))
        #expect(shown.say == "Codex: 64% of tokens")
    }

    @Test func theCLIsCardDrawsTheEnginesShares() throws {
        let figures = CLIFigures(shares: [.init(source: .claudeCode, fraction: 0.8), .init(source: .codex, fraction: 0.15), .init(source: .grok, fraction: 0.05)])
        let shown = try tile("clis", state(dashboard(), panel: PanelInsights(results: results(clis: CLIShareInsight(source: .claudeCode, percent: 80, basis: .cost)), clis: figures)))
        #expect(shown.mark == PanelState.Tile.Mark.shares([0.8, 0.15, 0.05]))
    }

    /// The answer can be a minute old, and the first request of the day must not read as 0 CLIs.
    @Test func theCLIsCountIsTheLiveOne() throws {
        let shown = try tile("clis", state(dashboard(), panel: PanelInsights(results: results(), clis: CLIFigures())))
        #expect(shown.value == "1")
    }

    @Test func withNoAnswerTheCLIsCardCountsAndDrawsNothing() throws {
        let shown = try tile("clis", state(dashboard(), nil))
        #expect(shown.value == "1")
        #expect(shown.say == nil)
        #expect(shown.mark == PanelState.Tile.Mark.none)
    }

    @Test func theCacheCardDrawsItsDays() throws {
        let cache = CacheFigures(hitRate: 0.9, dailyHitRates: [0.8, 0.9])
        let shown = try tile("cache", state(dashboard(), panel: PanelInsights(results: results(), cache: cache)))
        #expect(shown.mark == PanelState.Tile.Mark.spark([0.8, 0.9]))
    }

    @Test func oneDayIsNoSparkline() throws {
        let cache = CacheFigures(hitRate: 0.9, dailyHitRates: [0.8])
        let shown = try tile("cache", state(dashboard(), panel: PanelInsights(results: results(), cache: cache)))
        #expect(shown.mark == PanelState.Tile.Mark.none)
    }

    // Drawing the day: spec §4.4.
    private func drawn(_ rule: TodayRule, metric: TodayInsight.Metric = .cost) -> UsualRangeSeries {
        let cost = UsualCurve(band: [.init(fraction: 0.5, low: 1, median: 2, high: 3)], today: [.init(fraction: 0.25, value: 4)], usualNow: 2)
        let output = UsualCurve(band: [.init(fraction: 0.5, low: 10, median: 20, high: 30)], today: [.init(fraction: 0.25, value: 40)], usualNow: 20)
        let today = TodayInsight(rule: rule, metric: metric, value: 1, range: range, verdict: .none)
        return state(dashboard(), panel: PanelInsights(results: results(today: today), cost: cost, output: output)).today.series
    }

    @Test func theCurveIsTheRulesMetric() {
        #expect(drawn(.h8).band == [.init(hour: 12, low: 1, high: 3)])
        #expect(drawn(.h8).line == [.init(hour: 6, value: 4)])
        #expect(drawn(.h8, metric: .output).band == [.init(hour: 12, low: 10, high: 30)])
        #expect(drawn(.h8, metric: .output).line == [.init(hour: 6, value: 40)])
    }

    @Test func whileReadingOnlyTodayIsDrawn() {
        for rule in [TodayRule.h1, .h1h] {
            #expect(drawn(rule).band.isEmpty)
            #expect(drawn(rule).line.count == 1)
        }
    }

    @Test func noUseTodayDrawsOnlyTheBand() {
        #expect(drawn(.h3).line.isEmpty)
        #expect(drawn(.h3).band.count == 1)
    }

    // Pinning: spec §7.
    @Test func thePanelShowsTheFirstFourPinned() {
        let shown = state(dashboard(), panel: nil)
        #expect(shown.tiles.map(\.id) == ["output", "cache", "speed", "clis"])
    }

    @Test func thePinnedOrderIsThePeoples() {
        let shown = state(dashboard(), panel: nil, pinned: [.when, .tokens, .cache])
        #expect(shown.tiles.map(\.id) == ["when", "tokens", "cache"])
    }

    @Test func theWindowCanAskForEveryCard() {
        let all = PanelState.Tile.pinned(PinnedCard.allCases, dashboard: dashboard(), insights: nil, limit: nil)
        #expect(all.map(\.id) == ["output", "cache", "speed", "clis", "tokens", "when"])
    }

    @Test func nothingPinnedIsNoCards() {
        #expect(state(dashboard(), panel: nil, pinned: []).tiles.isEmpty)
    }

    @Test func theTokensCardDrawsItsLayers() throws {
        var answer = results()
        answer.cacheReadPercent = 90
        let shown = try tile("tokens", state(dashboard(output: 0), panel: PanelInsights(results: answer), pinned: [.tokens]))
        #expect(shown.value == "100")
        #expect(shown.say == Labels.cacheReads(90))
        #expect(shown.mark == PanelState.Tile.Mark.layers([0.9, 0, 0, 0.1]))
    }

    @Test func theWhenCardHasOnlyItsSay() throws {
        var answer = results()
        answer.when = .needsDays(daysLeft: 4)
        let shown = try tile("when", state(dashboard(), panel: PanelInsights(results: answer), pinned: [.when]))
        #expect(shown.value == nil)
        #expect(shown.say == Labels.say(.needsDays(daysLeft: 4)))
    }

    @Test func aWhenCardWithNothingToSaySaysNoData() throws {
        let shown = try tile("when", state(dashboard(), panel: nil, pinned: [.when]))
        #expect(shown.value == String(localized: "card.noData", bundle: .tacho))
        #expect(shown.say == nil)
    }

    // Routes: spec §7 and §10.
    @Test func everyCardOpensWhatTheSpecSays() throws {
        let speed = SpeedInsight(rule: .p8, model: "claude-opus-5-5", value: 71, range: nil)
        let panel = PanelInsights(results: results(speed: speed))
        let first = state(dashboard(), panel: panel)
        let second = state(dashboard(), panel: panel, pinned: [.tokens, .when])
        #expect(try tile("output", first).route == Route(page: .tokens, metric: .output, range: .day))
        #expect(try tile("cache", first).route == Route(page: .cache, range: .day))
        #expect(try tile("speed", first).route == Route(page: .speed, model: "claude-opus-5-5"))
        #expect(try tile("clis", first).route == Route(page: .cost, range: .day))
        #expect(try tile("tokens", second).route == Route(page: .tokens, metric: .allTokens, range: .day))
        #expect(try tile("when", second).route == Route(page: .calendar))
        #expect(first.today.route == Route(page: .cost, range: .day))
    }

    @Test func aCardWithNoValueStillOpensItsPage() throws {
        let shown = state(dashboard(output: 0), panel: nil)
        #expect(try tile("output", shown).route == Route(page: .tokens, metric: .output, range: .day))
        #expect(try tile("speed", shown).route == Route(page: .speed))
    }

    @Test func theLimitsCardOpensTheLimitTheRulePicked() {
        let reset = now.addingTimeInterval(7_200)
        let snapshot = QuotaSnapshot(provider: .anthropic, window: .weekly, scope: "Fable", usedPercent: 40, resetsAt: reset, observedAt: now, origin: .claudeCache)
        let limit = Projection(snapshot: snapshot, estimatedPercent: 40, isEstimate: false, method: .calibrated, outcome: .lastsUntilReset, isStale: false, resetsAt: reset)
        let picked = state(dashboard(), results(limits: LimitsInsight(rule: .l5, limit: limit))).limits
        #expect(picked.route == Route(page: .limits, limit: LimitKey(snapshot)))
        #expect(state(dashboard(), nil).limits.route == Route(page: .limits))
    }

    @Test func withNoAnswerYetTheCardsMakeNoComparison() throws {
        let shown = state(dashboard(), nil)
        #expect(try tile("output", shown).say == nil)
        #expect(try tile("output", shown).mark == PanelState.Tile.Mark.none)
        #expect(try tile("cache", shown).say == nil)
    }
}
