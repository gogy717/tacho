import Foundation
@testable import TachoKit
import Testing

struct QueriesTests {
    private let everything = TimeRange(start: date("2026-01-01T00:00:00Z"), end: date("2027-01-01T00:00:00Z"))
    private let noon = date("2026-11-03T12:00:00Z")

    private func event(
        _ name: String,
        at time: Date? = nil,
        source: Source = .claudeCode,
        client: String? = nil,
        project: String? = nil,
        provider: String? = nil,
        model: String? = "m",
        startTime: Date? = nil,
        generationMs: Double? = nil,
        speed: String? = nil,
        geo: String? = nil,
        tokens: TokenCounts = TokenCounts(output: 1)
    ) -> UsageEvent {
        UsageEvent(
            source: source, client: client, dedupKey: "\(source.rawValue):\(name)", project: project, provider: provider, model: model,
            time: time ?? noon, startTime: startTime, generationMs: generationMs, speed: speed, geo: geo, tokens: tokens
        )
    }

    private func store(_ events: [UsageEvent]) throws -> EventStore {
        let store = try EventStore.inMemory()
        try store.upsert(events)
        return store
    }

    private func calendar(_ zone: String, firstWeekday: Int = 1) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    /// `LocalBuckets.hourOfWeek`, shape checked first so a wrong result fails its test instead of crashing the run.
    private func hourOfWeek(_ groups: [QuarterHourGroup], _ calendar: Calendar) throws -> [[Int]] {
        let cells = LocalBuckets.hourOfWeek(groups, calendar: calendar)
        try #require(cells.count == 7 && cells.allSatisfy { $0.count == 24 })
        return cells
    }

    private func keys(_ store: EventStore, _ filter: EventFilter) throws -> Set<String> {
        Set(try store.logPage(filter: filter, before: nil, limit: 1_000).map(\.dedupKey))
    }

    // MARK: Token sums

    @Test func tokensInRangeAreHalfOpen() throws {
        let start = date("2026-11-03T10:00:00Z")
        let end = date("2026-11-03T11:00:00Z")
        let store = try store([
            event("start", at: start, tokens: TokenCounts(output: 3)),
            event("end", at: end, tokens: TokenCounts(output: 5)),
        ])
        #expect(try store.tokens(in: TimeRange(start: start, end: end)) == TokenCounts(output: 3))
    }

    @Test func tokensAddUpEachCategory() throws {
        let store = try store([
            event("a", tokens: TokenCounts(input: 1, output: 2, reasoning: 3, cacheRead: 4, cacheWrite5m: 5, cacheWrite1h: 6)),
            event("b", tokens: TokenCounts(input: 10, output: 20, reasoning: 30, cacheRead: 40, cacheWrite5m: 50, cacheWrite1h: 60)),
        ])
        #expect(try store.tokens(in: everything) == TokenCounts(input: 11, output: 22, reasoning: 33, cacheRead: 44, cacheWrite5m: 55, cacheWrite1h: 66))
    }

    @Test func tokensOfNoEventsAreZero() throws {
        #expect(try store([]).tokens(in: everything) == .zero)
    }

    @Test func tokensBySourceAndClientSplitsClientsWithinASource() throws {
        let earlier = date("2026-11-03T10:00:00Z")
        let later = date("2026-11-03T10:30:00Z")
        let store = try store([
            event("a", at: earlier, client: "cli", tokens: TokenCounts(output: 3)),
            event("b", at: later, client: "cli", tokens: TokenCounts(output: 5)),
            event("c", at: earlier, client: "claude-desktop", tokens: TokenCounts(output: 7)),
            event("d", at: later, source: .pi, tokens: TokenCounts(output: 11)),
            event("outside", at: date("2025-01-01T00:00:00Z"), client: "cli", tokens: TokenCounts(output: 13)),
        ])

        let rows = try store.tokensBySourceAndClient(in: everything)
        #expect(rows.count == 3)
        #expect(rows.first { $0.client == "cli" } == SourceClientTokens(source: .claudeCode, client: "cli", tokens: TokenCounts(output: 8), lastTime: later))
        #expect(rows.first { $0.client == "claude-desktop" } == SourceClientTokens(source: .claudeCode, client: "claude-desktop", tokens: TokenCounts(output: 7), lastTime: earlier))
        #expect(rows.first { $0.source == .pi } == SourceClientTokens(source: .pi, client: nil, tokens: TokenCounts(output: 11), lastTime: later))
    }

    // MARK: Minute groups

    /// The tokens of each minute of `minuteGroups`.
    private func tokens(of store: EventStore, endingAt now: Date, minutes: Int = 60) throws -> [TokenCounts] {
        try store.minuteGroups(endingAt: now, minutes: minutes, thresholds: []).map { $0.reduce(.zero) { $0 + $1.tokens } }
    }

    @Test func minuteGroupsBucketByWallClockMinute() throws {
        let store = try store([
            event("current", at: date("2026-11-03T10:00:10Z"), tokens: TokenCounts(output: 3)),
            event("oldest", at: date("2026-11-03T09:01:00Z"), tokens: TokenCounts(output: 5)),
            event("outside", at: date("2026-11-03T09:00:59Z"), tokens: TokenCounts(output: 7)),
        ])

        let series = try tokens(of: store, endingAt: date("2026-11-03T10:00:30Z"))

        try #require(series.count == 60)
        #expect(series[59] == TokenCounts(output: 3))
        #expect(series[0] == TokenCounts(output: 5))
        #expect(series[1..<59].allSatisfy { $0 == .zero })
    }

    // MARK: Sub-agents and sessions

