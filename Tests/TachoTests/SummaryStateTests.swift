import Foundation
import Testing
@testable import Tacho
import TachoKit

/// What Summary says: spec section 11.
struct SummaryStateTests {
    private let now = WindowSamples.now

    private func preferences(_ pinned: [PinnedCard]? = nil) -> Preferences {
        var preferences = Preferences.defaults(home: URL(fileURLWithPath: "/nonexistent"))
        if let pinned { preferences.pinnedCards = pinned }
        return preferences
    }

    private func insights(week: WeekRule = .w1(percent: 20), limit: Projection? = nil) -> PanelInsights {
        PanelInsights(
            results: InsightResults(
                today: TodayInsight(rule: .h2(soFar: 3), metric: .cost, value: 1, range: nil, verdict: .none),
                limits: LimitsInsight(rule: limit == nil ? .l6 : .l3, limit: limit),
                week: week,
                output: OutputInsight(rule: .p1, value: 1, range: nil),
                cache: nil,
                speed: nil,
                clis: nil,
                cacheReadPercent: nil,
                when: nil
            ),
            daysOfUse: 14
        )
    }

    private func state(
        quotas: [Projection] = [],
        sources: [SourceRow] = [],
        insights: PanelInsights? = nil,
        week: Loaded<DetailFigures> = .loading,
        pinned: [PinnedCard]? = nil,
        blocked: Bool = false,
        tokens: TokenCounts = .zero
    ) -> SummaryState {
        SummaryState(
            dashboard: WindowSamples.dashboard(quotas: quotas, sources: sources, today: tokens, usd: 98.74),
            insights: insights,
            day: nil,
            week: week,
            preferences: preferences(pinned),
            menuBarBlocked: blocked,
            now: now
        )
    }

    /// Output of 1 to 7 over the 7 days before, and 11 to 17 over the last 7.
    private func weekFigures() -> DetailFigures {
        var figures = WindowSamples.figures(range: .week)
        figures.previousColumns = figures.columns
        for index in figures.columns.indices {
            figures.previousColumns[index].tokens.output = index + 1
            figures.columns[index].tokens.output = index + 11
        }
        return figures
    }

    @Test func theEnginesLimitIsTheCard() {
        let low = WindowSamples.projection(percent: 20)
        let high = WindowSamples.projection(window: .weekly, percent: 70)
        #expect(state(quotas: [high, low], insights: insights(limit: low)).limit?.key == LimitKey(low.snapshot))
    }

    @Test func untilTheEngineAnswersNoLimitIsPicked() {
        // Which limit matters is the engine's to say.
        let state = state(quotas: [WindowSamples.projection(percent: 70)])
        #expect(state.limit == nil)
        #expect(state.limitsSay == nil)
    }

    @Test func withNoLimitToNameThereIsNoChart() {
        let state = state(quotas: [WindowSamples.projection(percent: 90, hasRecentData: false)], insights: insights(limit: nil))
        #expect(state.limit == nil)
        #expect(state.limitsSay == "No recent quota data.")
    }

    @Test func theLimitCardNamesItsLimitAndSaysTheEnginesRule() {
        let quota = WindowSamples.projection(percent: 20, outcome: .idle)
        let card = state(quotas: [quota], insights: insights(limit: quota)).limit
        #expect(card?.name == "Anthropic 5 hours")
        #expect(card?.sentence == "Clear for now: not in use.")
    }

    @Test func theBarsAreTheWeeksTheEngineCompares() throws {
        guard case .columns(let columns) = state(insights: insights(), week: .ready(weekFigures())).week else {
            Issue.record("no columns")
            return
        }
        #expect(columns.last == [11, 12, 13, 14, 15, 16, 17])
        #expect(columns.before == [1, 2, 3, 4, 5, 6, 7])
    }

