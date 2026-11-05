import Foundation
import Testing
@testable import TachoKit

/// `Reports` over a real store: sections 12 and 13.1 of `docs/design/direction-b-spec.md`.
struct ReportsTests {
    // MARK: Fixtures

    /// Sydney: 4 October 2026 skips 02:00 to 03:00; 5 April 2026 repeats 02:00 to 03:00.
    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        return calendar
    }

    private let utc = Self.calendar("UTC")
    private let sydney = Self.calendar("Australia/Sydney")
    /// Midday on a Wednesday, UTC.
    private let now = date("2026-06-17T12:30:00Z")
    private var today: Date { date("2026-06-17T00:00:00Z") }

    /// A local table, in which a million tokens read as whole dollars.
    private let prices: PriceTable

    init() throws {
        prices = try PriceTable(json: Data(#"""
        {"geoMultipliers":{},"models":[
         {"id":"priced","provider":"anthropic","price":{"input":1,"output":2,"cacheRead":0.5,"cacheWrite5m":1.5,"cacheWrite1h":1.5}}]}
        """#.utf8))
    }

    private func reports(
        _ store: EventStore,
        sources: Set<Source> = Set(Source.allCases),
        phase: IngestProgress.Phase = .live
    ) -> Reports {
        Reports(store: store, prices: prices, sources: sources, phase: phase)
    }

    private func use(
        _ name: String,
        at time: Date,
        source: Source = .claudeCode,
        client: String? = nil,
        model: String? = "priced",
        tokens: TokenCounts = TokenCounts(input: 1_000_000),
        isSubagent: Bool = false,
        generationMs: Double? = nil
    ) -> UsageEvent {
        UsageEvent(
            source: source, client: client, dedupKey: "\(source.rawValue):\(name)", project: "p", isSubagent: isSubagent, model: model,
            time: time, generationMs: generationMs, tokens: tokens
        )
    }

    private func storing(_ events: [UsageEvent]) throws -> EventStore {
        let store = try EventStore.inMemory()
        try store.upsert(events)
        return store
    }

    /// The columns of `figures` with any tokens.
    private func columnsWithUse(_ figures: DetailFigures) -> [Int] {
        figures.columns.indices.filter { figures.columns[$0].tokens.total > 0 }
    }

    private func days(_ count: Int, before day: Date, calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? utc
        return calendar.startOfDay(for: calendar.date(byAdding: .day, value: -count, to: day) ?? day)
    }

    private func detail(
        _ range: DetailRange,
        _ events: [UsageEvent],
        curves: [DayCurve] = [],
        now: Date? = nil,
        calendar: Calendar? = nil
    ) async throws -> DetailFigures {
        try await reports(storing(events)).detail(range: range, curves: curves, now: now ?? self.now, calendar: calendar ?? utc)
    }

    // MARK: Empty

    @Test(arguments: [(DetailRange.day, 24), (.week, 7), (.month, 30), (.year, 12)])
    func anEmptyStoreStillHasItsColumns(range: DetailRange, columns: Int) async throws {
        let figures = try await detail(range, [])
        #expect(figures.range == range)
        #expect(figures.columns.count == columns)
        #expect(figures.totals == PeriodTotals())
        #expect(figures.bySource.isEmpty)
        #expect(figures.byModel.isEmpty)
        #expect(figures.clientsBySource.isEmpty)
        #expect(figures.cacheSaving == .zero)
        #expect(figures.medianCost == nil)
        #expect(figures.daysOfUse == 0)
        #expect(figures.usualCost == UsualBands())
        #expect(!figures.previousIsFull)
    }

    // MARK: Ranges

    @Test func dayIsTheHoursOfToday() async throws {
        let figures = try await detail(.day, [
            use("yesterday", at: today.addingTimeInterval(-1)),
            use("midnight", at: today),
            use("noon", at: today.addingTimeInterval(12 * 3_600 + 59)),
            use("last", at: today.addingTimeInterval(86_399)),
            use("tomorrow", at: today.addingTimeInterval(86_400)),
        ])
        #expect(figures.columns.map(\.start) == (0..<24).map { today.addingTimeInterval(Double($0) * 3_600) })
        #expect(columnsWithUse(figures) == [0, 12, 23])
        #expect(figures.totals.tokens.input == 3_000_000)
        #expect(figures.totals.daysWithUse == 1)
        #expect(figures.previous == nil)
        #expect(figures.previousColumns.isEmpty)
        #expect(figures.currentColumn == 12)
    }

    @Test func weekIsTheLastSevenDaysCountingToday() async throws {
        let figures = try await detail(.week, [
            use("oldest", at: days(6, before: today)),
            use("too old", at: days(6, before: today).addingTimeInterval(-1)),
            use("last of today", at: days(-1, before: today).addingTimeInterval(-1)),
            use("tomorrow", at: days(-1, before: today)),
        ])
        #expect(figures.columns.map(\.start) == (0...6).reversed().map { days($0, before: today) })
        #expect(figures.previousColumns.map(\.start) == (7...13).reversed().map { days($0, before: today) })
        #expect(figures.columns.first?.tokens.input == 1_000_000)
        #expect(figures.columns.last?.tokens.input == 1_000_000)
        #expect(figures.totals.tokens.input == 2_000_000)
        #expect(figures.totals.daysWithUse == 2)
        #expect(figures.currentColumn == 6)
    }

    @Test func monthIsTheLastThirtyDaysCountingToday() async throws {
        let figures = try await detail(.month, [
            use("today", at: today),
            use("oldest", at: days(29, before: today)),
            use("too old", at: days(29, before: today).addingTimeInterval(-1)),
        ])
        #expect(figures.columns.map(\.start) == (0...29).reversed().map { days($0, before: today) })
        #expect(figures.previousColumns.map(\.start) == (30...59).reversed().map { days($0, before: today) })
        #expect(figures.totals.tokens.input == 2_000_000)
        #expect(figures.currentColumn == 29)
    }

    /// Today is under way, so the period before ends at the time of day it is now: as much of its last day as there is of today.
    @Test(arguments: [(DetailRange.week, 7), (.month, 30)])
    func thePeriodBeforeEndsAtThisTimeOfDay(range: DetailRange, length: Int) async throws {
        let cut = days(length, before: today).addingTimeInterval(12 * 3_600 + 30 * 60)
        let figures = try await detail(range, [
            use("first", at: days(2 * length - 1, before: today)),
            use("too old", at: days(2 * length - 1, before: today).addingTimeInterval(-1)),
            use("before the cut", at: cut.addingTimeInterval(-1)),
            use("at the cut", at: cut),
        ])
        #expect(figures.previousColumns.first?.tokens.input == 1_000_000)
        #expect(figures.previousColumns.last?.tokens.input == 1_000_000)
        #expect(figures.previous?.tokens.input == 2_000_000)
        #expect(figures.previous?.requests == 2)
        #expect(figures.totals == PeriodTotals())
    }

    /// The same use every day at `hours` past midnight, over the `count` days to today, up to `now`.
    private func everyDay(at hours: [Double], back count: Int, until now: Date) -> [UsageEvent] {
        let times = (0..<count).flatMap { day in hours.map { days(day, before: today).addingTimeInterval($0 * 3_600) } }
        return times.filter { $0 <= now }.enumerated().map { use("use \($0.offset)", at: $0.element) }
    }

    /// The same use every day, seen in the morning, late in the evening, just past midnight, and before any of today's: the week so far
    /// and as much of the one before add up the same, so a morning reads as no fall.
    @Test(arguments: [(9.0, [8.0, 20.0], 13), (23.5, [8.0, 23.75], 13), (5.0 / 60, [3.0 / 60, 12.0], 13), (9.0, [12.0], 6)])
    func steadyUseIsAboutTheSameAtAnyTimeOfDay(hour: Double, uses: [Double], each: Int) async throws {
        let seen = today.addingTimeInterval(hour * 3_600)
        let figures = try await detail(.week, everyDay(at: uses, back: 14, until: seen), now: seen)
        #expect(figures.totals.tokens.input == each * 1_000_000)
        #expect(figures.previous?.tokens.input == each * 1_000_000)
        #expect(figures.previousIsFull)
        #expect(figures.highlights.cost.contains(.d6))
    }

    /// The same time of day is the same on the clock: across a clock change, a week back is not 168 hours.
    @Test(arguments: [
        // Seen at 10:00 on 4 October, 23 hours long: the cut is 10:00 on 27 September, an hour after 168 hours back.
        (date("2026-10-03T23:00:00Z"), date("2026-09-26T23:30:00Z"), date("2026-09-27T00:00:00Z")),
        // Seen at 10:00 on 5 April, 25 hours long: the cut is 10:00 on 29 March, an hour before.
        (date("2026-04-05T00:00:00Z"), date("2026-03-28T22:30:00Z"), date("2026-03-28T23:30:00Z")),
    ])
    func acrossAClockChangeThePeriodBeforeEndsAtTheSameClockTime(seen: Date, inside: Date, outside: Date) async throws {
        let figures = try await detail(.week, [use("inside", at: inside), use("outside", at: outside)], now: seen, calendar: sydney)
        #expect(figures.previous?.tokens.input == 1_000_000)
        #expect(figures.totals == PeriodTotals())
    }

    @Test func yearIsTheLastTwelveCalendarMonthsThisOneLast() async throws {
        let figures = try await detail(.year, [
            use("this month", at: today),
            use("first", at: date("2025-07-01T00:00:00Z")),
            use("before", at: date("2025-06-30T23:59:59Z")),
            use("another", at: date("2025-07-02T00:00:00Z")),
            use("just after asking", at: now.addingTimeInterval(1)),
        ])
        #expect(figures.columns.count == 12)
        #expect(figures.columns.first?.start == date("2025-07-01T00:00:00Z"))
        #expect(figures.columns.last?.start == date("2026-06-01T00:00:00Z"))
        #expect(figures.columns.first?.tokens.input == 2_000_000)
        #expect(figures.columns.last?.tokens.input == 2_000_000)
        #expect(figures.totals.daysWithUse == 3)
        #expect(figures.previous == nil)
    }

    // MARK: Daylight saving

    /// A skipped hour stays flat, and there are still 24 columns: section 8.1.
    @Test func theDayClocksGoForwardHasTwentyFourHoursWithTheSkippedOneEmpty() async throws {
        let day = date("2026-10-03T14:00:00Z")
        let figures = try await detail(.day, [
            use("before", at: date("2026-10-03T15:30:00Z")),
            use("after", at: date("2026-10-03T16:30:00Z")),
        ], now: date("2026-10-04T02:00:00Z"), calendar: sydney)
        #expect(figures.columns.count == 24)
        #expect(figures.columns.first?.start == day)
        #expect(columnsWithUse(figures) == [1, 3])
    }

    /// A repeated hour adds to its slots.
    @Test func theDayClocksGoBackAddsTheRepeatedHour() async throws {
        let figures = try await detail(.day, [
            use("first", at: date("2026-04-04T15:30:00Z")),
            use("second", at: date("2026-04-04T16:30:00Z")),
        ], now: date("2026-04-05T02:00:00Z"), calendar: sydney)
        #expect(figures.columns.count == 24)
        #expect(figures.columns[2].tokens.input == 2_000_000)
        #expect(figures.totals.tokens.input == 2_000_000)
    }

    /// Columns 2 and 3 share a start on this day, and the hour that happened is 3.
    @Test func theCurrentHourIsTheOneThatHappenedTheDayClocksGoForward() async throws {
        let beforeIt = try await detail(.day, [], now: date("2026-10-03T15:30:00Z"), calendar: sydney)
        let atIt = try await detail(.day, [], now: date("2026-10-03T16:00:00Z"), calendar: sydney)
        let afterIt = try await detail(.day, [], now: date("2026-10-03T16:30:00Z"), calendar: sydney)
        #expect(beforeIt.currentColumn == 1)
        #expect(atIt.currentColumn == 3)
        #expect(afterIt.currentColumn == 3)
    }

    @Test func theCurrentHourIsTheOneRepeatedWhileInIt() async throws {
        let figures = try await detail(.day, [], now: date("2026-04-04T16:30:00Z"), calendar: sydney)
        #expect(figures.currentColumn == 2)
    }

    /// Havana goes forward at midnight, so that day starts at 01:00.
    @Test func aDayWithNoMidnightHasItsTwentyFourHoursToo() async throws {
        let figures = try await detail(.day, [use("first", at: date("2026-03-08T05:30:00Z"))], now: date("2026-03-08T16:00:00Z"), calendar: Self.calendar("America/Havana"))
        #expect(figures.columns.count == 24)
        #expect(figures.columns[0].tokens.input == 0)
        #expect(figures.columns[1].tokens.input == 1_000_000)
    }

    /// A week across a clock change is still 7 local days, one of them 23 hours long.
    @Test func aWeekAcrossAClockChangeKeepsLocalDays() async throws {
        let tuesday = date("2026-10-05T14:00:00Z")
        let figures = try await detail(.week, [
            use("start of the short day", at: date("2026-10-03T14:00:00Z")),
            use("end of the short day", at: date("2026-10-04T12:59:59Z")),
            use("next day", at: date("2026-10-04T13:00:00Z")),
        ], now: tuesday, calendar: sydney)
        let local = figures.columns.map { sydney.dateComponents([.day, .hour], from: $0.start) }
        #expect(local.map(\.hour) == Array(repeating: 0, count: 7))
        #expect(local.map(\.day) == [30, 1, 2, 3, 4, 5, 6])
        #expect(figures.columns[4].tokens.input == 2_000_000)
        #expect(figures.columns[5].tokens.input == 1_000_000)
    }

    @Test func aYearAcrossAClockChangeKeepsLocalMonths() async throws {
        let figures = try await detail(.year, [
            use("first of July, local", at: date("2025-06-30T14:00:00Z")),
            use("last of June, local", at: date("2025-06-30T13:59:59Z")),
        ], now: date("2026-06-17T00:00:00Z"), calendar: sydney)
        #expect(figures.columns.first?.start == date("2025-06-30T14:00:00Z"))
        #expect(figures.totals.tokens.input == 1_000_000)
    }

    // MARK: Enabled sources

    @Test func aDisabledSourceCountsForNothing() async throws {
        let yesterday = today.addingTimeInterval(-3_600)
        let store = try storing([
            use("on", at: yesterday, tokens: TokenCounts(input: 1_000_000)),
            use("off", at: yesterday, source: .codex, client: "desk", tokens: TokenCounts(input: 5_000_000, cacheRead: 1_000_000), isSubagent: true),
            use("off before", at: days(10, before: today), source: .codex, tokens: TokenCounts(input: 7)),
        ])
        let figures = try await reports(store, sources: [.claudeCode]).detail(range: .week, curves: [], now: now, calendar: utc)
        #expect(figures.totals.tokens == TokenCounts(input: 1_000_000))
        #expect(figures.totals.requests == 1)
        #expect(figures.totals.subagentRequests == 0)
        #expect(figures.bySource.map(\.key) == [Source.claudeCode.displayName])
        #expect(figures.byModel.map(\.tokens) == [TokenCounts(input: 1_000_000)])
        #expect(figures.clientsBySource.isEmpty)
        #expect(figures.cacheSaving == .zero)
        #expect(figures.previous == PeriodTotals())
        #expect(figures.previousColumns.allSatisfy { $0.tokens == .zero })
    }

    @Test func withNoSourceEnabledThereIsNothing() async throws {
        let store = try storing([use("on", at: today.addingTimeInterval(-3_600))])
        let figures = try await reports(store, sources: []).detail(range: .week, curves: [], now: now, calendar: utc)
        #expect(figures.totals == PeriodTotals())
        #expect(figures.bySource.isEmpty)
    }

    // MARK: Totals and breakdowns

    @Test func totalsCostEachCategory() async throws {
        let tokens = TokenCounts(input: 1_000_000, output: 2_000_000, cacheRead: 4_000_000, cacheWrite5m: 2_000_000)
        let figures = try await detail(.week, [use("all", at: today.addingTimeInterval(-1), tokens: tokens)])
        #expect(figures.totals.cost == CostSummary(usd: 1 + 4 + 2 + 3, unpricedModels: [], unpricedTokens: 0))
        #expect(figures.totals.costByCategory == CategoryCost(input: 1, output: 4, cacheRead: 2, cacheWrite: 3))
        #expect(figures.columns[5].costByCategory == CategoryCost(input: 1, output: 4, cacheRead: 2, cacheWrite: 3))
    }

    /// Section 8.1 asks for one event, and an event can have no tokens.
    @Test func aDayWithAnEventOfNoTokensIsADayWithUse() async throws {
        let figures = try await detail(.week, [
            use("nothing", at: days(2, before: today), tokens: .zero),
            use("a", at: days(1, before: today)),
        ])
        #expect(figures.totals.daysWithUse == 2)
        #expect(figures.columns.map(\.hasUse) == [false, false, false, false, true, true, false])
    }

    @Test func aColumnWithNoEventHasNoUse() async throws {
        let figures = try await detail(.week, [])
        #expect(figures.columns.allSatisfy { !$0.hasUse })
    }

    /// The same day counts the same way on the page and in the kept days.
    @Test func daysWithUseAndDaysOfUseAgree() async throws {
        let events = [
            use("nothing", at: days(3, before: today), tokens: .zero),
            use("a", at: days(2, before: today)),
            use("b", at: days(1, before: today)),
        ]
        let figures = try await engine(events).detail(range: .week, now: now, calendar: utc)
        #expect(figures.daysOfUse == 3)
        #expect(figures.totals.daysWithUse == figures.daysOfUse)
    }

    @Test func aDayOfNoTokensIsInTheMedian() async throws {
        let figures = try await detail(.week, [
            use("nothing", at: days(3, before: today), tokens: .zero),
            use("a", at: days(2, before: today), tokens: TokenCounts(input: 1_000_000)),
            use("b", at: days(1, before: today), tokens: TokenCounts(input: 3_000_000)),
        ])
        #expect(figures.medianCost == 1)
    }

    @Test func d13AndD15CountThatDayToo() async throws {
        let events = [use("nothing", at: days(3, before: today), tokens: .zero), use("a", at: days(2, before: today))]
        let month = try await detail(.month, events)
        let year = try await detail(.year, events)
        #expect(month.highlights.cost.contains(.d13(days: 27)))
        #expect(year.highlights.cost.contains(.d15(days: 2)))
    }

    /// Today is under way: with nothing in it yet, it is not one of the days with no use.
    @Test func anEmptyTodayIsNoDayWithNoUse() async throws {
        let events = (1...29).filter { $0 != 3 && $0 != 5 }.map { use("d\($0)", at: days($0, before: today)) }
        let figures = try await detail(.month, events)
        #expect(figures.highlights.cost == [.d13(days: 2)])
    }

    @Test func requestsCountEveryEventAndItsSubagents() async throws {
        let yesterday = today.addingTimeInterval(-1)
        let figures = try await detail(.week, [
            use("a", at: yesterday), use("b", at: yesterday, isSubagent: true), use("c", at: yesterday, isSubagent: true),
        ])
        #expect(figures.totals.requests == 3)
        #expect(figures.totals.subagentRequests == 2)
    }

    @Test func theCacheSavingIsWhatReadsKeptOffTheBill() async throws {
        let figures = try await detail(.week, [use("a", at: today.addingTimeInterval(-1), tokens: TokenCounts(cacheRead: 2_000_000))])
        #expect(figures.cacheSaving == CostSummary(usd: 1, unpricedModels: [], unpricedTokens: 0))
    }

    @Test func sourcesAreNamedAndClientsSitUnderThem() async throws {
        let yesterday = today.addingTimeInterval(-1)
        let figures = try await detail(.week, [
            use("a", at: yesterday, source: .claudeCode, client: "desk"),
            use("b", at: yesterday, source: .claudeCode, client: "desk"),
            use("c", at: yesterday, source: .claudeCode, client: nil),
            use("d", at: yesterday, source: .codex, tokens: TokenCounts(input: 9_000_000)),
        ])
        #expect(figures.bySource.map(\.key) == [Source.codex.displayName, Source.claudeCode.displayName])
        #expect(figures.bySource.last?.tokens.input == 3_000_000)
        #expect(figures.clientsBySource[Source.claudeCode.displayName]?.map(\.key) == ["desk"])
        #expect(figures.clientsBySource[Source.claudeCode.displayName]?.first?.tokens.input == 2_000_000)
    }

    /// Thinking has to survive the store and the rows, which `DetailHighlightsTests` starts after.
    @Test func t1ReadsThinkingThroughTheStore() async throws {
        let yesterday = today.addingTimeInterval(-1)
        let figures = try await detail(.week, [
            use("a", at: yesterday, source: .claudeCode, tokens: TokenCounts(output: 900)),
            use("b", at: yesterday, source: .codex, tokens: TokenCounts(output: 100, reasoning: 25)),
            use("c", at: yesterday, source: .codex, tokens: TokenCounts(output: 100, reasoning: 25)),
        ])
        #expect(figures.highlights.tokens.first == .t1(percent: 25))
    }

    @Test func modelsAddUpToTheWholeRange() async throws {
        let yesterday = today.addingTimeInterval(-1)
        let figures = try await detail(.week, [
            use("a", at: yesterday, model: "priced"),
            use("b", at: yesterday, model: "mystery", tokens: TokenCounts(input: 7)),
            use("c", at: yesterday, model: nil, tokens: TokenCounts(input: 3)),
        ])
        #expect(figures.byModel.map(\.key) == ["priced", "mystery", ""])
        #expect(figures.byModel.reduce(0) { $0 + $1.tokens.total } == figures.totals.tokens.total)
    }

    // MARK: Unpriced models

    @Test func unpricedModelsAreNamedAndNeverGuessed() async throws {
        let yesterday = today.addingTimeInterval(-1)
        let figures = try await detail(.week, [
            use("a", at: yesterday),
            use("b", at: yesterday, model: "mystery", tokens: TokenCounts(input: 7)),
        ])
        #expect(figures.totals.cost == CostSummary(usd: 1, unpricedModels: ["mystery"], unpricedTokens: 7))
        #expect(figures.columns[5].cost == CostSummary(usd: 1, unpricedModels: ["mystery"], unpricedTokens: 7))
        #expect(figures.byModel.first { $0.key == "mystery" }?.cost == CostSummary(usd: 0, unpricedModels: ["mystery"], unpricedTokens: 7))
    }

    @Test func aRangeOfOnlyUnpricedTokensHasNoCost() async throws {
        let figures = try await detail(.week, [use("a", at: today.addingTimeInterval(-1), model: "mystery", tokens: TokenCounts(input: 7, cacheRead: 5))])
        #expect(figures.totals.cost == CostSummary(usd: 0, unpricedModels: ["mystery"], unpricedTokens: 12))
        #expect(figures.totals.costByCategory.total == 0)
        #expect(figures.cacheSaving == CostSummary(usd: 0, unpricedModels: ["mystery"], unpricedTokens: 5))
    }

    // MARK: The median

    @Test func theMedianDayIsOverDaysWithUseOnly() async throws {
        let figures = try await detail(.week, [
            use("a", at: days(1, before: today), tokens: TokenCounts(input: 1_000_000)),
            use("b", at: days(2, before: today), tokens: TokenCounts(input: 2_000_000)),
            use("c", at: days(3, before: today), tokens: TokenCounts(input: 9_000_000)),
        ])
        #expect(figures.medianCost == 2)
    }

    /// In day order the middle day is neither the median nor anything like it.
    @Test func theMedianGoesByCostNotByDay() async throws {
        let figures = try await detail(.week, [
            use("a", at: days(3, before: today), tokens: TokenCounts(input: 5_000_000)),
            use("b", at: days(2, before: today), tokens: TokenCounts(input: 1_000_000)),
            use("c", at: days(1, before: today), tokens: TokenCounts(input: 9_000_000)),
        ])
        #expect(figures.medianCost == 5)
    }

    @Test func theMedianMonthIsOverMonthsWithUseOnly() async throws {
        let figures = try await detail(.year, [
            use("a", at: date("2026-01-10T00:00:00Z"), tokens: TokenCounts(input: 1_000_000)),
            use("b", at: date("2026-02-10T00:00:00Z"), tokens: TokenCounts(input: 4_000_000)),
        ])
        #expect(figures.medianCost == 2.5)
    }

    @Test func dayHasNoMedian() async throws {
        #expect(try await detail(.day, [use("a", at: today)]).medianCost == nil)
    }

    /// Half of this week is a lower bound, and the page would print the median as an exact figure.
    @Test func thereIsNoMedianPastTheTolerance() async throws {
        let figures = try await detail(.week, [
            use("a", at: days(1, before: today)),
            use("b", at: days(2, before: today), model: "mystery"),
        ])
        #expect(figures.medianCost == nil)
    }

    @Test func thereIsAMedianUnderTheTolerance() async throws {
        let day = days(1, before: today)
        let under = try await detail(.week, [use("a", at: day, tokens: TokenCounts(input: 9_801)), use("b", at: day, model: "mystery", tokens: TokenCounts(input: 199))])
        let at = try await detail(.week, [use("a", at: day, tokens: TokenCounts(input: 9_800)), use("b", at: day, model: "mystery", tokens: TokenCounts(input: 200))])
        #expect(under.medianCost == 0.009801)
        #expect(at.medianCost == nil)
    }

    /// Today is under way, so it is not yet a day to take the middle of.
    @Test func theMedianDayLeavesOutToday() async throws {
        let figures = try await detail(.week, [
            use("a", at: days(1, before: today), tokens: TokenCounts(input: 1_000_000)),
            use("b", at: days(2, before: today), tokens: TokenCounts(input: 2_000_000)),
            use("c", at: days(3, before: today), tokens: TokenCounts(input: 9_000_000)),
            use("today", at: today, tokens: TokenCounts(input: 100_000_000)),
            use("a week ago", at: days(7, before: today), tokens: TokenCounts(input: 3_000_000)),
        ])
        #expect(figures.medianCost == 2)
    }

    /// The median goes on the days before today, so their tolerance is what counts: a local model used today does not hide it.
    @Test func todaysUnpricedTokensDoNotHideTheMedian() async throws {
        let figures = try await detail(.week, [use("a", at: days(1, before: today)), use("local", at: today, model: "mystery")])
        #expect(figures.totals.cost.unpricedTokens == 1_000_000)
        #expect(figures.medianCost == 1)
    }

    /// Nor does today's priced use make those days' unpriced tokens small enough to pass.
    @Test func theDaysBeforeTodayKeepTheirTolerance() async throws {
        let day = days(1, before: today)
        let figures = try await detail(.week, [
            use("a", at: day, tokens: TokenCounts(input: 9_800)),
            use("local", at: day, model: "mystery", tokens: TokenCounts(input: 200)),
            use("today", at: today, tokens: TokenCounts(input: 1_000_000)),
        ])
        #expect(figures.totals.tokens.input == 1_010_000)
        #expect(figures.medianCost == nil)
    }

    // MARK: Whether the previous period is full

    @Test func aPreviousPeriodIsFullWhenHistoryReachesItsFirstDay() async throws {
        let figures = try await detail(.week, [use("a", at: days(13, before: today))])
        #expect(figures.previousIsFull)
    }

    @Test func aPreviousPeriodIsFullWithHistoryBeforeIt() async throws {
        let figures = try await detail(.week, [use("old", at: days(40, before: today)), use("a", at: days(10, before: today))])
        #expect(figures.previousIsFull)
    }

    @Test func aPreviousPeriodIsNotFullWhenHistoryStartsPartWayIn() async throws {
        let figures = try await detail(.week, [use("a", at: days(12, before: today))])
        #expect(!figures.previousIsFull)
    }

    @Test func aPreviousPeriodIsNotFullWithNoUseInIt() async throws {
        let figures = try await detail(.week, [use("old", at: days(40, before: today)), use("a", at: days(2, before: today))])
        #expect(!figures.previousIsFull)
    }

    @Test func aDisabledSourcesHistoryDoesNotMakeAPeriodFull() async throws {
        let store = try storing([use("old", at: days(40, before: today), source: .codex), use("a", at: days(10, before: today))])
        let figures = try await reports(store, sources: [.claudeCode]).detail(range: .week, curves: [], now: now, calendar: utc)
        #expect(!figures.previousIsFull)
    }

    // MARK: Usual bands

    /// Seven days of 1 to 7 USD, all in the last quarter of 06:00, where an hour read from its start would miss them.
    private func curves(hour: Int = 6, count: Int = 7) -> [DayCurve] {
        (1...count).map { day in
            var slots = [[PricingGroup]](repeating: [], count: DayCurve.quarterHours)
            slots[hour * 4 + 3] = [
                PricingGroup(model: "priced", promptBand: 0, tokens: TokenCounts(input: day * 1_000_000)),
                PricingGroup(model: "mystery", promptBand: 0, tokens: TokenCounts(output: day)),
            ]
            return DayCurve(day: days(day, before: today), quarterHours: slots, prices: prices)
        }
    }

    @Test func theBandsComeFromTheKeptDays() async throws {
        let figures = try await detail(.day, [], curves: curves())
        #expect(figures.daysOfUse == 7)
        #expect(figures.usualCost.daily == UsualRange(p25: 2.5, median: 4, p75: 5.5))
        #expect(figures.usualOutput.daily == UsualRange(p25: 2.5, median: 4, p75: 5.5))
        #expect(figures.usualTokens.daily == UsualRange(p25: 2_500_002.5, median: 4_000_004, p75: 5_500_005.5))
    }

    @Test func eachHourHasItsOwnBand() async throws {
        let figures = try await detail(.day, [], curves: curves())
        #expect(figures.usualCost.hourly.count == 24)
        #expect(figures.usualCost.hourly[6] == UsualRange(p25: 2.5, median: 4, p75: 5.5))
        #expect(figures.usualCost.hourly[5] == UsualRange(p25: 0, median: 0, p75: 0))
        #expect(figures.usualCost.hourly[7] == UsualRange(p25: 0, median: 0, p75: 0))
    }

    @Test func nowIsTheCumulativeFigureAtThisTimeOfDay() async throws {
        let before = try await detail(.day, [], curves: curves(), now: today.addingTimeInterval(5 * 3_600))
        let after = try await detail(.day, [], curves: curves(), now: today.addingTimeInterval(7 * 3_600))
        #expect(before.usualCost.now == UsualRange(p25: 0, median: 0, p75: 0))
        #expect(after.usualCost.now == UsualRange(p25: 2.5, median: 4, p75: 5.5))
    }

    @Test func thereAreNoBandsUnderSevenDays() async throws {
        let figures = try await detail(.day, [], curves: curves(count: 6))
        #expect(figures.daysOfUse == 6)
        #expect(figures.usualCost == UsualBands())
        #expect(figures.usualTokens == UsualBands())
        #expect(figures.usualOutput == UsualBands())
    }

    // MARK: Rules on the figures

    @Test func theFiguresCarryTheirRules() async throws {
        let store = try storing([
            use("before", at: days(13, before: today), tokens: TokenCounts(input: 1_000_000)),
            use("last", at: days(2, before: today), tokens: TokenCounts(input: 2_000_000)),
        ])
        let figures = try await reports(store).detail(range: .week, curves: [], now: now, calendar: utc)
        #expect(figures.highlights.cost.contains(.d4(percent: 100)))
    }

    @Test func theFiguresTakeThePhase() async throws {
        let store = try storing([
            use("before", at: days(14, before: today), tokens: TokenCounts(input: 1_000_000)),
            use("last", at: days(2, before: today), tokens: TokenCounts(input: 2_000_000)),
        ])
        let figures = try await reports(store, phase: .history).detail(range: .week, curves: [], now: now, calendar: utc)
        #expect(figures.highlights == DetailHighlights(weekOutput: .w6, weekTokens: .w6))
    }

    @Test func theDayKnowsItsCurrentHourForD2() async throws {
        let figures = try await detail(.day, [
            use("morning", at: today.addingTimeInterval(3_600), tokens: TokenCounts(input: 1_000_000)),
            use("now", at: today.addingTimeInterval(12 * 3_600), tokens: TokenCounts(input: 2_000_000)),
        ])
        #expect(figures.highlights.cost == [.d1, .d2(cost: CostSummary(usd: 2, unpricedModels: [], unpricedTokens: 0))])
    }

    // MARK: Speed

    /// `output` tokens in `seconds`.
    private func timed(_ name: String, at time: Date, model: String = "priced", source: Source = .claudeCode, seconds: Double, output: Int = 1_000) -> UsageEvent {
        use(name, at: time, source: source, model: model, tokens: TokenCounts(output: output), generationMs: seconds * 1_000)
    }

    @Test func noSamplesNoModels() async throws {
        let figures = try await reports(storing([])).speed(range: .week, model: nil, medians: [:], now: now, calendar: utc)
        #expect(figures.range == .week)
        #expect(figures.models.isEmpty)
        #expect(figures.columns.count == 7)
        #expect(figures.columns.allSatisfy { $0.tokensPerSecond == nil && $0.samples == 0 })
    }

    @Test func speedHasTheColumnsOfItsRange() async throws {
        let store = try storing([])
        for (range, count) in [(DetailRange.day, 24), (.month, 30), (.year, 12)] {
            #expect(try await reports(store).speed(range: range, model: nil, medians: [:], now: now, calendar: utc).columns.count == count)
        }
    }

    @Test func theMostSampledModelLeadsAndIsChosenWithNone() async throws {
        let day = days(1, before: today)
        let figures = try await reports(storing([
            timed("a1", at: day, model: "a", seconds: 10),
            timed("b1", at: day, model: "b", seconds: 20),
            timed("b2", at: day.addingTimeInterval(1), model: "b", seconds: 40),
        ])).speed(range: .week, model: nil, medians: [:], now: now, calendar: utc)
        #expect(figures.models.map(\.speed.model) == ["b", "a"])
        #expect(figures.models.first?.speed.tokensPerSecond == 37.5)
        #expect(figures.columns[5].samples == 2)
        #expect(figures.columns[5].tokensPerSecond == 37.5)
    }

    @Test func theColumnsAreTheChosenModels() async throws {
        let day = days(1, before: today)
        let figures = try await reports(storing([
            timed("a1", at: day, model: "a", seconds: 10),
            timed("b1", at: day, model: "b", seconds: 20),
            timed("b2", at: day.addingTimeInterval(1), model: "b", seconds: 20),
        ])).speed(range: .week, model: "a", medians: [:], now: now, calendar: utc)
        #expect(figures.columns[5].tokensPerSecond == 100)
        #expect(figures.columns[5].samples == 1)
    }

    @Test func aChosenModelWithNoSamplesInTheRangeHasEmptyColumns() async throws {
        let figures = try await reports(storing([timed("a", at: days(1, before: today), model: "a", seconds: 10)]))
            .speed(range: .week, model: "b", medians: [:], now: now, calendar: utc)
        #expect(figures.columns.allSatisfy { $0.tokensPerSecond == nil && $0.samples == 0 })
        #expect(figures.models.map(\.speed.model) == ["a"])
    }

    /// A model first used today is in the week, as today is.
    @Test func aModelFirstUsedTodayIsInTheWeek() async throws {
        let figures = try await reports(storing([timed("today", at: today, seconds: 10)])).speed(range: .week, model: nil, medians: [:], now: now, calendar: utc)
        #expect(figures.models.map(\.speed.model) == ["priced"])
        #expect(figures.columns.last?.samples == 1)
    }

    @Test func speedCountsEnabledSourcesOnly() async throws {
        let day = days(1, before: today)
        let store = try storing([timed("a", at: day, model: "a", seconds: 10), timed("b", at: day, model: "b", source: .codex, seconds: 10)])
        let figures = try await reports(store, sources: [.claudeCode]).speed(range: .week, model: nil, medians: [:], now: now, calendar: utc)
        #expect(figures.models.map(\.speed.model) == ["a"])
    }

    /// `count` days of `samples` samples each, the last `count` days before today, day `n` at `10 × n` tokens a second.
    private func speedDays(_ count: Int, samples: Int = 5, offset: Int = 1) -> [UsageEvent] {
        (0..<count).flatMap { index in
            (0..<samples).map { sample in
                timed("d\(index)s\(sample)", at: days(index + offset, before: today).addingTimeInterval(Double(sample)), seconds: 100, output: 1_000 * (index + 1))
            }
        }
    }

    @Test func aModelsUsualRangeIsOfItsDailyMedians() async throws {
        let store = try storing(speedDays(1))
        let figures = try await reports(store).speed(range: .week, model: nil, medians: ["priced": [10, 20, 30, 40, 50, 60, 70]], now: now, calendar: utc)
        #expect(figures.models.first?.speedDays == 7)
        #expect(figures.models.first?.usual == UsualRange(p25: 25, median: 40, p75: 55))
    }

    @Test func thereIsNoUsualSpeedUnderSevenDays() async throws {
        let store = try storing(speedDays(1))
        let figures = try await reports(store).speed(range: .week, model: nil, medians: ["priced": [1, 2, 3, 4, 5, 6]], now: now, calendar: utc)
        #expect(figures.models.first?.speedDays == 6)
        #expect(figures.models.first?.usual == nil)
    }

    @Test func speedDaysStopAtTheNewestFourteen() async throws {
        let store = try storing(speedDays(1))
        let days = (1...20).map(Double.init)
        let figures = try await reports(store).speed(range: .week, model: nil, medians: ["priced": days], now: now, calendar: utc)
        #expect(figures.models.first?.speedDays == 14)
        #expect(figures.models.first?.usual?.median == 13.5)
    }

    @Test func aModelsDaysAreItsOwn() async throws {
        let store = try storing(speedDays(1))
        let figures = try await reports(store).speed(range: .week, model: nil, medians: ["other": [1, 2, 3, 4, 5, 6, 7]], now: now, calendar: utc)
        #expect(figures.models.first?.speedDays == 0)
        #expect(figures.models.first?.usual == nil)
    }

    // MARK: Limit history

    private func reading(
        _ percent: Double,
        resets: TimeInterval,
        observed: TimeInterval,
        window: QuotaWindow = .fiveHour,
        scope: String? = nil,
        provider: QuotaProvider = .anthropic
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider, window: window, scope: scope, usedPercent: percent,
            resetsAt: now.addingTimeInterval(resets), observedAt: now.addingTimeInterval(observed), origin: .claudeCache
        )
    }

    private func record(_ snapshots: [QuotaSnapshot], of snapshot: QuotaSnapshot) async throws -> LimitHistory {
        let store = try storing([])
        try store.record(snapshots)
        return try await reports(store).limitHistory(of: snapshot, now: now)
    }

    @Test func aLimitWithNoRecordHasNoHistory() async throws {
        let history = try await record([], of: reading(10, resets: 3_600, observed: -60))
        #expect(history == LimitHistory())
    }

    @Test func theReadingsAreTheCurrentWindowsOldestFirst() async throws {
        let latest = reading(30, resets: 3_600, observed: -60)
        let history = try await record([
            reading(90, resets: -3_600, observed: -7_200),
            reading(20, resets: 3_600, observed: -120),
            latest,
            reading(10, resets: 3_600, observed: -180),
        ], of: latest)
        #expect(history.readings == [
            LimitHistory.Reading(time: now.addingTimeInterval(-180), percent: 10),
            LimitHistory.Reading(time: now.addingTimeInterval(-120), percent: 20),
            LimitHistory.Reading(time: now.addingTimeInterval(-60), percent: 30),
        ])
    }

    @Test func theWindowsPeakOldestFirstWithTheCurrentLast() async throws {
        let latest = reading(30, resets: 3_600, observed: -60)
        let history = try await record([
            latest,
            reading(90, resets: -3_600, observed: -7_200),
            reading(100, resets: -3_600, observed: -7_100),
            reading(40, resets: -3_600, observed: -7_000),
            reading(70, resets: -30_000, observed: -40_000),
        ], of: latest)
        #expect(history.windows == [
            LimitHistory.Window(resetsAt: now.addingTimeInterval(-30_000), peak: 70),
            LimitHistory.Window(resetsAt: now.addingTimeInterval(-3_600), peak: 100),
            LimitHistory.Window(resetsAt: now.addingTimeInterval(3_600), peak: 30),
        ])
        #expect(history.windows.map(\.reachedLimit) == [false, true, false])
    }

    @Test func resetTimesWithin60SecondsAreOneWindow() async throws {
        let latest = reading(30, resets: 3_660, observed: -60)
        let history = try await record([latest, reading(20, resets: 3_600, observed: -120)], of: latest)
        #expect(history.windows == [LimitHistory.Window(resetsAt: now.addingTimeInterval(3_660), peak: 30)])
        #expect(history.readings.count == 2)
    }

    @Test func resetTimesOver60SecondsApartAreTwoWindows() async throws {
        let latest = reading(30, resets: 3_661, observed: -60)
        let history = try await record([latest, reading(20, resets: 3_600, observed: -120)], of: latest)
        #expect(history.windows.count == 2)
        #expect(history.readings.map(\.percent) == [30])
    }

    /// A stale cached figure can be read again after the next window opened: windows go by when they reset, not when they were seen.
    @Test func aWindowSeenAgainLateKeepsItsPlace() async throws {
        let latest = reading(30, resets: 3_600, observed: -200)
        let history = try await record([latest, reading(90, resets: -3_600, observed: -100)], of: latest)
        #expect(history.windows.map(\.peak) == [90, 30])
    }

    @Test func readingsGoByTimeWhateverTheirResetTimes() async throws {
        let latest = reading(30, resets: 3_600, observed: -60)
        let history = try await record([latest, reading(20, resets: 3_650, observed: -120)], of: latest)
        #expect(history.readings.map(\.percent) == [20, 30])
        #expect(history.windows == [LimitHistory.Window(resetsAt: latest.resetsAt, peak: 30)])
    }

    /// 3,661 is a window of its own, yet within 60 s of 3,640 in the one before: the current window is the newer.
    @Test func theCurrentWindowIsTheNewestThatFits() async throws {
        let latest = reading(30, resets: 3_661, observed: -100)
        let history = try await record([
            reading(10, resets: 3_600, observed: -300),
            reading(20, resets: 3_640, observed: -200),
            latest,
        ], of: latest)
        #expect(history.windows.count == 2)
        #expect(history.readings.map(\.percent) == [30])
    }

    /// Limits read nothing past what they keep: a year of readings is far too many for a page's refresh.
    @Test func aLimitsReadingsStopAtItsNewestWindows() throws {
        let latest = reading(4, resets: 3_600, observed: -60)
        let store = try storing([])
        try store.record([
            latest,
            reading(3, resets: 3_630, observed: -120),
            reading(2, resets: -3_600, observed: -7_000),
            reading(1, resets: -9_000, observed: -12_000),
            reading(0, resets: -20_000, observed: -22_000),
        ])
        let readings = try store.limitReadings(of: latest, upTo: now, windows: 2)
        #expect(Set(readings.map(\.percent)) == [4, 3, 2])
    }

    @Test func aLimitsReadingsStopOnlyPastItsWindows() throws {
        let latest = reading(2, resets: 3_600, observed: -60)
        let store = try storing([])
        try store.record([latest, reading(1, resets: -3_600, observed: -7_000)])
        #expect(try store.limitReadings(of: latest, upTo: now, windows: 2).count == 2)
    }

    @Test func resetsExactly60SecondsApartAreOneWindowToTheRead() throws {
        let latest = reading(2, resets: 3_660, observed: -60)
        let store = try storing([])
        try store.record([latest, reading(1, resets: 3_600, observed: -120)])
        #expect(try store.limitReadings(of: latest, upTo: now, windows: 1).count == 2)
    }

    /// Seen out of order, resets of 60, 120 and 0 are one window to the read, which stops by what it has seen so far, and two once sorted.
    @Test func aRecordOfOneWindowTooManyKeepsTheNewest() async throws {
        let latest = reading(1, resets: 60, observed: -60)
        let older = (1...23).map { reading(Double($0) + 1, resets: Double(-$0) * 3_600, observed: Double(-$0) * 3_600 - 60) }
        let history = try await record([latest, reading(2, resets: 120, observed: -120), reading(3, resets: 0, observed: -180)] + older, of: latest)
        #expect(history.windows.count == 24)
        #expect(history.windows.first?.peak == 23)
        #expect(history.windows.last?.peak == 2)
    }

    /// Only a reading the page never asked for could tell these apart: a reset far ahead, from before the windows it keeps.
    @Test func theRecordIsReadNoFurtherThanItKeeps() async throws {
        let latest = reading(1, resets: 0, observed: -60)
        let kept = (1...23).map { reading(Double($0), resets: Double(-$0) * 3_600, observed: Double(-$0) * 3_600 - 60) }
        let beyond = reading(99, resets: 900_000, observed: -500_000)
        let history = try await record(kept + [latest, beyond], of: latest)
        #expect(history.windows.count == 24)
        #expect(!history.windows.contains { $0.peak == 99 })
    }

    @Test func aSnapshotNotYetRecordedFindsItsWindow() async throws {
        let history = try await record([reading(20, resets: 3_600, observed: -120)], of: reading(30, resets: 3_630, observed: -60))
        #expect(history.readings.map(\.percent) == [20])
    }

    @Test func onlyTheLast24WindowsAreKept() async throws {
        let latest = reading(1, resets: 0, observed: -60)
        let older = (1...30).map { reading(Double($0), resets: Double(-$0) * 3_600, observed: Double(-$0) * 3_600 - 60) }
        let history = try await record(older + [latest], of: latest)
        #expect(history.windows.count == 24)
        #expect(history.windows.first?.peak == 23)
        #expect(history.windows.last?.resetsAt == now)
    }

    @Test func aLimitsRecordIsItsOwn() async throws {
        let latest = reading(30, resets: 3_600, observed: -60)
        let history = try await record([
            latest,
            reading(99, resets: 3_600, observed: -61, window: .weekly),
            reading(98, resets: 3_600, observed: -62, scope: "opus"),
            reading(97, resets: 3_600, observed: -63, provider: .openai),
        ], of: latest)
        #expect(history.readings.map(\.percent) == [30])
        #expect(history.windows.map(\.peak) == [30])
    }

    @Test func aScopedLimitReadsItsScope() async throws {
        let latest = reading(30, resets: 3_600, observed: -60, scope: "opus")
        let history = try await record([latest, reading(99, resets: 3_600, observed: -61)], of: latest)
        #expect(history.readings.map(\.percent) == [30])
    }

    @Test func readingsAfterNowAreNotYetRecorded() async throws {
        let latest = reading(30, resets: 3_600, observed: -60)
        let history = try await record([latest, reading(99, resets: 3_600, observed: 60)], of: latest)
        #expect(history.readings.map(\.percent) == [30])
    }

    @Test func aRecordIsFullyReadOnlyWhenLive() async throws {
        let latest = reading(30, resets: 3_600, observed: -60)
        let store = try storing([])
        try store.record([latest])
        for phase in [IngestProgress.Phase.idle, .recent, .history] {
            #expect(try await reports(store, phase: phase).limitHistory(of: latest, now: now).isFullyRead == false)
        }
        #expect(try await reports(store, phase: .live).limitHistory(of: latest, now: now).isFullyRead)
    }

    @Test func aReadingAtThisMomentIsRecorded() async throws {
        let latest = reading(30, resets: 3_600, observed: 0)
        #expect(try await record([latest], of: latest).readings.map(\.percent) == [30])
    }

    // MARK: Log summary

    @Test func anEmptyLogSaysSo() async throws {
        let summary = try await reports(storing([])).logSummary(filter: .all)
        #expect(summary == LogSummary())
    }

    @Test func theSummaryCoversEverythingMatching() async throws {
        let summary = try await reports(storing([
            use("a", at: now, tokens: TokenCounts(input: 1_000_000, output: 500_000, cacheRead: 3_000_000)),
            use("b", at: date("2020-01-01T00:00:00Z"), tokens: TokenCounts(input: 1_000_000, output: 500_000, cacheRead: 3_000_000), isSubagent: true),
            use("c", at: now, source: .codex, tokens: TokenCounts(input: 2_000_000), isSubagent: true),
        ])).logSummary(filter: EventFilter(sources: [.claudeCode]))
        #expect(summary.requests == 2)
        #expect(summary.cost == CostSummary(usd: 2 + 2 + 3, unpricedModels: [], unpricedTokens: 0))
        #expect(summary.output == 1_000_000)
        #expect(summary.cacheHitRate == 0.75)
        #expect(summary.subagentShare == 0.5)
    }

    /// The strip sits over the table, which a disabled source still reaches.
    @Test func theSummaryIsTheFiltersNotTheEnabledSources() async throws {
        let store = try storing([use("a", at: now, source: .codex)])
        let summary = try await reports(store, sources: [.claudeCode]).logSummary(filter: .all)
        #expect(summary.requests == 1)
    }

    @Test func thereIsNoHitRateWithNoPromptTokens() async throws {
        let summary = try await reports(storing([use("a", at: now, tokens: TokenCounts(output: 5))])).logSummary(filter: .all)
        #expect(summary.cacheHitRate == nil)
        #expect(summary.subagentShare == 0)
    }

    @Test func theSummaryNamesUnpricedModels() async throws {
        let summary = try await reports(storing([use("a", at: now, model: "mystery", tokens: TokenCounts(input: 7))])).logSummary(filter: .all)
        #expect(summary.cost == CostSummary(usd: 0, unpricedModels: ["mystery"], unpricedTokens: 7))
    }

    @Test func theSummaryHonoursEveryFilter() async throws {
        let store = try storing([use("a", at: now, isSubagent: true), use("b", at: now)])
        let summary = try await reports(store).logSummary(filter: EventFilter(isSubagent: true))
        #expect(summary.requests == 1)
        #expect(summary.subagentShare == 1)
    }

    // MARK: Through the engine

    /// An engine on `events`, with no readers and nothing to fetch: nothing here goes near the keychain or the network.
    private func engine(_ events: [UsageEvent], snapshots: [QuotaSnapshot] = [], change: (inout Preferences) -> Void = { _ in }) throws -> Engine {
        let store = try storing(events)
        try store.record(snapshots)
        var preferences = Preferences.defaults(home: try makeTempDir())
        preferences.priceOverrides = ["priced": PriceEntry(id: "priced", provider: "anthropic", price: Price(input: 1, output: 2, cacheRead: 0.5, cacheWrite5m: 1.5, cacheWrite1h: 1.5))]
        change(&preferences)
        return try Engine(
            store: store, home: try makeTempDir(), preferences: preferences, readers: [],
            token: { nil }, send: { _ in throw CancellationError() }
        )
    }

    private func goLive(_ engine: Engine) async throws {
        await engine.start()
        for _ in 0..<3_000 {
            if try await engine.dashboard(now: now, calendar: utc).progress.phase == .live { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The engine never went live")
    }

    @Test func theEngineGivesDetailItsEnabledSourcesAndPrices() async throws {
        let engine = try engine([use("on", at: days(1, before: today)), use("off", at: days(1, before: today), source: .codex)]) {
            $0.enabledSources = [.claudeCode]
        }
        let figures = try await engine.detail(range: .week, now: now, calendar: utc)
        #expect(figures.totals.requests == 1)
        #expect(figures.totals.cost == CostSummary(usd: 1, unpricedModels: [], unpricedTokens: 0))
    }

    @Test func theEngineGivesDetailItsKeptDays() async throws {
        let week = (1...7).map { use("d\($0)", at: days($0, before: today), tokens: TokenCounts(input: $0 * 1_000_000)) }
        let figures = try await engine(week).detail(range: .week, now: now, calendar: utc)
        #expect(figures.daysOfUse == 7)
        #expect(figures.usualCost.daily == UsualRange(p25: 2.5, median: 4, p75: 5.5))
    }

    @Test func theEngineGivesDetailItsPhase() async throws {
        let events = (1...14).map { use("d\($0)", at: days($0, before: today)) }
        let engine = try engine(events)
        #expect(try await engine.detail(range: .week, now: now, calendar: utc).highlights.weekOutput == .w6)
        try await goLive(engine)
        #expect(try await engine.detail(range: .week, now: now, calendar: utc).highlights.weekOutput == .w5)
    }

    /// The panel's sentence sits beside the Week columns, so the two speak of the same days: today so far, and as much of the week before.
    @Test func thePageAndThePanelSayTheSameOfTheWeek() async throws {
        let events = (1...6).map { use("last\($0)", at: days($0, before: today), tokens: TokenCounts(output: 150)) }
            + (7...13).map { use("before\($0)", at: days($0, before: today), tokens: TokenCounts(output: 100)) }
            + [
                use("today", at: today.addingTimeInterval(6 * 3_600), tokens: TokenCounts(output: 150)),
                use("after the cut", at: days(7, before: today).addingTimeInterval(18 * 3_600), tokens: TokenCounts(output: 9_999)),
                use("a fortnight ago", at: days(14, before: today), tokens: TokenCounts(output: 1)),
            ]
        let engine = try engine(events)
        try await goLive(engine)
        let page = try await engine.detail(range: .week, now: now, calendar: utc).highlights.weekOutput
        let panel = try await engine.insights(now: now, calendar: utc).results.week
        #expect(page == .w1(percent: 50))
        #expect(panel == page)
    }

    @Test func theEngineGivesSpeedItsEnabledSources() async throws {
        let day = days(1, before: today)
        let engine = try engine([timed("a", at: day, model: "a", seconds: 10), timed("b", at: day, model: "b", source: .codex, seconds: 10)]) {
            $0.enabledSources = [.claudeCode]
        }
        #expect(try await engine.speed(range: .week, model: nil, now: now, calendar: utc).models.map(\.speed.model) == ["a"])
    }

    private func tagged(_ events: [UsageEvent], _ tag: String) -> [UsageEvent] {
        events.map { event in
            var event = event
            event.dedupKey += tag
            return event
        }
    }

    private func firstModel(_ engine: Engine) async throws -> SpeedFigures.Model? {
        try await engine.speed(range: .week, model: nil, now: now, calendar: utc).models.first
    }

    @Test func theEngineGivesSpeedItsKeptDays() async throws {
        let model = try await firstModel(engine(speedDays(7)))
        #expect(model?.speedDays == 7)
        #expect(model?.usual == UsualRange(p25: 25, median: 40, p75: 55))
    }

    @Test func aDayUnderFiveSamplesIsNotASpeedDay() async throws {
        let model = try await firstModel(engine(speedDays(7, samples: 4)))
        #expect(model?.speedDays == 0)
        #expect(model?.usual == nil)
    }

    @Test func speedDaysLookBackNinetyDays() async throws {
        let events = tagged(speedDays(1, offset: 90), "a") + tagged(speedDays(1, offset: 91), "b") + tagged(speedDays(1, offset: 1), "c")
        #expect(try await firstModel(engine(events))?.speedDays == 2)
    }

    @Test func todayIsNoSpeedDay() async throws {
        let events = tagged(speedDays(1, offset: 1), "a") + tagged(speedDays(1, offset: 0), "b")
        #expect(try await firstModel(engine(events))?.speedDays == 1)
    }

    @Test func aDisabledSourceAddsNoSpeedDays() async throws {
        let off = tagged(speedDays(3, offset: 2), "off").map { event in
            var event = event
            event.source = .codex
            return event
        }
        let engine = try engine(speedDays(1) + off) { $0.enabledSources = [.claudeCode] }
        #expect(try await firstModel(engine)?.speedDays == 1)
    }

    /// One map serves both, so the page's range cannot drift from rule P.
    @Test func theSpeedPageReadsThePanelsMedians() async throws {
        let engine = try engine(tagged(speedDays(7), "a") + tagged(speedDays(1, offset: 0), "b"))
        let page = try await firstModel(engine)
        let panel = try await engine.insightInputs(now: now, calendar: utc).speed
        #expect(page?.usual == UsualRange.of(panel?.dailyMedians ?? []))
        #expect(page?.usual == UsualRange(p25: 25, median: 40, p75: 55))
    }

    @Test func theEngineReadsALimitsRecord() async throws {
        let latest = reading(30, resets: 3_600, observed: -60)
        let history = try await engine([], snapshots: [latest]).limitHistory(of: latest, now: now)
        #expect(history.windows == [LimitHistory.Window(resetsAt: latest.resetsAt, peak: 30)])
    }

    @Test func theEngineSummarisesTheLog() async throws {
        let engine = try engine([use("a", at: now)])
        #expect(try await engine.logSummary(filter: .all).cost == CostSummary(usd: 1, unpricedModels: [], unpricedTokens: 0))
    }

    /// The pages leave the actor, and the kept history they read has to survive that.
    @Test func aSourceTurnedOffLeavesTheBandsToo() async throws {
        let week = (1...7).map { use("d\($0)", at: days($0, before: today), source: .codex) }
        let engine = try engine(week)
        #expect(try await engine.detail(range: .day, now: now, calendar: utc).daysOfUse == 7)
        var preferences = Preferences.defaults(home: try makeTempDir())
        preferences.enabledSources = [.claudeCode]
        await engine.apply(preferences)
        #expect(try await engine.detail(range: .day, now: now, calendar: utc).daysOfUse == 0)
    }

    // MARK: Store reads

    @Test func requestCountsAreOfTheRangeAndFilter() throws {
        let store = try storing([use("a", at: today), use("b", at: today, source: .codex, isSubagent: true), use("c", at: today.addingTimeInterval(-1))])
        let range = TimeRange(start: today, end: today.addingTimeInterval(60))
        #expect(try store.requestCounts(in: range).all == 2)
        #expect(try store.requestCounts(in: range).subagent == 1)
        #expect(try store.requestCounts(in: range, filter: EventFilter(sources: [.claudeCode])).all == 1)
        #expect(try store.requestCounts(in: TimeRange(start: now, end: now)).all == 0)
        #expect(try store.requestCounts(in: TimeRange(start: now, end: now)).subagent == 0)
    }
}
