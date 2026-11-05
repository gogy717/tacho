import Foundation
import Testing
@testable import Tacho
import TachoKit

/// What the panel and the menu bar show for each state of the dashboard: spec §4.1, §5 and §6.2.
@MainActor
struct PanelStateTests {
    private let now = Date(timeIntervalSince1970: 1_793_800_000)

    private func cost(_ usd: Double, unpriced: Int = 0, models: [String] = []) -> CostSummary {
        CostSummary(usd: usd, unpricedModels: models, unpricedTokens: unpriced)
    }

    private func dashboard(
        isIdle: Bool = false,
        phase: IngestProgress.Phase = .live,
        rateCost: CostSummary? = nil,
        lastActivity: Date? = nil,
        today: TokenCounts = .zero,
        speeds: [ModelSpeed] = []
    ) -> Dashboard {
        let row = SourceRow(source: .claudeCode, clients: [], perMinute: 0, today: today, todayCost: cost(0), lastActivity: lastActivity, isActive: false, costLastHour: cost(0), hasQuota: false)
        let series = (0..<60).map { TokenCounts(input: $0, output: $0 * 2, cacheRead: $0 * 3, cacheWrite5m: $0 * 4) }
        return Dashboard(perMinute: 4_100_000, perSecond: 68_000, isIdle: isIdle, lastMinute: .zero, series: series, sources: [row], quotas: [], today: TodaySummary(tokens: today, cost: cost(0), speeds: speeds), alert: .none, progress: IngestProgress(phase: phase, filesDone: 212, filesTotal: 704), outputPerMinute: 11_200, costPerMinute: rateCost ?? cost(1.2))
    }

    private func row(_ source: Source, hasQuota: Bool = true, isActive: Bool = false, hourly: Double = 0, cost usd: Double = 0, tokens: Int = 0) -> SourceRow {
        SourceRow(source: source, clients: [], perMinute: 0, today: TokenCounts(output: tokens), todayCost: cost(usd), lastActivity: nil, isActive: isActive, costLastHour: cost(hourly), hasQuota: hasQuota)
    }

    private func dashboardWithSources(_ rows: [SourceRow]) -> Dashboard {
        var dashboard = dashboard()
        dashboard.sources = rows
        return dashboard
    }

    private func preferences(_ mode: RateMode = .output, style: MenuBarStyle = .rate) -> Preferences {
        var preferences = Preferences.defaults(home: URL(fileURLWithPath: "/nowhere"))
        preferences.rateMode = mode
        preferences.menuBarStyle = style
        return preferences
    }

    private func state(_ dashboard: Dashboard, _ mode: RateMode = .output) -> PanelState {
        PanelState(dashboard: dashboard, preferences: preferences(mode), now: now)
    }

    /// It says why Today is short, which matters more than a note about prices.
    @Test func aClockSetBackTakesTheNote() {
        let at = Date(timeIntervalSince1970: 1_793_800_000)
        var dashboard = dashboard()
        dashboard.today.cost = CostSummary(usd: 0, unpricedModels: ["m"], unpricedTokens: 40)
        let priced = PanelState.Today(dashboard: dashboard, insights: nil, now: at).note
        dashboard.newestEvent = at.addingTimeInterval(3_600)
        let behind = PanelState.Today(dashboard: dashboard, insights: nil, now: at).note
        #expect(behind == Labels.clockBehind(newestEvent: at.addingTimeInterval(3_600), now: at))
        #expect(behind != nil)
        #expect(behind != priced)
    }

    @Test func liveShowsTheChosenModesFigure() {
        #expect(state(dashboard()).rate.headline == .live(figure: "11.2k/min"))
        #expect(state(dashboard(), .allTokens).rate.headline == .live(figure: "4.1M/min"))
        #expect(state(dashboard(), .cost).rate.headline == .live(figure: "$1.20/min"))
    }

    @Test func theMenuAlwaysHoldsAllThreeReadings() {
        let readings = state(dashboard()).rate.readings
        #expect(readings.map(\.mode) == [.output, .allTokens, .cost])
        #expect(readings[0].title.contains("11.2k/min"))
        #expect(readings[2].title.contains("$1.20/min"))
    }

    @Test func idleSaysWhenTheLastRequestWas() {
        var idle = dashboard(isIdle: true)
        idle.latestRequest = now.addingTimeInterval(-38 * 60)
        let state = state(idle)
        guard case .idle(let lastSeen) = state.rate.headline else {
            Issue.record("expected idle")
            return
        }
        #expect(lastSeen?.contains("38") == true)
    }

    @Test func aNewInstallIsReadingNotIdle() {
        #expect(state(dashboard(isIdle: true, phase: .recent)).rate.headline == .reading)
        #expect(state(dashboard(isIdle: true, phase: .idle)).rate.headline == .reading)
    }