    private func agentsAndSessions() throws -> EventStore {
        var agent = event("agent", tokens: TokenCounts(output: 3))
        agent.isSubagent = true
        agent.sessionId = "s1"
        var main = event("main", tokens: TokenCounts(output: 5))
        main.sessionId = "s1"
        var other = event("other", tokens: TokenCounts(output: 7))
        other.sessionId = "s2"
        return try store([agent, main, other, event("none", tokens: TokenCounts(output: 11))])
    }

    private var aroundNoon: TimeRange {
        TimeRange(start: noon.addingTimeInterval(-60), end: noon.addingTimeInterval(60))
    }

    @Test func aFilterCanAskForSubagentsOrTheRest() throws {
        let store = try agentsAndSessions()

        #expect(try store.tokens(in: aroundNoon, filter: EventFilter(isSubagent: true)).output == 3)
        #expect(try store.tokens(in: aroundNoon, filter: EventFilter(isSubagent: false)).output == 23)
        #expect(try store.tokens(in: aroundNoon).output == 26)
    }

    @Test func aFilterCanAskForOneSession() throws {
        let store = try agentsAndSessions()

        #expect(try store.tokens(in: aroundNoon, filter: EventFilter(sessionId: "s1")).output == 8)
        #expect(try store.tokens(in: aroundNoon, filter: EventFilter(sessionId: "no such session")).output == 0)
    }

    @Test func theTwoNarrowTogether() throws {
        let store = try agentsAndSessions()

        #expect(try store.tokens(in: aroundNoon, filter: EventFilter(isSubagent: false, sessionId: "s1")).output == 5)
    }

    @Test func theLogFollowsThoseFiltersToo() throws {
        let page = try agentsAndSessions().logPage(filter: EventFilter(isSubagent: true), before: nil, limit: 10)

        #expect(page.map(\.dedupKey) == ["claudeCode:agent"])
    }

    @Test func speedSamplesCountOnlyWhatTheFilterLetsThrough() throws {
        let store = try store([
            event("on", at: noon, source: .claudeCode, generationMs: 1_000, tokens: TokenCounts(output: 100)),
            event("off", at: noon, source: .pi, generationMs: 1_000, tokens: TokenCounts(output: 200)),
        ])

        let samples = try store.speedSamples(in: aroundNoon, filter: EventFilter(sources: [.claudeCode]))

        #expect(samples.map(\.output) == [100])
        #expect(try store.speedSamples(in: aroundNoon).count == 2)
    }

    // MARK: Quarter hours of a local day

    /// `events` at `times`, by local day, each slot holding the output tokens of its groups.
    private func slots(_ times: [String], zone: String) throws -> [Date: [Int]] {
        let calendar = try calendar(zone)
        let events = times.enumerated().map { index, time in event("e\(index)", at: date(time), tokens: TokenCounts(output: 1)) }
        let groups = try store(events).quarterHourGroups(
            in: TimeRange(start: date("2025-01-01T00:00:00Z"), end: date("2027-01-01T00:00:00Z")),
            thresholds: []
        )
        return LocalBuckets.quarterHours(groups, calendar: calendar).mapValues { slots in
            #expect(slots.count == 96)
            return slots.map { $0.reduce(0) { $0 + $1.tokens.output } }
        }
    }

    @Test func aLocalDayHasNinetySixQuarterHours() throws {
        let days = try slots(["2026-06-15T00:10:00Z", "2026-06-15T12:30:00Z", "2026-06-15T23:50:00Z"], zone: "UTC")

        let day = try #require(days[date("2026-06-15T00:00:00Z")])
        #expect(day[0] == 1)
        #expect(day[50] == 1)
        #expect(day[95] == 1)
        #expect(day.reduce(0, +) == 3)
    }

    @Test func midnightOpensTheNextDay() throws {
        let days = try slots(["2026-06-15T23:59:59Z", "2026-06-16T00:00:00Z"], zone: "UTC")

        #expect(days[date("2026-06-15T00:00:00Z")]?[95] == 1)
        #expect(days[date("2026-06-16T00:00:00Z")]?[0] == 1)
    }

    /// New York, 1 November 2026: 01:00 to 02:00 happens twice, and both add to the same four slots.
    @Test func aRepeatedHourAddsToItsSlots() throws {
        let days = try slots(["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z"], zone: "America/New_York")

        let day = try #require(days.values.first)
        #expect(days.count == 1)
        #expect(day[6] == 2)
        #expect(day.reduce(0, +) == 2)
    }

    /// New York, 8 March 2026: 02:00 to 03:00 never happens, so its slots stay empty and the day still has 96.
    @Test func aSkippedHourLeavesItsSlotsEmpty() throws {
        let days = try slots(["2026-03-08T06:59:00Z", "2026-03-08T07:00:00Z"], zone: "America/New_York")

        let day = try #require(days.values.first)
        #expect(day[7] == 1)
        #expect(day[8..<12].allSatisfy { $0 == 0 })
        #expect(day[12] == 1)
    }

    /// Havana, 8 March 2026: midnight itself is skipped, so the day starts at 01:00.
    @Test func aDayThatStartsLateKeepsItsSlots() throws {
        let days = try slots(["2026-03-08T05:10:00Z"], zone: "America/Havana")

        let day = try #require(days.values.first)
        #expect(day[0..<4].allSatisfy { $0 == 0 })
        #expect(day[4] == 1)
    }

    /// Havana, 2 November 2025: 00:00 to 01:00 happens twice, in the same local day. A date in the past, which the zone data keeps.
    @Test func aRepeatedFirstHourStaysInItsDay() throws {
        let days = try slots(["2025-11-02T04:30:00Z", "2025-11-02T05:30:00Z"], zone: "America/Havana")

        #expect(days.count == 1)
        #expect(days.values.first?[2] == 2)
    }

