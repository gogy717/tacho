import Foundation
import Testing
@testable import Tacho
import TachoKit

struct PanelLimitsTests {
    private let now = Date(timeIntervalSince1970: 1_793_800_000)

    private func quota(
        _ provider: QuotaProvider = .anthropic,
        _ window: QuotaWindow = .fiveHour,
        scope: String? = nil,
        percent: Double = 40,
        outcome: Projection.Outcome = .lastsUntilReset,
        isStale: Bool = false,
        age: TimeInterval = 120,
        recent: Bool = true
    ) -> Projection {
        let reset = now.addingTimeInterval(7_200)
        let snapshot = QuotaSnapshot(provider: provider, window: window, scope: scope, usedPercent: percent, resetsAt: reset, observedAt: now.addingTimeInterval(-age), origin: .claudeCache)
        return Projection(snapshot: snapshot, estimatedPercent: percent, isEstimate: false, method: .calibrated, outcome: outcome, isStale: isStale, resetsAt: reset, hasRecentData: recent)
    }

    private func limits(_ quotas: [Projection], query: Bool = false) -> PanelState.Limits {
        let inputs = InsightInputs(phase: .live, limits: quotas, anthropicQueryEnabled: query)
        return PanelState.Limits(quotas: quotas, insight: Insights.compute(inputs).limits, now: now)
    }