    @Test func readingOlderLogsIsNormalPlusProgress() {
        let state = state(dashboard(phase: .history))
        #expect(state.rate.headline == .live(figure: "11.2k/min"))
        #expect(state.progress?.text.contains("212") == true)
        #expect(abs((state.progress?.fraction ?? 0) - 212.0 / 704.0) < 0.001)
    }

    @Test func noProgressOnceLive() {
        #expect(state(dashboard()).progress == nil)
    }

    @Test func outputIsOneLayer() {
        let rate = state(dashboard()).rate
        #expect(rate.layers == [.output])
        #expect(rate.series[59] == [118])
    }

    @Test func aMinuteOfCostUnderThePointerFollowsTheThreeWayRule() {
        var figures = dashboard()
        figures.costSeries = [
            CategoryCost(output: 1.2),
            CategoryCost(output: 1.2, unpricedTokens: 500),
            CategoryCost(unpricedTokens: 500),
            CategoryCost(output: 0.004),
        ]
        let rate = state(figures, .cost).rate
        #expect(rate.figure(ofMinute: 0) == "$1.20")
        #expect(rate.figure(ofMinute: 1) == "$1.20+")
        #expect(rate.figure(ofMinute: 2) == "no price")
        #expect(rate.figure(ofMinute: 3) == "<$0.01")
    }

    @Test func aMinuteOfTokensUnderThePointerIsACount() {
        #expect(state(dashboard()).rate.figure(ofMinute: 59) == "118")
    }

    @Test func aMinuteOffTheChartHasNoFigure() {
        let rate = state(dashboard()).rate
        #expect(rate.figure(ofMinute: rate.series.count) == nil)
        #expect(rate.figure(ofMinute: -1) == nil)
    }

    @Test func allTokensStacksInTheCheckedOrder() {
        let rate = state(dashboard(), .allTokens).rate
        #expect(rate.layers == [.cacheRead, .cacheWrite, .output, .input])
        #expect(rate.series[1] == [3, 4, 2, 1])
    }

    @Test func theCostNoteOnlyShowsInCostMode() {
        let unpriced = dashboard(rateCost: cost(1.2, unpriced: 5, models: ["acme-coder-2"]))
        #expect(state(unpriced).rate.note == nil)
        #expect(state(unpriced, .cost).rate.note?.contains("acme-coder-2") == true)
    }

    @Test func aProgressWithNoTotalYetIsIndeterminate() {
        var dashboard = dashboard(phase: .history)
        dashboard.progress.filesTotal = 0
        #expect(state(dashboard).progress?.fraction == nil)
    }

    @Test func costModeWithNothingPricedSaysSoInsteadOfDrawing() {
        var unpriced = dashboard()
        unpriced.costSeries = [.zero]
        #expect(state(unpriced, .cost).rate.emptyText == String(localized: "chart.noPrice", bundle: .tacho))
    }

    @Test func costModeWithNothingPricedHasNoNote() {
        #expect(state(dashboard(rateCost: cost(0, unpriced: 9, models: ["a-1"])), .cost).rate.note == nil)
    }

    @Test func costModeWithSomePricedSaysWhatIsLeftOut() {
        #expect(state(dashboard(rateCost: cost(1, unpriced: 9, models: ["a-1"])), .cost).rate.note == "Excludes a-1: no price")
    }

    @Test func costModeWithNoUseInTheHourIsPlainlyEmpty() {
        var quiet = dashboard()
        quiet.series = [.zero]
        quiet.costSeries = [.zero]
        #expect(state(quiet, .cost).rate.emptyText == String(localized: "chart.empty", bundle: .tacho))
    }

    @Test func costModeChartsDollarsInTheStackOrder() {
        var priced = dashboard()
        priced.costSeries = [CategoryCost(input: 1, output: 2, cacheRead: 3, cacheWrite: 4)]
        let rate = state(priced, .cost).rate
        #expect(rate.layers == Theme.stackOrder)
        #expect(rate.series == [[3, 4, 2, 1]])
        #expect(rate.emptyText == String(localized: "chart.empty", bundle: .tacho))
    }

    @Test func otherModesKeepThePlainEmptyText() {
        #expect(state(dashboard()).rate.emptyText == String(localized: "chart.empty", bundle: .tacho))
    }

    // CLIs with no quota: spec §4.5, goal 6.
    @Test func anActiveCLIWithNoQuotaShowsItsHourlyCost() throws {
        let limits = state(dashboardWithSources([row(.opencode, hasQuota: false, isActive: true, hourly: 0.2, tokens: 9), row(.pi, hasQuota: false, isActive: true, hourly: 0.1, tokens: 9), row(.claudeCode, hasQuota: true, isActive: true, hourly: 5, tokens: 9), row(.grok, hasQuota: false, isActive: false, hourly: 1, tokens: 9)])).limits
        let last = try #require(limits.rows.last)
        #expect(last.name == String(localized: "limits.noQuotaShort", bundle: .tacho))
        guard case .line(let text) = last.content else {
            Issue.record("expected a line")
            return
        }
        #expect(text.contains("OpenCode"))
        #expect(text.contains("pi"))
        #expect(!text.contains("Claude Code"))
        #expect(!text.contains("Grok"))
    }