    /// Lord Howe moves by 30 minutes, 5 April 2026: 01:30 to 02:00 happens twice.
    @Test func aRepeatedHalfHourAddsToItsSlots() throws {
        let days = try slots(["2026-04-04T14:40:00Z", "2026-04-04T15:10:00Z"], zone: "Australia/Lord_Howe")

        #expect(days.count == 1)
        #expect(days.values.first?[6] == 2)
    }

    /// Kathmandu is 5:45 ahead of UTC, so a UTC quarter hour is still a local one.
    @Test func anOffsetOfAQuarterHourKeepsItsSlots() throws {
        let days = try slots(["2026-06-14T18:15:00Z", "2026-06-15T18:14:59Z"], zone: "Asia/Kathmandu")

        let day = try #require(days.values.first)
        #expect(days.count == 1)
        #expect(day[0] == 1)
        #expect(day[95] == 1)
    }

    // MARK: Fingerprints

    private var day: TimeRange {
        TimeRange(start: date("2026-11-03T00:00:00Z"), end: date("2026-11-04T00:00:00Z"))
    }

    @Test func aRowInTheRangeChangesTheFingerprint() throws {
        let store = try store([event("a", at: noon)])
        let before = try store.fingerprint(of: day)

        try store.upsert([event("b", at: noon)])

        #expect(try store.fingerprint(of: day) != before)
    }

    @Test func aRowOutsideTheRangeLeavesTheFingerprint() throws {
        let store = try store([event("a", at: noon)])
        let before = try store.fingerprint(of: day)

        try store.upsert([
            event("after", at: date("2026-11-04T00:00:00Z")),
            event("before", at: date("2026-11-02T23:59:59Z")),
        ])

        #expect(try store.fingerprint(of: day) == before)
    }

    @Test func moreTokensInARowChangeTheFingerprint() throws {
        let store = try store([event("a", at: noon, tokens: TokenCounts(output: 1))])
        let before = try store.fingerprint(of: day)

        try store.upsert([event("a", at: noon, tokens: TokenCounts(output: 2))])

        #expect(try store.fingerprint(of: day) != before)
    }

    @Test func aRowThatMovesChangesTheFingerprint() throws {
        let store = try store([event("a", at: noon)])
        let before = try store.fingerprint(of: day)

        try store.upsert([event("a", at: noon.addingTimeInterval(1))])

        #expect(try store.fingerprint(of: day) != before)
    }

    /// Reading a log again writes the same rows: that is nothing new.
    @Test func theSameRowsWrittenAgainLeaveTheFingerprint() throws {
        let rows = [event("a", at: noon, tokens: TokenCounts(input: 3, output: 5))]
        let store = try store(rows)
        let before = try store.fingerprint(of: day)

        try store.upsert(rows)

        #expect(try store.fingerprint(of: day) == before)
    }

    /// Added up from zero, these two times overflow. A range's rows are all near its start, whatever the date.
    @Test func aFingerprintDoesNotDependOnHowFarTheTimesAreFromZero() throws {
        let start = Date(timeIntervalSince1970: 9_000_000_000_000_000)
        let store = try store([event("a", at: start), event("b", at: start.addingTimeInterval(2))])

        let fingerprint = try store.fingerprint(of: TimeRange(start: start, end: start.addingTimeInterval(60)))

        #expect(fingerprint.rows == 2)
        #expect(fingerprint.milliseconds == 2_000)
    }

    @Test func noRowsHaveAFingerprintToo() throws {
        let store = try store([])

        #expect(try store.fingerprint(of: day) == RowsFingerprint(rows: 0, milliseconds: 0, tokens: .zero))
    }

    @Test func minuteGroupsLeaveOutWhatIsOutsideTheHour() throws {
        let now = date("2026-11-03T10:00:30Z")
        let store = try store([
            event("newest", at: date("2026-11-03T10:00:10Z"), tokens: TokenCounts(output: 3)),
            event("boundary", at: date("2026-11-03T09:30:00Z"), tokens: TokenCounts(output: 7)),
            event("oldest", at: date("2026-11-03T09:01:00Z"), tokens: TokenCounts(output: 5)),
            event("outside", at: date("2026-11-03T09:00:59Z"), tokens: TokenCounts(output: 11)),
            event("ahead", at: date("2026-11-03T10:00:31Z"), tokens: TokenCounts(output: 13)),
        ])

        let groups = try store.minuteGroups(endingAt: now, thresholds: [])

        try #require(groups.count == 60)
        #expect(groups[59].first?.tokens == TokenCounts(output: 3))
        #expect(groups[29].first?.tokens == TokenCounts(output: 7))
        #expect(groups[0].first?.tokens == TokenCounts(output: 5))
        #expect(groups.flatMap { $0 }.count == 3)
    }

    /// Whatever changes a price stays apart, or the dollars of a minute could not be right.
    @Test func minuteGroupsKeepWhatChangesThePrice() throws {
        let at = date("2026-11-03T10:00:10Z")
        let store = try store([
            event("a", at: at, model: "m1", tokens: TokenCounts(input: 1)),
            event("b", at: at, model: "m1", tokens: TokenCounts(input: 2)),
            event("c", at: at, model: "m2", tokens: TokenCounts(input: 4)),
            event("d", at: at, model: "m1", speed: "fast", tokens: TokenCounts(input: 8)),
            event("e", at: at, model: "m1", geo: "us", tokens: TokenCounts(input: 16)),
            event("f", at: at, model: "m1", tokens: TokenCounts(input: 200)),
        ])

        let minute = try #require(try store.minuteGroups(endingAt: date("2026-11-03T10:00:30Z"), thresholds: [100]).last)

        #expect(minute.count == 5)
        #expect(minute.first { $0.model == "m1" && $0.promptBand == 0 && $0.speed == nil && $0.geo == nil }?.tokens.input == 3)
        #expect(minute.first { $0.promptBand == 1 }?.tokens.input == 200)
    }