    private func say(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .tacho)
    }

    private func cells(_ row: PanelState.LimitRow) -> [PanelState.LimitCell] {
        if case .cells(let cells) = row.content { return cells }
        return []
    }

    // Rules L7 and L8.
    @Test func noQuotaWithTheQuerySwitchedOffSaysHowToGetOne() {
        let limits = limits([])
        #expect(limits.rows.isEmpty)
        #expect(limits.age == nil)
        #expect(limits.say == say("limit.say.noQuota"))
        #expect(limits.tone == .plain)
    }

    @Test func noQuotaWithTheQuerySwitchedOnIsWaiting() {
        #expect(limits([], query: true).say == say("limit.say.waiting"))
    }

    // Rule L4.
    @Test func allClearSaysSoPlainly() {
        let limits = limits([quota(), quota(.openai, outcome: .idle)])
        #expect(limits.say == say("limit.say.clear"))
        #expect(limits.tone == .plain)
    }

    // Rule L5.
    @Test func aStaleFigureIsNotAllClear() {
        #expect(limits([quota(), quota(.openai, isStale: true)]).say == say("limit.say.noRisk"))
    }

    @Test func anUnknownForecastIsNotAllClear() {
        #expect(limits([quota(outcome: .unknown)]).say == say("limit.say.noRisk"))
    }

    // Rule L6.
    @Test func onlyOldDataSaysSo() {
        let limits = limits([quota(.openai, percent: 0, outcome: .unknown, recent: false)])
        #expect(limits.say == say("limit.say.noRecent"))
        #expect(limits.age == nil)
    }

    // Rule L1.
    @Test func aLimitAtTheRoundedTopIsUsedUp() throws {
        let text = try #require(limits([quota(percent: 99.6)]).say)
        #expect(text.contains(Labels.limitName(quota().snapshot)))
        #expect(text.contains(Labels.clock(quota().resetsAt)))
        #expect(limits([quota(percent: 99.6)]).tone == .critical)
    }

    // Rule L2.
    @Test func ninetyPercentWithNoRunOutSaysItsFigure() throws {
        let limits = limits([quota(percent: 92)])
        let text = try #require(limits.say)
        #expect(text.contains("92%"))
        #expect(limits.tone == .critical)
    }

    @Test func usedUpOutranksAtNinety() throws {
        let text = try #require(limits([quota(.openai, percent: 92), quota(percent: 100)]).say)
        #expect(text.contains(Labels.provider(.anthropic)))
        #expect(!text.contains("92%"))
    }

    // Rule L3.
    @Test func theSoonestRunOutIsNamed() throws {
        let soon = now.addingTimeInterval(1_800)
        let later = now.addingTimeInterval(3_600)
        let limits = limits([quota(.openai, outcome: .runsOut(at: later, beforeReset: 3_600)), quota(.anthropic, .weekly, scope: "Fable", outcome: .runsOut(at: soon, beforeReset: 5_400))])
        let text = try #require(limits.say)
        #expect(text.contains("Fable"))
        #expect(text.contains(Labels.clock(soon)))
        #expect(text.contains(Labels.duration(5_400)))
        #expect(limits.tone == .warning)
    }

    @Test func ninetyAndRunningOutIsARunOut() throws {
        let at = now.addingTimeInterval(600)
        let limits = limits([quota(percent: 92, outcome: .runsOut(at: at, beforeReset: 600))])
        #expect(limits.say?.contains(Labels.clock(at)) == true)
    }

    @Test func oldDataNeverSpeaksForALimit() {
        let at = now.addingTimeInterval(600)
        let limits = limits([quota(outcome: .runsOut(at: at, beforeReset: 600), recent: false), quota(.openai)])
        #expect(limits.say == say("limit.say.noRisk"))
    }

    // No word of ClaudeBar's.
    @Test func theRetiredWordingIsGone() {
        for key: String.LocalizationValue in ["limit.say.pace", "limit.say.usedUp", "limit.say.clear", "limit.say.noRisk"] {
            let text = String(localized: key, bundle: .tacho)
            for phrase in ["Runs out in", "Lasts until", "Resets in", "On track", "Running hot", "Room to spare"] {
                #expect(!text.contains(phrase))
            }
        }
    }

    @Test func aProviderIsOneRowWithACellForEachLimit() {
        let limits = limits([quota(), quota(.anthropic, .weekly), quota(.anthropic, .weekly, scope: "Fable"), quota(.openai)])
        #expect(limits.rows.map(\.name) == ["Anthropic", Labels.provider(.openai)])
        #expect(cells(limits.rows[0]).map(\.label) == [say("limit.short.fiveHour"), say("limit.short.week"), "Fable"])
    }

    @Test func aCellCarriesItsFigure() throws {
        let cell = try #require(cells(limits([quota(percent: 64)]).rows[0]).first)
        #expect(cell.percent == "64%")
        #expect(cell.value == 0.64)
        #expect(cell.level == .normal)
    }

    @Test func theAgeIsSaidOnceForTheNewestFigure() throws {
        let limits = limits([quota(age: 600), quota(.openai, age: 120)])
        let age = try #require(limits.age)
        #expect(age.contains("2"))
    }

    @Test func aLimitThatWillRunOutIsAmber() throws {
        let cell = try #require(cells(limits([quota(outcome: .runsOut(at: now.addingTimeInterval(600), beforeReset: 600))]).rows[0]).first)
        #expect(cell.level == .warning)
    }

    @Test func ninetyPercentIsRed() {
        #expect(cells(limits([quota(percent: 92)]).rows[0]).first?.level == .critical)
    }

    @Test func aStaleFigureSaysItsAgeAndHasNoTick() throws {
        let cell = try #require(cells(limits([quota(isStale: true, age: 7 * 86_400)]).rows[0]).first)
        #expect(cell.level == .stale)
        #expect(cell.caption.contains("7"))
        #expect(cell.pace == nil)
    }

    @Test func theTickIsWhereEvenUseWouldBe() throws {
        // Two hours left of five: three fifths gone.
        let cell = try #require(cells(limits([quota()]).rows[0]).first)
        #expect(abs((cell.pace ?? 0) - 0.6) < 0.001)
    }

    @Test func theAgeIgnoresStaleFigures() {
        let limits = limits([quota(isStale: true, age: 30), quota(.openai, age: 600)])
        #expect(limits.age?.contains("10") == true)
    }

    @Test func aCellSaysWhenItsLimitResets() throws {
        let quota = quota()
        let cell = try #require(cells(limits([quota]).rows[0]).first)
        #expect(cell.caption == Labels.reset(quota.resetsAt, now: now))
    }

    @Test func aLaterResetCarriesItsDay() {
        let date = now.addingTimeInterval(3 * 86_400)
        #expect(Labels.reset(date, now: now) != Labels.clock(date))
    }

    @Test func noRecentDataHasNoFigure() throws {
        let limits = limits([quota(.openai, percent: 0, outcome: .unknown, age: 15 * 86_400, recent: false), quota(.openai, .weekly, percent: 0, outcome: .unknown, age: 15 * 86_400, recent: false)])
        #expect(limits.rows.count == 1)
        #expect(limits.rows[0].name == Labels.provider(.openai))
        guard case .message(let text) = limits.rows[0].content else {
            Issue.record("expected a message")
            return
        }
        #expect(!text.contains("%"))
        #expect(text.contains("15"))
    }

    @Test func aWeeklyRunOutCarriesItsDay() throws {
        let at = now.addingTimeInterval(3 * 86_400)
        let text = try #require(limits([quota(.anthropic, .weekly, outcome: .runsOut(at: at, beforeReset: 600))]).say)
        #expect(text.contains(Labels.reset(at, now: now)))
    }

    @Test func anAlertWinsOverStale() {
        let limits = limits([quota(percent: 92, isStale: true)])
        #expect(cells(limits.rows[0]).first?.level == .critical)
    }

    @Test func aProviderCanHaveBoth() {
        let limits = limits([quota(), quota(.anthropic, .weekly, outcome: .unknown, age: 15 * 86_400, recent: false)])
        #expect(limits.rows.count == 2)
        #expect(cells(limits.rows[0]).count == 1)
        #expect(limits.rows[1].content == .message("No recent quota data · last figure 15 d ago"))
        // Both rows carry the provider's name, and `ForEach` needs them apart.
        #expect(Set(limits.rows.map(\.id)).count == 2)
    }

    /// The line names no limit, so two would read the same: they are one, with the newest figure.
    @Test func twoOldLimitsBesideARecentOneAreOneLine() {
        let limits = limits([
            quota(),
            quota(.anthropic, .weekly, outcome: .unknown, age: 15 * 86_400, recent: false),
            quota(.anthropic, .weekly, scope: "Fable", outcome: .unknown, age: 10 * 86_400, recent: false),
        ])
        #expect(limits.rows.count == 2)
        #expect(limits.rows[1].content == .message("No recent quota data · last figure 10 d ago"))
    }
}
