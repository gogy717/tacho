import Foundation
import Testing
@testable import Tacho
import TachoKit

/// What the Limits page says: spec section 12.5.
struct LimitsStateTests {
    private let now = WindowSamples.now

    private func state(
        _ quotas: [Projection],
        sources: [SourceRow] = [],
        insight: LimitsInsight? = nil,
        selected: LimitKey? = nil,
        history: LimitHistory? = nil
    ) -> LimitsState {
        LimitsState(
            dashboard: WindowSamples.dashboard(quotas: quotas, sources: sources),
            insights: insight,
            selected: selected,
            record: LimitsState.chosen(of: quotas, selected: selected, insights: insight).flatMap { limit in
                history.map { LimitRecord(of: limit, history: $0) }
            },
            now: now
        )
    }

    private let five = WindowSamples.projection(percent: 64, outcome: .runsOut(at: WindowSamples.now + 4_200, beforeReset: 5_100))
    private let week = WindowSamples.projection(window: .weekly, percent: 41)

    @Test func whatThePersonPickedStandsOverTheRules() {
        let state = state([five, week], insight: LimitsInsight(rule: .l3, limit: five), selected: LimitKey(week.snapshot))
        #expect(state.selected == LimitKey(week.snapshot))
        #expect(state.selectedName == "Anthropic weekly")
    }

    @Test func withNothingPickedTheRulesChoose() {
        #expect(state([week, five], insight: LimitsInsight(rule: .l3, limit: five)).selected == LimitKey(five.snapshot))
    }

    @Test func aPickGoneFromTheListFallsBack() {
        let gone = LimitKey(WindowSamples.projection(provider: .xai, percent: 1).snapshot)
        #expect(state([five], selected: gone).selected == LimitKey(five.snapshot))
    }

    @Test func runningOutAddsWhenAndHowLongWithoutAny() {
        let state = state([five], selected: LimitKey(five.snapshot))
        #expect(state.stats.map(\.label) == ["Used so far", "Empties at this pace", "Resets"])
        #expect(state.stats[1].tone == .warning)
        #expect(state.captions.count == 4)
        #expect(state.captions[2] == "1 h 25 min with nothing left")
    }

    /// The figures above give the two times, and this caption the gap between them.
    @Test func theCaptionsGapIsWhatTheTwoTimesSubtractTo() {
        for gap in WindowSamples.gaps {
            let quota = WindowSamples.projection(empties: gap.empties, resets: gap.resets)
            #expect(state([quota], selected: LimitKey(quota.snapshot)).captions[2] == "\(gap.short) with nothing left")
        }
    }

    @Test func lastingHasNoEmptiesFigure() {
        let state = state([week])
        #expect(state.stats.map(\.label) == ["Used so far", "Resets"])
        #expect(state.captions.count == 3)
    }

    @Test func aLimitWithNoRecentDataHidesItsChartsAndKeepsTheList() {
        let old = WindowSamples.projection(provider: .openai, percent: 14, hasRecentData: false)
        let state = state([five, old], selected: LimitKey(old.snapshot))
        #expect(state.stats.isEmpty)
        #expect(state.runway == nil)
        #expect(state.message?.hasPrefix("No recent quota data") == true)
        #expect(state.rows.count == 2)
        #expect(state.rows[1].message != nil)
    }

    @Test func aLimitWithNoRecentDataKeepsItsRightColumn() {
        let old = WindowSamples.projection(provider: .openai, percent: 14, hasRecentData: false)
        let history = LimitHistory(windows: (0..<6).map { .init(resetsAt: WindowSamples.now - Double(6 - $0) * 18_000, peak: 40) })
        let state = state([five, old], selected: LimitKey(old.snapshot), history: history)
        #expect(state.stats.isEmpty)
        #expect(state.runway == nil)
        #expect(state.highlights == ["Recent windows peaked around 40%."])
        #expect(!state.how.isEmpty)
    }

    @Test func staleAndClearGoesGrey() {
        let state = state([WindowSamples.projection(percent: 40, isStale: true)])
        #expect(state.rows.first?.level == .stale)
        #expect(state.stats.first?.note == "may be out of date")
    }

    @Test func aWarningWinsOverStaleSoTheBarAgreesWithTheIcon() {
        let stale = WindowSamples.projection(percent: 95, outcome: .runsOut(at: WindowSamples.now + 100, beforeReset: 9_000), isStale: true)
        #expect(state([stale]).rows.first?.level != .stale)
        #expect(state([stale]).rows.first?.level != .normal)
    }

    @Test func aStaleLimitDrawsNoEvenPaceTick() {
        #expect(state([WindowSamples.projection(percent: 40, isStale: true)]).rows.first?.pace == nil)
        #expect(state([WindowSamples.projection(percent: 40)]).rows.first?.pace != nil)
    }