    @Test func minuteGroupsCountOnlyWhatTheFilterLetsThrough() throws {
        let store = try store([
            event("kept", at: date("2026-11-03T12:00:10Z"), source: .claudeCode, tokens: TokenCounts(output: 3)),
            event("left out", at: date("2026-11-03T12:00:20Z"), source: .pi, tokens: TokenCounts(output: 5)),
        ])

        let groups = try store.minuteGroups(endingAt: date("2026-11-03T12:00:30Z"), filter: EventFilter(sources: [.claudeCode]), thresholds: [])

        #expect(groups[59].map(\.tokens) == [TokenCounts(output: 3)])
    }

    @Test func noMinutesHaveNoGroups() throws {
        #expect(try store([]).minuteGroups(endingAt: noon, minutes: 0, thresholds: []).isEmpty)
    }

    @Test func minuteGroupsPutAMinuteBoundaryInTheLaterMinute() throws {
        let store = try store([
            event("before", at: date("2026-11-03T09:58:59Z"), tokens: TokenCounts(output: 3)),
            event("on", at: date("2026-11-03T09:59:00Z"), tokens: TokenCounts(output: 5)),
        ])
        let series = try tokens(of: store, endingAt: date("2026-11-03T10:00:30Z"), minutes: 3)
        #expect(series == [TokenCounts(output: 3), TokenCounts(output: 5), .zero])
    }

    @Test func minuteGroupsEndAtNow() throws {
        let now = date("2026-11-03T10:00:30Z")
        let store = try store([
            event("now", at: now, tokens: TokenCounts(output: 3)),
            event("after", at: date("2026-11-03T10:00:31Z"), tokens: TokenCounts(output: 5)),
        ])
        #expect(try tokens(of: store, endingAt: now, minutes: 1) == [TokenCounts(output: 3)])
    }

    // MARK: Pricing groups

    @Test func pricingGroupsSplitByModelSpeedGeoAndBand() throws {
        let thresholds = [100_000, 200_000]
        let bands = try store([
            event("a", tokens: TokenCounts(input: 50_000)),
            event("b", tokens: TokenCounts(input: 150_000)),
            event("c", tokens: TokenCounts(input: 250_000)),
        ]).pricingGroups(in: everything, thresholds: thresholds).sorted { $0.promptBand < $1.promptBand }
        #expect(bands.map(\.promptBand) == [0, 1, 2])
        #expect(bands.map(\.tokens.input) == [50_000, 150_000, 250_000])

        let split = try store([
            event("a", model: "m1", speed: "standard", geo: "us", tokens: TokenCounts(output: 1)),
            event("b", model: "m1", speed: "standard", geo: "us", tokens: TokenCounts(output: 2)),
            event("c", model: "m2", speed: "standard", geo: "us", tokens: TokenCounts(output: 4)),
            event("d", model: "m1", speed: "fast", geo: "us", tokens: TokenCounts(output: 8)),
            event("e", model: "m1", speed: "standard", geo: "global", tokens: TokenCounts(output: 16)),
        ]).pricingGroups(in: everything, thresholds: thresholds)
        #expect(split.count == 4)
        #expect(split.first { $0.model == "m1" && $0.speed == "standard" && $0.geo == "us" }?.tokens.output == 3)
        #expect(split.first { $0.model == "m2" }?.tokens.output == 4)
        #expect(split.first { $0.speed == "fast" }?.tokens.output == 8)
        #expect(split.first { $0.geo == "global" }?.tokens.output == 16)
    }

    /// `PricingGroup.promptBand`: 0 when at most `thresholds[0]`.
    @Test func aPromptExactlyAtAThresholdIsNotOverIt() throws {
        let groups = try store([
            event("at", tokens: TokenCounts(input: 100_000)),
            event("over", tokens: TokenCounts(input: 100_001)),
        ]).pricingGroups(in: everything, thresholds: [100_000]).sorted { $0.promptBand < $1.promptBand }
        #expect(groups.map(\.promptBand) == [0, 1])
        #expect(groups.map(\.tokens.input) == [100_000, 100_001])
    }

    @Test func aPromptIsInputCacheReadAndCacheWritesButNotOutput() throws {
        let groups = try store([
            event("over", tokens: TokenCounts(input: 1, cacheRead: 2, cacheWrite5m: 4, cacheWrite1h: 4)),
            event("at", tokens: TokenCounts(input: 1, output: 500, reasoning: 500, cacheRead: 2, cacheWrite5m: 4, cacheWrite1h: 3)),
        ]).pricingGroups(in: everything, thresholds: [10]).sorted { $0.promptBand < $1.promptBand }
        #expect(groups.map(\.promptBand) == [0, 1])
        #expect(groups.map(\.tokens.output) == [500, 0])
    }

    @Test func withoutThresholdsEveryGroupIsInBandZero() throws {
        let store = try store([event("a", tokens: TokenCounts(input: 900_000))])
        #expect(try store.pricingGroups(in: everything, thresholds: []).map(\.promptBand) == [0])
        #expect(try store.quarterHourGroups(in: everything, thresholds: []).map(\.group.promptBand) == [0])
    }