    @Test(arguments: [WeekRule.w4(soFar: 9), .w6])
    func withNothingToCompareTheGreyColumnsGo(rule: WeekRule) throws {
        guard case .columns(let columns) = state(insights: insights(week: rule), week: .ready(weekFigures())).week else {
            Issue.record("no columns")
            return
        }
        #expect(columns.last.count == 7)
        #expect(columns.before.isEmpty)
    }

    @Test func withNoAnswerTheWeekMakesNoComparison() throws {
        // Which weeks can be compared is the engine's to say. Grey columns are forbidden under W4 and W6, and with no answer it could be either.
        guard case .columns(let columns) = state(week: .ready(weekFigures())).week else {
            Issue.record("no columns")
            return
        }
        #expect(columns.last.count == 7)
        #expect(columns.before.isEmpty)
    }

    @Test func aFailedInsightsReadKeepsWhatIsDrawn() {
        let quota = WindowSamples.projection(percent: 20)
        let answer = insights(limit: quota)
        let record = LimitHistory(readings: [.init(time: now - 100, percent: 10)])
        var reads = SummaryReads()
        reads.take(insights: answer, history: record)
        reads.take(insights: nil, history: nil)
        #expect(reads.insights == answer)
        #expect(reads.history == record)
    }

    @Test func aNewAnswerReplacesTheLastWithItsOwnRecord() {
        let record = LimitHistory(readings: [.init(time: now - 100, percent: 10)])
        var reads = SummaryReads()
        reads.take(insights: insights(week: .w3), history: record)
        reads.take(insights: insights(week: .w5), history: nil)
        #expect(reads.insights?.results.week == .w5)
        #expect(reads.history == nil)
    }

    @Test func aFailedDayReadKeepsTheBars() {
        let figures = WindowSamples.figures(range: .day, columns: 24)
        var reads = SummaryReads()
        reads.take(day: figures)
        reads.take(day: nil)
        #expect(reads.day == figures)
    }

    @Test func aFailedWeekReadIsAFailure() {
        var reads = SummaryReads()
        reads.take(week: nil)
        guard case .failed = reads.week else {
            Issue.record("not failed")
            return
        }
    }

    @Test func aLaterFailedWeekReadReplacesTheChart() {
        // As on every other page: an old chart under no warning would say more than Tacho knows.
        var reads = SummaryReads()
        reads.take(week: weekFigures())
        reads.take(week: nil)
        guard case .failed = reads.week else {
            Issue.record("kept the old chart")
            return
        }
    }

    @Test func untilTheEngineCanSayTheWeekWaitsWithNoSentence() {
        let state = state()
        #expect(state.week == .waiting)
        #expect(state.weekSentence == " ")
    }

    @Test func aFailedWeekReadSaysSoRatherThanWaitingForEver() {
        #expect(state(week: .failed).week == .failed)
    }

    @Test func everyPinnedCardShowsInOrderPastThePanelsFour() {
        let order: [PinnedCard] = [.when, .tokens, .clis, .speed, .cache, .output]
        let cards = state(pinned: order).cards
        #expect(cards.map(\.id) == order)
        #expect(cards.allSatisfy { !$0.title.isEmpty })
    }

    @Test func eachCardOpensItsPage() {
        let routes = Dictionary(uniqueKeysWithValues: state(pinned: PinnedCard.allCases).cards.map { ($0.id, $0.route) })
        #expect(routes[.output] == Route(page: .tokens, metric: .output, range: .day))
        #expect(routes[.tokens] == Route(page: .tokens, metric: .allTokens, range: .day))
        #expect(routes[.cache] == Route(page: .cache, range: .day))
        #expect(routes[.speed]?.page == .speed)
        #expect(routes[.clis] == Route(page: .cost, range: .day))
        #expect(routes[.when] == Route(page: .calendar))
    }

    @Test func noTokensTodaySaysSoRatherThanDrawingAnEmptyBar() {
        let card = state(pinned: [.tokens]).cards.first
        #expect(card?.value == "No data yet")
        guard case .none? = card?.visual else {
            Issue.record("drew something")
            return
        }
    }