    @Test func aWindowAverageSaysSoBesideTheFigure() {
        let quota = WindowSamples.projection(percent: 41, method: .windowAverage)
        #expect(state([quota]).stats.first?.note == "estimated from the window average")
    }

    @Test func usedUpIsRedAndSaysSoFirst() {
        let quota = WindowSamples.projection(percent: 100, outcome: .runsOut(at: WindowSamples.now, beforeReset: 9_300))
        let state = state([quota])
        #expect(state.stats.first?.tone == .critical)
        #expect(state.stats.map(\.label) == ["Used so far", "Resets"])
        #expect(state.highlights.count == 1)
    }

    @Test func noSnapshotsWithTheQueryOffOffersSettings() {
        let state = state([], insight: LimitsInsight(rule: .l7, limit: nil))
        #expect(state.rows.isEmpty)
        #expect(state.offersSettings)
        #expect(state.message == "No quota data yet. Turn on the Claude quota query in Settings.")
    }

    @Test func noSnapshotsWithTheQueryOnJustWaits() {
        let state = state([], insight: LimitsInsight(rule: .l8, limit: nil))
        #expect(!state.offersSettings)
        #expect(state.message == "Waiting for the first quota reading.")
    }

    @Test func withNoAnswerYetItSaysNothingRatherThanGuess() {
        let state = state([])
        #expect(state.message == nil)
        #expect(!state.offersSettings)
    }

    @Test func usedUpSpeaksOfTheLimitOnThePageNotTheOneTheRulesPicked() {
        let used = WindowSamples.projection(window: .weekly, percent: 100, outcome: .runsOut(at: WindowSamples.now, beforeReset: 9_300))
        let state = state([five, used], insight: LimitsInsight(rule: .l3, limit: five), selected: LimitKey(used.snapshot))
        #expect(state.highlights.first?.hasPrefix("Anthropic weekly is used up.") == true)
    }

    @Test func onlyCLIsInUseTodayCountAsHavingNoQuota() {
        // `hasQuota` is false for anything unused today, so without the use check every idle CLI would be listed.
        let state = state([five], sources: [
            WindowSamples.source(.codex, today: WindowSamples.tokens, usd: 8),
            WindowSamples.source(.opencode),
            WindowSamples.source(.claudeCode, today: WindowSamples.tokens, usd: 80, hasQuota: true),
        ])
        #expect(state.noQuota.map(\.name) == ["Codex"])
        #expect(state.noQuota.first?.figure == "≈ $2.00/h")
    }

    @Test func theRecordFeedsTheRunwayAndTheBars() {
        let history = LimitHistory(
            readings: [.init(time: WindowSamples.now - 1_000, percent: 50)],
            windows: [.init(resetsAt: WindowSamples.now - 90_000, peak: 100), .init(resetsAt: WindowSamples.now + 9_300, peak: 64)]
        )
        let state = state([five], history: history)
        #expect(state.runway?.hasReadings == true)
        #expect(state.windows.count == 2)
    }

    /// A click moves the page on at once, and the record read for the last limit is still there. Drawn under the new name, it would say
    /// something false of it, so it is the limit a record was read for that decides, and not the order things happen in.
    @Test func anotherLimitsRecordIsNotDrawn() {
        let weekly = WindowSamples.projection(window: .weekly, percent: 41)
        let history = LimitHistory(
            readings: [.init(time: WindowSamples.now - 1_000, percent: 50)],
            windows: (0..<6).map { .init(resetsAt: WindowSamples.now - Double(6 - $0) * 18_000, peak: 40) }
        )
        let state = LimitsState(
            dashboard: WindowSamples.dashboard(quotas: [five, weekly]),
            insights: nil,
            selected: LimitKey(weekly.snapshot),
            record: LimitRecord(of: five, history: history),
            now: now
        )
        #expect(state.selectedName == Labels.limitName(weekly.snapshot))
        #expect(state.runway?.hasReadings == false)
        #expect(state.windows.isEmpty)
        #expect(state.highlights.isEmpty)
    }

    /// The page's clock can be a minute behind the engine's, so it is the engine that says a window has reset: on the page's clock this
    /// one has not, and with its percent back to nothing the row read "+-64% from local use".
    @Test func aResetTheEngineHasSeenIsSaidBeforeThePagesClockGetsThere() {
        var over = WindowSamples.projection(percent: 64)
        over.estimatedPercent = 0
        over.isEstimate = true
        over.resetsAt = over.snapshot.resetsAt + over.snapshot.window.length
        let clock = over.snapshot.resetsAt - 30
        let state = LimitsState(dashboard: WindowSamples.dashboard(quotas: [over]), insights: nil, selected: nil, record: nil, now: clock)
        #expect(state.how[2].value == "the window has reset since")
    }