    @Test func pricingGroupsFollowTheRangeAndFilter() throws {
        let inside = date("2026-11-03T10:00:00Z")
        let groups = try store([
            event("a", at: inside, tokens: TokenCounts(output: 3)),
            event("b", at: inside, source: .pi, tokens: TokenCounts(output: 5)),
            event("c", at: date("2026-11-03T11:00:00Z"), tokens: TokenCounts(output: 7)),
        ]).pricingGroups(
            in: TimeRange(start: inside, end: date("2026-11-03T11:00:00Z")),
            filter: EventFilter(sources: [.claudeCode]),
            thresholds: []
        )
        #expect(groups.map(\.tokens.output) == [3])
    }

    // MARK: Quarter hours

    @Test func quarterHourGroupsAlignToNineHundredSeconds() throws {
        let groups = try store([
            event("a", at: date("2026-11-03T10:00:00Z"), tokens: TokenCounts(output: 3)),
            event("b", at: date("2026-11-03T10:14:59Z"), tokens: TokenCounts(output: 5)),
            event("c", at: date("2026-11-03T10:15:00Z"), tokens: TokenCounts(output: 7)),
        ]).quarterHourGroups(in: everything, thresholds: []).sorted { $0.start < $1.start }
        #expect(groups.map(\.start) == [date("2026-11-03T10:00:00Z"), date("2026-11-03T10:15:00Z")])
        #expect(groups.map(\.group.tokens.output) == [8, 7])
    }

    @Test func quarterHourGroupsAddUpToThePricingGroups() throws {
        let store = try store((0..<40).map { step in
            event(
                "\(step)",
                at: noon.addingTimeInterval(Double(step) * 137),
                model: step % 2 == 0 ? "m1" : "m2",
                tokens: TokenCounts(input: step % 3 == 0 ? 150_000 : 10, output: step)
            )
        })
        let thresholds = [100_000]
        let total = { (groups: [PricingGroup]) in groups.reduce(TokenCounts.zero) { $0 + $1.tokens } }
        let quarterHours = try store.quarterHourGroups(in: everything, thresholds: thresholds).map(\.group)
        let whole = try store.pricingGroups(in: everything, thresholds: thresholds)
        #expect(total(whole).output == (0..<40).reduce(0, +))
        #expect(total(quarterHours) == total(whole))
        for band in [0, 1] {
            #expect(total(quarterHours.filter { $0.promptBand == band }) == total(whole.filter { $0.promptBand == band }))
        }
    }

    @Test func quarterHourGroupsFollowTheFilter() throws {
        let groups = try store([
            event("a", tokens: TokenCounts(output: 3)),
            event("b", source: .pi, tokens: TokenCounts(output: 5)),
        ]).quarterHourGroups(in: everything, filter: EventFilter(sources: [.pi]), thresholds: [])
        #expect(groups.map(\.group.tokens.output) == [5])
    }

    // MARK: Breakdown

    @Test func breakdownGroupsByDimensionAndKeepsPriceDetail() throws {
        let store = try store([
            event("a", project: "/p1", model: "m1", tokens: TokenCounts(input: 150_000)),
            event("b", source: .codex, project: "/p1", model: "m2", tokens: TokenCounts(input: 3)),
            event("c", source: .codex, project: "/p2", model: "m2", tokens: TokenCounts(input: 5)),
            event("outside", at: date("2025-01-01T00:00:00Z"), project: "/p3", model: "m3"),
        ])
        let thresholds = [100_000]

        let bySource = try store.breakdown(in: everything, by: .source, thresholds: thresholds)
        #expect(Set(bySource.keys) == ["claudeCode", "codex"])
        #expect(bySource["codex"]?.map(\.tokens.input) == [8])
        #expect(bySource["claudeCode"]?.map(\.promptBand) == [1])

        let byModel = try store.breakdown(in: everything, by: .model, thresholds: thresholds)
        #expect(Set(byModel.keys) == ["m1", "m2"])
        #expect(byModel["m2"]?.map(\.tokens.input) == [8])

        let byProject = try store.breakdown(in: everything, by: .project, thresholds: thresholds)
        #expect(Set(byProject.keys) == ["/p1", "/p2"])
        #expect(byProject["/p1"]?.count == 2)
        #expect(byProject["/p2"]?.map(\.model) == ["m2"])
    }

    /// Their tokens still count, so the rows of a breakdown add up to the total.
    @Test func breakdownKeepsEventsWithoutAModelOrProjectUnderAnEmptyKey() throws {
        let store = try store([event("a", project: nil, model: nil, tokens: TokenCounts(input: 3))])
        #expect(try store.breakdown(in: everything, by: .model, thresholds: [])[""]?.map(\.tokens.input) == [3])
        #expect(try store.breakdown(in: everything, by: .project, thresholds: [])[""]?.map(\.tokens.input) == [3])
    }

    // MARK: Filters

    @Test func filtersByQuotaProviderAndScope() throws {
        let claude = event("a", model: "claude-fable-5-1", tokens: TokenCounts(output: 3))
        let store = try store([
            claude,
            event("b", source: .codex, provider: "openai", model: "gpt-5", tokens: TokenCounts(output: 5)),
            event("c", source: .omp, provider: "xai", model: "grok-4", tokens: TokenCounts(output: 7)),
        ])

        let filter = EventFilter(quotaProvider: .anthropic, modelContains: "fable")
        #expect(try store.tokens(in: everything, filter: filter) == TokenCounts(output: 3))
        #expect(try keys(store, filter) == [claude.dedupKey])

        #expect(QuotaAttribution.provider(source: .omp, eventProvider: "openai-codex") == .openai)
        #expect(QuotaAttribution.provider(source: .codex, eventProvider: "ollama") == nil)
        #expect(QuotaAttribution.provider(source: .copilot, eventProvider: "copilot") == nil)
    }