    @Test func tokensShareOutInStackOrder() {
        let card = state(pinned: [.tokens], tokens: WindowSamples.tokens).cards.first
        guard case .shares(let parts)? = card?.visual else {
            Issue.record("no share bar")
            return
        }
        #expect(parts.count == 4)
        #expect(parts.first?.share == 0.97)
    }

    @Test func cliRowsGoByTheEnginesShareAndStayInMoney() {
        // Tokens, because something is unpriced: OpenCode leads though Claude Code cost more.
        var answer = insights()
        answer.results.clis = CLIShareInsight(source: .opencode, percent: 75, basis: .tokens)
        answer.clis = CLIFigures(shares: [.init(source: .opencode, fraction: 0.75), .init(source: .claudeCode, fraction: 0.25)])
        let sources = [
            WindowSamples.source(.claudeCode, today: WindowSamples.tokens, usd: 8),
            WindowSamples.source(.opencode, today: WindowSamples.tokens, usd: 1),
            WindowSamples.source(.pi),
        ]
        let card = state(sources: sources, insights: answer, pinned: [.clis]).cards.first
        guard case .rows(let rows, let more)? = card?.visual else {
            Issue.record("no rows")
            return
        }
        #expect(rows.map(\.name) == ["OpenCode", "Claude Code"])
        #expect(rows.map(\.figure) == ["$1.00", "$8.00"])
        #expect(rows.first?.fraction == 1)
        #expect(rows.last?.fraction == 0.25 / 0.75)
        #expect(more == 0)
        #expect(card?.title == "CLIs today")
        #expect(card?.value == nil)
        #expect(card?.say == "OpenCode: 75% of tokens")
    }

    @Test func aCLIThatIsNewSinceTheAnswerGoesLastWithNoBar() {
        var answer = insights()
        answer.clis = CLIFigures(shares: [.init(source: .claudeCode, fraction: 1)])
        let sources = [
            WindowSamples.source(.codex, today: WindowSamples.tokens, usd: 3),
            WindowSamples.source(.claudeCode, today: WindowSamples.tokens, usd: 8),
        ]
        guard case .rows(let rows, _)? = state(sources: sources, insights: answer, pinned: [.clis]).cards.first?.visual else {
            Issue.record("no rows")
            return
        }
        #expect(rows.map(\.name) == ["Claude Code", "Codex"])
        #expect(rows.map(\.fraction) == [1, nil])
    }

    @Test func aCLIGoneSinceTheAnswerLeavesNoRowAndTheTopBarStaysFull() {
        var answer = insights()
        answer.clis = CLIFigures(shares: [.init(source: .opencode, fraction: 0.75), .init(source: .claudeCode, fraction: 0.25)])
        let sources = [WindowSamples.source(.claudeCode, today: WindowSamples.tokens, usd: 8)]
        guard case .rows(let rows, _)? = state(sources: sources, insights: answer, pinned: [.clis]).cards.first?.visual else {
            Issue.record("no rows")
            return
        }
        #expect(rows.map(\.name) == ["Claude Code"])
        #expect(rows.first?.fraction == 1)
    }

    @Test func withNoAnswerCLIRowsCompareNothing() {
        let card = state(sources: [WindowSamples.source(.codex, today: WindowSamples.tokens, usd: 8)], pinned: [.clis]).cards.first
        guard case .rows(let rows, _)? = card?.visual else {
            Issue.record("no rows")
            return
        }
        #expect(rows.map(\.figure) == ["$8.00"])
        #expect(rows.first?.fraction == nil)
    }

    @Test func theRateStripIsOnlyForABlockedItem() {
        #expect(state(blocked: true).showsRate)
        #expect(!state(blocked: false).showsRate)
    }

    @Test func theFigureBesideTheSentenceIsCostBare() {
        #expect(state().todayFigure == "$98.74")
    }
}