    /// With nothing picked the rules name the limit, and their answer is only as new as the last read. The figures' own row is newer.
    @Test func aLimitTheRulesPickTakesItsFiguresFromTheDashboard() {
        var row = WindowSamples.projection(percent: 64)
        row.estimatedPercent = 0
        row.isEstimate = true
        row.resetsAt = row.snapshot.resetsAt + row.snapshot.window.length
        let answer = LimitsInsight(rule: .l1, limit: WindowSamples.projection(percent: 64))
        let state = state([row], insight: answer)
        #expect(state.how[2].value == "the window has reset since")
    }

    @Test func aLimitTheRulesPickWithNoRowIsStillTheirs() {
        let answer = LimitsInsight(rule: .l1, limit: WindowSamples.projection(window: .weekly, percent: 41))
        #expect(LimitsState.chosen(of: [five], selected: nil, insights: answer) == answer.limit)
    }

    @Test func whatIsPickedComesBeforeWhatTheRulesName() {
        let weekly = WindowSamples.projection(window: .weekly, percent: 41)
        let answer = LimitsInsight(rule: .l1, limit: five)
        #expect(LimitsState.chosen(of: [five, weekly], selected: LimitKey(weekly.snapshot), insights: answer) == weekly)
    }

    /// A pick that has gone is no pick.
    @Test func aPickThatHasGoneGivesWayToTheRules() {
        let weekly = WindowSamples.projection(window: .weekly, percent: 41)
        let answer = LimitsInsight(rule: .l1, limit: five)
        #expect(LimitsState.chosen(of: [five], selected: LimitKey(weekly.snapshot), insights: answer) == five)
    }

    @Test func withNoAnswerTheFirstLimitWithRecentDataIsChosen() {
        let old = WindowSamples.projection(provider: .openai, percent: 14, hasRecentData: false)
        #expect(LimitsState.chosen(of: [old, five], selected: nil, insights: nil) == five)
    }

    /// The page reads a record for the limit `chosen` gives and draws it for the limit `chosen` gives. Were the two ever to part, every
    /// record would go blank and nothing would say so.
    @Test func aRecordReadForTheRulesLimitIsDrawnUnderIt() {
        let weekly = WindowSamples.projection(window: .weekly, percent: 41)
        let answer = LimitsInsight(rule: .l1, limit: WindowSamples.projection(window: .weekly, percent: 41))
        let history = LimitHistory(
            readings: [.init(time: WindowSamples.now - 1_000, percent: 50)],
            windows: [.init(resetsAt: WindowSamples.now - 90_000, peak: 100), .init(resetsAt: WindowSamples.now + 9_300, peak: 60)]
        )
        let state = state([five, weekly], insight: answer, history: history)
        #expect(state.selected == LimitKey(weekly.snapshot))
        #expect(state.windows.count == 2)
    }

    /// A window that has not reset says what has changed since the reading, as it always did.
    @Test func aWindowThatHasNotResetSaysWhatHasChanged() {
        var rising = WindowSamples.projection(percent: 64)
        rising.estimatedPercent = 70
        rising.isEstimate = true
        let state = LimitsState(dashboard: WindowSamples.dashboard(quotas: [rising]), insights: nil, selected: nil, record: nil, now: now)
        #expect(state.how[2].value == "+6% from local use")
    }

    @Test func theRecordSaysRulesLHAfterAnyUsedUpSentence() {
        let history = LimitHistory(windows: (0..<6).map { .init(resetsAt: WindowSamples.now - Double(6 - $0) * 18_000, peak: 40) })
        let clear = state([WindowSamples.projection(percent: 20)], history: history)
        #expect(clear.highlights == ["Recent windows peaked around 40%."])
        let used = WindowSamples.projection(percent: 100, outcome: .runsOut(at: WindowSamples.now, beforeReset: 9_300))
        let full = state([used], history: history)
        #expect(full.highlights.first?.contains("is used up.") == true)
        #expect(full.highlights.count > 1)
    }

    @Test func howItIsMadeSaysWhereTheFigureCameFrom() {
        var quota = five
        quota.snapshot.plan = "Max 20x"
        let how = state([quota]).how
        #expect(how.map(\.label) == ["Last reading", "From", "Since then", "Pace taken from", "Method", "Plan"])
        #expect(how[0].value == "64%, 2 min ago")
        #expect(how[1].value == "Anthropic usage request")
        #expect(how[2].value == "no change")
        #expect(how[3].value == "the last 30 minutes")
        #expect(how[5].value == "Max 20x")
    }
}