    @Test func modelContainsIgnoresCase() throws {
        let store = try store([event("a", model: "claude-fable-5-1"), event("b", model: "claude-opus-5-5")])
        #expect(try keys(store, EventFilter(modelContains: "Fable")) == ["claudeCode:a"])
    }

    @Test func quotaAttributionFollowsTheSourceThenTheProvider() {
        let table: [(source: Source, id: String?, quota: QuotaProvider?)] = [
            (.claudeCode, nil, .anthropic), (.claudeCode, "anything", .anthropic),
            (.grok, nil, .xai), (.grok, "anything", .xai),
            (.codex, nil, .openai), (.codex, "openai", .openai), (.codex, "openai-codex", nil), (.codex, "", nil),
            (.omp, "anthropic", .anthropic), (.pi, "anthropic-oauth", .anthropic), (.opencode, "anthropic", .anthropic),
            (.omp, "openai", .openai), (.pi, "openai-codex", .openai), (.opencode, "openai", .openai),
            (.omp, "xai", .xai), (.pi, "xai-oauth", .xai), (.opencode, "xai", .xai),
            (.omp, nil, nil), (.pi, "ollama", nil), (.opencode, "myopenai", nil), (.omp, "OpenAI", nil),
            (.copilot, nil, nil), (.copilot, "anthropic", nil),
        ]
        for row in table {
            #expect(QuotaAttribution.provider(source: row.source, eventProvider: row.id) == row.quota, "\(row.source) \(row.id ?? "nil")")
        }
    }

    /// The SQL predicate and the Swift mapping must never disagree: a limit's forecast is computed from what the predicate selects.
    @Test func theQuotaFilterSelectsExactlyWhatTheMappingAttributes() throws {
        let ids: [String?] = [
            nil, "", "anthropic", "anthropic-oauth", "Anthropic", "openai", "openai-codex", "OpenAI", "myopenai",
            "xai", "xai-oauth", "XAI", "ollama", "copilot",
        ]
        let events = Source.allCases.flatMap { source in
            ids.enumerated().map { event("\($0.offset)", source: source, provider: $0.element) }
        }
        let store = try store(events)

        for quota in QuotaProvider.allCases {
            let attributed = events.filter { QuotaAttribution.provider(source: $0.source, eventProvider: $0.provider) == quota }
            #expect(!attributed.isEmpty)
            #expect(try keys(store, EventFilter(quotaProvider: quota)) == Set(attributed.map(\.dedupKey)), "\(quota)")
        }
    }

    @Test func filtersBySourcesProjectsAndModels() throws {
        let store = try store([
            event("a", project: "/p1", model: "m1"),
            event("b", source: .codex, project: "/p2", model: "m2"),
            event("c", source: .pi, project: "/p3", model: "m3"),
        ])
        #expect(try keys(store, EventFilter(sources: [.codex, .pi])) == ["codex:b", "pi:c"])
        #expect(try keys(store, EventFilter(projects: ["/p1", "/p3"])) == ["claudeCode:a", "pi:c"])
        #expect(try keys(store, EventFilter(models: ["m2"])) == ["codex:b"])
        #expect(try keys(store, EventFilter(sources: [.codex, .pi], models: ["m3"])) == ["pi:c"])
    }

    /// nil means every source; an empty set is the user switching them all off.
    @Test func anEmptySetMatchesNothing() throws {
        let store = try store([event("a")])
        #expect(try keys(store, EventFilter(sources: [])).isEmpty)
        #expect(try store.tokens(in: everything, filter: EventFilter(models: [])) == .zero)
    }

    @Test func searchFindsASubstringOfTheProjectOrModelInAnyCase() throws {
        let store = try store([
            event("a", project: "/Users/me/Tacho", model: nil),
            event("b", project: nil, model: "claude-opus-5-5"),
            event("c", project: "/Users/me/other", model: "gpt-5"),
        ])
        #expect(try keys(store, EventFilter(search: "tACHO")) == ["claudeCode:a"])
        #expect(try keys(store, EventFilter(search: "OPUS")) == ["claudeCode:b"])
    }

    @Test func searchTakesWildcardsLiterally() throws {
        let store = try store([event("a", project: "/p/100%_done"), event("b", project: "/p/other")])
        #expect(try keys(store, EventFilter(search: "%")) == ["claudeCode:a"])
        #expect(try keys(store, EventFilter(search: "_")) == ["claudeCode:a"])
        #expect(try keys(store, EventFilter(search: "o%r")).isEmpty)
    }

    /// An empty search box filters nothing, not even events without a project or model.
    @Test func anEmptySearchMatchesEverything() throws {
        let store = try store([event("a", project: nil, model: nil), event("b", project: "/p")])
        #expect(try keys(store, EventFilter(search: "")) == ["claudeCode:a", "claudeCode:b"])
        #expect(try keys(store, EventFilter(modelContains: "")) == ["claudeCode:a", "claudeCode:b"])
    }

    // MARK: Log pages