    @Test func aCLIUnusedTodayIsNotCalledOneWithNoQuota() {
        #expect(state(dashboardWithSources([row(.claudeCode, hasQuota: false, isActive: true, hourly: 5)])).limits.rows.isEmpty)
    }

    @Test func noSuchCLIsNoRow() {
        #expect(state(dashboardWithSources([row(.claudeCode, hasQuota: true, isActive: true, hourly: 5)])).limits.rows.isEmpty)
    }

    // VoiceOver: spec §4.1. The label replaces what is drawn, so the value has to say it.
    @Test func theHeadlineSaysItsFigureAndMode() {
        #expect(state(dashboard()).rate.spoken == "11.2k/min, Output")
    }

    @Test func idleSaysWhenItLastWorked() {
        var idle = dashboard(isIdle: true)
        idle.latestRequest = now.addingTimeInterval(-38 * 60)
        let spoken = state(idle).rate.spoken
        #expect(spoken.hasPrefix(String(localized: "rate.idle", bundle: .tacho)))
        #expect(spoken.contains("38"))
    }

    @Test func idleWithNothingYetIsJustIdle() {
        #expect(state(dashboard(isIdle: true)).rate.spoken == String(localized: "rate.idle", bundle: .tacho))
    }

    // The menu bar: spec §5.
    @Test func theMenuBarFollowsTheMode() {
        #expect(MenuBarLabel.title(dashboard: dashboard(), preferences: preferences()) == "11.2k/min")
        #expect(MenuBarLabel.title(dashboard: dashboard(), preferences: preferences(.allTokens)) == "4.1M/min")
        #expect(MenuBarLabel.title(dashboard: dashboard(), preferences: preferences(.cost)) == "$1.20/min")
    }

    @Test func theMenuBarNeverSaysZeroDollars() {
        let title = MenuBarLabel.title(dashboard: dashboard(rateCost: cost(0, unpriced: 9)), preferences: preferences(.cost))
        #expect(title == String(localized: "cost.noPrice", bundle: .tacho))
    }

    @Test func whileReadingTheMenuBarIsTheIconAlone() {
        #expect(MenuBarLabel.title(dashboard: dashboard(phase: .recent), preferences: preferences()) == nil)
        #expect(MenuBarLabel.title(dashboard: dashboard(phase: .idle), preferences: preferences()) == nil)
        #expect(MenuBarLabel.title(dashboard: dashboard(phase: .history), preferences: preferences()) == "11.2k/min")
    }

    @Test func idleIsTheIconAlone() {
        #expect(MenuBarLabel.title(dashboard: dashboard(isIdle: true), preferences: preferences()) == nil)
        #expect(MenuBarLabel.title(dashboard: nil, preferences: preferences()) == nil)
        #expect(MenuBarLabel.title(dashboard: dashboard(), preferences: preferences(style: .iconOnly)) == nil)
    }

    // The pinned cards: spec §7. Only comparisons need history.
    @Test func cardsShowTodaysValueWithoutHistory() {
        let today = TokenCounts(input: 39, output: 41_800, cacheRead: 961)
        let speed = ModelSpeed(model: "claude-opus-5-5", tokensPerSecond: 71, samples: 9, approximate: true)
        let tiles = state(dashboard(today: today, speeds: [speed])).tiles
        #expect(tiles.map(\.id) == ["output", "cache", "speed", "clis"])
        #expect(tiles[0].value == "41.8k")
        #expect(tiles[1].value?.contains("96.1%") == true)
        #expect(tiles[2].value?.contains("71") == true)
        #expect(tiles[2].say == "Opus 5.5")
        #expect(tiles[3].value == "1")
    }

    @Test func noValueSaysSo() {
        let noData = String(localized: "card.noData", bundle: .tacho)
        let tiles = state(dashboard()).tiles
        #expect(tiles.allSatisfy { $0.value == noData })
    }

    @Test func theModelWithTheMostSamplesSpeaksForSpeed() {
        let few = ModelSpeed(model: "gpt-6", tokensPerSecond: 10, samples: 2, approximate: false)
        let many = ModelSpeed(model: "claude-opus-5-5", tokensPerSecond: 71, samples: 90, approximate: false)
        #expect(state(dashboard(speeds: [few, many])).tiles[2].say == "Opus 5.5")
    }
}