    @Test func logPageIsKeysetPaginated() throws {
        let times = (0..<5).map { noon.addingTimeInterval(Double($0) * 60) }
        let store = try store(times.enumerated().map { event("\($0.offset)", at: $0.element) })

        let first = try store.logPage(filter: .all, before: nil, limit: 2)
        #expect(first.map(\.dedupKey) == ["claudeCode:4", "claudeCode:3"])

        let second = try store.logPage(filter: .all, before: try #require(first.last).time, limit: 2)
        #expect(second.map(\.dedupKey) == ["claudeCode:2", "claudeCode:1"])

        let third = try store.logPage(filter: .all, before: try #require(second.last).time, limit: 2)
        #expect(third.map(\.dedupKey) == ["claudeCode:0"])
    }

    /// A Grok turn on two models is two events with one `endedAt`. `before` holds only a time, so a page has to finish that
    /// time: stopping between the two would lose the second for good.
    @Test func aPageFinishesTheTimeItEndsOn() throws {
        let tied = noon.addingTimeInterval(60)
        let store = try store([
            event("older", at: noon),
            event("tie-1", at: tied),
            event("tie-2", at: tied),
            event("tie-3", at: tied),
            event("newest", at: noon.addingTimeInterval(120)),
        ])

        let first = try store.logPage(filter: .all, before: nil, limit: 2)
        #expect(first.map(\.dedupKey) == ["claudeCode:newest", "claudeCode:tie-3", "claudeCode:tie-2", "claudeCode:tie-1"])

        let second = try store.logPage(filter: .all, before: try #require(first.last).time, limit: 2)
        #expect(second.map(\.dedupKey) == ["claudeCode:older"])
    }

    @Test func aPageFinishesItsTimeOnlyWithinTheFilter() throws {
        let store = try store([
            event("kept-1", at: noon, source: .grok),
            event("other", at: noon, source: .pi),  // between the two, so only the filter can keep it out
            event("kept-2", at: noon, source: .grok),
        ])
        let page = try store.logPage(filter: EventFilter(sources: [.grok]), before: nil, limit: 1)
        #expect(page.map(\.dedupKey) == ["grok:kept-2", "grok:kept-1"])
    }

    @Test func aPageOfNoRowsIsEmpty() throws {
        let store = try store([event("a")])
        #expect(try store.logPage(filter: .all, before: nil, limit: 0).isEmpty)
        #expect(try store.logPage(filter: .all, before: nil, limit: -1).isEmpty)
    }

    @Test func logPageRestoresEveryField() throws {
        let original = UsageEvent(
            source: .codex, client: "codex-tui", dedupKey: "codex:k", sessionId: "s", project: "/p", isSubagent: true,
            provider: "openai", model: "gpt-5", time: noon, startTime: noon.addingTimeInterval(-9), generationMs: 1_234.5,
            speed: "fast", geo: "us",
            tokens: TokenCounts(input: 1, output: 2, reasoning: 3, cacheRead: 4, cacheWrite5m: 5, cacheWrite1h: 6)
        )
        let store = try store([original])
        #expect(try store.logPage(filter: .all, before: nil, limit: 1) == [original])
    }

    // MARK: Speed samples

    @Test func speedSamplesNeedTiming() throws {
        let store = try store([
            event("exact", model: "m1", generationMs: 1_500, tokens: TokenCounts(output: 3)),
            event("approximate", model: "m2", startTime: noon.addingTimeInterval(-9), tokens: TokenCounts(output: 5)),
            event("untimed", model: "m3", tokens: TokenCounts(output: 7)),
        ])
        let samples = try store.speedSamples(in: everything)
        #expect(samples.count == 2)
        #expect(samples.first { $0.model == "m1" } == SpeedSample(model: "m1", output: 3, generationMs: 1_500, startTime: nil, time: noon))
        #expect(samples.first { $0.model == "m2" } == SpeedSample(model: "m2", output: 5, generationMs: nil, startTime: noon.addingTimeInterval(-9), time: noon))
    }

    /// A speed is reported per model, so without one there is nothing to report it under.
    @Test func speedSamplesNeedAModel() throws {
        let store = try store([event("a", model: nil, generationMs: 1_500)])
        #expect(try store.speedSamples(in: everything).isEmpty)
    }

    @Test func speedSamplesFollowTheRange() throws {
        let store = try store([event("a", at: date("2025-01-01T00:00:00Z"), model: "m1", generationMs: 1_500)])
        #expect(try store.speedSamples(in: everything).isEmpty)
    }

    // MARK: Local calendar (Review Focus 3)

    /// Local midnight in India is 18:30 UTC, half an hour off the hour.
    @Test func dayBucketsFollowLocalCalendar() throws {
        let store = try store([
            event("a", at: date("2026-11-02T18:29:00Z"), tokens: TokenCounts(output: 3)),
            event("b", at: date("2026-11-02T18:31:00Z"), tokens: TokenCounts(output: 5)),
        ])
        let groups = try store.quarterHourGroups(in: everything, thresholds: [])

        let days = LocalBuckets.days(groups, calendar: try calendar("Asia/Kolkata"))

        #expect(days.count == 2)
        #expect(days[date("2026-11-01T18:30:00Z")]?.map(\.tokens.output) == [3])
        #expect(days[date("2026-11-02T18:30:00Z")]?.map(\.tokens.output) == [5])
    }

    /// Nepal is the awkward case: its midnight, 18:15 UTC, sits on a quarter hour and no coarser boundary.
    @Test func dayBucketsFollowAQuarterHourOffset() throws {
        let store = try store([
            event("a", at: date("2026-11-02T18:14:59Z"), tokens: TokenCounts(output: 3)),
            event("b", at: date("2026-11-02T18:15:00Z"), tokens: TokenCounts(output: 5)),
        ])
        let groups = try store.quarterHourGroups(in: everything, thresholds: [])

        let days = LocalBuckets.days(groups, calendar: try calendar("Asia/Kathmandu"))

        #expect(days[date("2026-11-01T18:15:00Z")]?.map(\.tokens.output) == [3])
        #expect(days[date("2026-11-02T18:15:00Z")]?.map(\.tokens.output) == [5])
    }

    /// Cuba moves its clocks at midnight, so 8 March 2026 has no 00:00 and starts at 01:00.
    @Test func dayBucketsCopeWithADayThatHasNoMidnight() throws {
        let store = try store([
            event("before", at: date("2026-03-08T04:50:00Z"), tokens: TokenCounts(output: 3)),
            event("first", at: date("2026-03-08T05:10:00Z"), tokens: TokenCounts(output: 5)),
            event("later", at: date("2026-03-09T03:50:00Z"), tokens: TokenCounts(output: 7)),
        ])
        let groups = try store.quarterHourGroups(in: everything, thresholds: [])

        let days = LocalBuckets.days(groups, calendar: try calendar("America/Havana"))

        #expect(days.count == 2)
        #expect(days[date("2026-03-08T05:00:00Z")]?.reduce(0) { $0 + $1.tokens.output } == 12)
    }

    /// New York's 25-hour day still holds every event of that day under one key.
    @Test func dayBucketsKeepALongDayTogether() throws {
        let store = try store([
            event("early", at: date("2026-11-01T04:10:00Z"), tokens: TokenCounts(output: 3)),
            event("late", at: date("2026-11-02T04:50:00Z"), tokens: TokenCounts(output: 5)),
        ])
        let groups = try store.quarterHourGroups(in: everything, thresholds: [])

        let days = LocalBuckets.days(groups, calendar: try calendar("America/New_York"))

        #expect(days.count == 1)
        #expect(days[date("2026-11-01T04:00:00Z")]?.reduce(0) { $0 + $1.tokens.output } == 8)
    }

    /// The clocks go back at 02:00 EDT on Sunday 1 November 2026, so 01:30 happens twice.
    @Test func hourOfWeekAcrossDST() throws {
        let store = try store([
            event("edt", at: date("2026-11-01T05:30:00Z"), tokens: TokenCounts(output: 3)),
            event("est", at: date("2026-11-01T06:30:00Z"), tokens: TokenCounts(output: 5)),
        ])
        let groups = try store.quarterHourGroups(in: everything, thresholds: [])

        let cells = try hourOfWeek(groups, try calendar("America/New_York", firstWeekday: 1))

        #expect(cells[0][1] == 8)
        #expect(cells.joined().reduce(0, +) == 8)
    }

    /// The clocks go forward at 02:00 EST on Sunday 8 March 2026: the minute after 01:59 is 03:00.
    @Test func hourOfWeekStepsOverTheMissingHour() throws {
        let store = try store([
            event("before", at: date("2026-03-08T06:59:00Z"), tokens: TokenCounts(output: 3)),
            event("after", at: date("2026-03-08T07:00:00Z"), tokens: TokenCounts(output: 5)),
        ])
        let groups = try store.quarterHourGroups(in: everything, thresholds: [])

        let cells = try hourOfWeek(groups, try calendar("America/New_York"))

        #expect(cells[0][1] == 3)
        #expect(cells[0][2] == 0)
        #expect(cells[0][3] == 5)
    }

    /// Row 0 is the calendar's first weekday, so with Monday first a Sunday is the last row.
    @Test func hourOfWeekRowsStartAtTheFirstWeekday() throws {
        let groups = try store([
            event("sunday", at: date("2026-11-01T10:00:00Z"), tokens: TokenCounts(output: 3)),
            event("monday", at: date("2026-11-02T11:00:00Z"), tokens: TokenCounts(output: 5)),
            event("saturday", at: date("2026-11-07T12:00:00Z"), tokens: TokenCounts(output: 7)),
        ]).quarterHourGroups(in: everything, thresholds: [])

        let monday = try hourOfWeek(groups, try calendar("UTC", firstWeekday: 2))
        #expect(monday[6][10] == 3)
        #expect(monday[0][11] == 5)
        #expect(monday[5][12] == 7)

        let saturday = try hourOfWeek(groups, try calendar("UTC", firstWeekday: 7))
        #expect(saturday[1][10] == 3)
        #expect(saturday[2][11] == 5)
        #expect(saturday[0][12] == 7)
    }

    /// 18:15 UTC is 23:45 on Monday in India; 18:30 UTC is 00:00 on Tuesday.
    @Test func hourOfWeekFollowsAHalfHourOffset() throws {
        let groups = try store([
            event("monday", at: date("2026-11-02T18:29:00Z"), tokens: TokenCounts(output: 3)),
            event("tuesday", at: date("2026-11-02T18:31:00Z"), tokens: TokenCounts(output: 5)),
        ]).quarterHourGroups(in: everything, thresholds: [])

        let cells = try hourOfWeek(groups, try calendar("Asia/Kolkata"))

        #expect(cells[1][23] == 3)
        #expect(cells[2][0] == 5)
    }

    @Test func hourOfWeekCountsEveryTokenCategory() throws {
        let groups = try store([
            event("a", at: date("2026-11-01T10:00:00Z"), tokens: TokenCounts(input: 1, output: 2, reasoning: 500, cacheRead: 4, cacheWrite5m: 8, cacheWrite1h: 16)),
        ]).quarterHourGroups(in: everything, thresholds: [])
        #expect(try hourOfWeek(groups, try calendar("UTC"))[0][10] == 31)
    }

    @Test func noGroupsFillNoBuckets() throws {
        let utc = try calendar("UTC")
        #expect(LocalBuckets.days([], calendar: utc).isEmpty)
        #expect(LocalBuckets.hourOfWeek([], calendar: utc) == Array(repeating: Array(repeating: 0, count: 24), count: 7))
    }
}
