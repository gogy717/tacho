import Foundation
import os
import Testing
@testable import TachoKit

/// Stands in for the keychain and the network, and counts what they are asked for: no test goes near either.
private final class FetchLog: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: (tokens: 0, sends: 0))
    private let holdsToken: Bool
    private let released = DispatchSemaphore(value: 0)

    init(holdsToken: Bool = false) {
        self.holdsToken = holdsToken
    }

    var tokens: Int { counts.withLock { $0.tokens } }
    var sends: Int { counts.withLock { $0.sends } }

    func token() throws -> ClaudeToken? {
        counts.withLock { $0.tokens += 1 }
        if holdsToken { released.wait() }
        return ClaudeToken(accessToken: "tok", expiresAt: .distantFuture)
    }

    /// Lets a held `token` return, as a slow keychain read finally does.
    func releaseToken() {
        released.signal()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        counts.withLock { $0.sends += 1 }
        throw CancellationError()
    }
}

/// Counts how many times files are looked for, which a backfill does once.
private final class CountingReader: SourceReader {
    let source = Source.claudeCode
    private let looks = OSAllocatedUnfairLock(initialState: 0)

    var count: Int { looks.withLock { $0 } }

    func discover(root: URL) throws -> [URL] {
        looks.withLock { $0 += 1 }
        return []
    }

    func read(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        throw CancellationError()
    }
}

/// Takes a while over each file, so that a backfill lasts long enough to watch.
private struct SlowReader: SourceReader {
    let source = Source.claudeCode
    let files: [URL]
    private let reads = OSAllocatedUnfairLock(initialState: 0)

    init(files: [URL]) {
        self.files = files
    }

    /// How many reads have finished.
    var finished: Int { reads.withLock { $0 } }

    func discover(root: URL) throws -> [URL] {
        files
    }

    func read(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        defer { reads.withLock { $0 += 1 } }
        Thread.sleep(forTimeInterval: 0.05)
        return ReadResult(events: [], quotas: [], cursor: FileCursor(inode: 1, size: 0, offset: 0, mtime: Date()), skipped: 0)
    }
}

/// Takes a while over each file, and finds one event in it: what a source's old logs look like to a rescan.
private struct DatedReader: SourceReader {
    let source = Source.claudeCode
    let events: [URL: UsageEvent]
    private let reads = OSAllocatedUnfairLock(initialState: 0)

    init(events: [URL: UsageEvent]) {
        self.events = events
    }

    /// How many reads have finished.
    var finished: Int { reads.withLock { $0 } }

    func discover(root: URL) throws -> [URL] {
        Array(events.keys)
    }

    func read(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        defer { reads.withLock { $0 += 1 } }
        Thread.sleep(forTimeInterval: 0.05)
        return ReadResult(
            events: events[url].map { [$0] } ?? [],
            quotas: [],
            cursor: FileCursor(inode: 1, size: 0, offset: 0, mtime: Date(timeIntervalSince1970: 0)),
            skipped: 0
        )
    }
}

/// Whether `condition` comes true, however loaded the machine is: a fixed sleep is only a guess at that.
private func eventually(_ condition: () async -> Bool) async throws -> Bool {
    for _ in 0..<6_000 {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(5))
    }
    return false
}

struct EngineTests {
    private let now = date("2026-11-03T10:00:00Z")
    private let utc: Calendar

    init() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        utc = calendar
    }

    /// $1 per million tokens of every kind, so that a token count reads straight as a price.
    private func entry(_ id: String, provider: String = "anthropic", longContext: LongContextPrice? = nil) -> PriceEntry {
        PriceEntry(id: id, provider: provider, price: flat(1), longContext: longContext)
    }

    private func flat(_ rate: Double) -> Price {
        Price(input: rate, output: rate, cacheRead: rate, cacheWrite5m: rate, cacheWrite1h: rate)
    }

    /// A `~/.claude.json` with one limit in its usage cache.
    private static let claudeConfig = #"{"oauthAccount":{"accountUuid":"acc1"},"cachedUsageUtilization":{"accountUuid":"acc1","fetchedAtMs":1793683423877,"utilization":{"limits":[{"kind":"session","percent":3,"resets_at":"2026-11-03T09:20:00.709695+00:00"}]}}}"#

    private func preferences(_ change: (inout Preferences) -> Void = { _ in }) throws -> Preferences {
        var preferences = Preferences.defaults(home: try makeTempDir())
        preferences.priceOverrides = ["test-model": entry("test-model")]
        change(&preferences)
        return preferences
    }

    private func engine(
        store: EventStore? = nil,
        home: URL? = nil,
        preferences: Preferences? = nil,
        fetches: FetchLog = FetchLog()
    ) throws -> (engine: Engine, store: EventStore) {
        let store = try store ?? EventStore.inMemory()
        let preferences = try preferences ?? self.preferences()
        let engine = try Engine(
            store: store,
            home: home ?? makeTempDir(),
            preferences: preferences,
            readers: [],
            token: { try fetches.token() },
            send: { try await fetches.send($0) }
        )
        return (engine, store)
    }

    private func event(
        _ name: String,
        ago: TimeInterval = 0,
        source: Source = .claudeCode,
        client: String? = nil,
        project: String? = nil,
        provider: String? = nil,
        model: String? = "test-model",
        startTime: Date? = nil,
        generationMs: Double? = nil,
        tokens: Int = 1
    ) -> UsageEvent {
        UsageEvent(
            source: source, client: client, dedupKey: "\(source.rawValue):\(name)", project: project, provider: provider, model: model,
            time: now.addingTimeInterval(-ago), startTime: startTime, generationMs: generationMs, tokens: TokenCounts(input: tokens)
        )
    }

    private func snapshot(
        _ provider: QuotaProvider = .anthropic,
        _ window: QuotaWindow = .fiveHour,
        scope: String? = nil,
        used: Double = 20,
        resetsIn: TimeInterval = 10_800,
        observedAgo: TimeInterval = 600
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider, window: window, scope: scope, usedPercent: used,
            resetsAt: now.addingTimeInterval(resetsIn), observedAt: now.addingTimeInterval(-observedAgo), origin: .claudeCache
        )
    }

    // MARK: Rate

    @Test func rateCountsTheLastFiveMinutes() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            event("a", ago: 10, tokens: 12_000),
            event("b", ago: 290, tokens: 400),
            event("c", ago: 301, tokens: 5_000),
        ])

        let dashboard = try await engine.dashboard(now: now, calendar: utc)

        #expect(dashboard.perMinute == 2_480)
        #expect(abs(dashboard.perSecond - 41.33) < 0.01)
        #expect(!dashboard.isIdle)
        #expect(dashboard.lastMinute.input == 2_480)
    }

    @Test func noEventsIsIdle() async throws {
        let dashboard = try await engine().engine.dashboard(now: now, calendar: utc)
        #expect(dashboard.isIdle)
        #expect(dashboard.perMinute == 0)
        #expect(dashboard.perSecond == 0)
        #expect(dashboard.sources.isEmpty)
        #expect(dashboard.quotas.isEmpty)
        #expect(dashboard.alert == .none)
        #expect(dashboard.series.count == 60)
    }

    /// (now − 300, now]: real timestamps carry fractions, which `Date` holds more finely than the store's unix seconds.
    @Test func theRateWindowHoldsNowAndNotItsStart() async throws {
        for millis in 120..<136 {
            let now = date("2026-11-03T10:00:00.\(millis)Z")
            let seconds = now.timeIntervalSince1970
            let (engine, store) = try engine()
            var atNow = event("now", tokens: 15)
            atNow.time = now
            var atStart = event("start", tokens: 25)
            atStart.time = Date(timeIntervalSince1970: seconds - 300)
            var justInside = event("inside", tokens: 35)
            justInside.time = Date(timeIntervalSince1970: (seconds - 300).nextUp)
            var justAfter = event("after", tokens: 55)
            justAfter.time = Date(timeIntervalSince1970: seconds.nextUp)
            try store.upsert([atNow, atStart, justInside, justAfter])

            #expect(try await engine.dashboard(now: now, calendar: utc).perMinute == 10)
        }
    }

    @Test func theSeriesHasSixtyMinutesEndingNow() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", tokens: 3), event("b", ago: 120, tokens: 5)])

        let series = try await engine.dashboard(now: now, calendar: utc).series

        try #require(series.count == 60)
        #expect(series[59].input == 3)
        #expect(series[57].input == 5)
    }

    // MARK: Sources

    @Test func sourcesSortActiveFirst() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            event("codex", ago: 30, source: .codex, tokens: 10),
            event("claude", ago: 600, tokens: 9_000),
        ])

        let sources = try await engine.dashboard(now: now, calendar: utc).sources

        #expect(sources.map(\.source) == [.codex, .claudeCode])
        #expect(sources[0].isActive)
        #expect(!sources[1].isActive)
    }

    @Test func activeSourcesSortByRateAndInactiveOnesByLastActivity() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            event("slow-but-recent", ago: 5, source: .omp, tokens: 5),
            event("fast-but-earlier", ago: 30, source: .pi, tokens: 500),
            event("older", ago: 7_200, source: .grok, tokens: 1),
            event("newer", ago: 3_600, source: .codex, tokens: 1),
        ])
        let sources = try await engine.dashboard(now: now, calendar: utc).sources
        #expect(sources.map(\.source) == [.pi, .omp, .codex, .grok])
    }

    @Test func activeMeansWithinFiveMinutes() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("edge", ago: 300, source: .pi), event("past", ago: 301, source: .omp)])
        let sources = try await engine.dashboard(now: now, calendar: utc).sources
        #expect(sources.first { $0.source == .pi }?.isActive == true)
        #expect(sources.first { $0.source == .omp }?.isActive == false)
    }

    /// Every enabled source with events: one that was last used last week still has a row.
    @Test func aSourceWithNoEventsTodayStillHasARow() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("old", ago: 7 * 86_400, source: .grok, tokens: 3)])

        let row = try #require(try await engine.dashboard(now: now, calendar: utc).sources.first)

        #expect(row.source == .grok)
        #expect(row.today == .zero)
        #expect(row.clients.isEmpty)
        #expect(row.lastActivity == now.addingTimeInterval(-7 * 86_400))
    }

    @Test func aDisabledSourceLeavesTheDashboard() async throws {
        let (engine, store) = try engine(preferences: preferences { $0.enabledSources = [.claudeCode] })
        try store.upsert([event("kept", ago: 10, tokens: 15), event("off", ago: 10, source: .pi, tokens: 5)])

        let dashboard = try await engine.dashboard(now: now, calendar: utc)

        #expect(dashboard.sources.map(\.source) == [.claudeCode])
        #expect(dashboard.perMinute == 3)
        #expect(dashboard.today.tokens.input == 15)
        #expect(abs(dashboard.today.cost.usd - 0.000015) < 1e-12)
    }

    @Test func clientsSplitWithinASource() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            event("a", ago: 10, client: "cli", tokens: 15),
            event("b", ago: 3_000, client: "cli", tokens: 25),
            event("c", ago: 20, client: "claude-desktop", tokens: 35),
        ])

        let row = try #require(try await engine.dashboard(now: now, calendar: utc).sources.first)

        #expect(row.clients.map(\.client) == ["cli", "claude-desktop"])
        #expect(row.clients.first { $0.client == "cli" } == ClientRow(client: "cli", perMinute: 3, today: 40))
        #expect(row.clients.first { $0.client == "claude-desktop" } == ClientRow(client: "claude-desktop", perMinute: 7, today: 35))
        #expect(row.perMinute == 10)
        #expect(row.today.input == 75)
    }

    /// Ten seconds into the day, the rate window is mostly yesterday: that client is still working, with nothing yet today.
    @Test func aClientBusyAcrossMidnightKeepsItsRow() async throws {
        let midnight = date("2026-11-03T00:00:10Z")
        let (engine, store) = try engine()
        var busy = event("a", client: "cli", tokens: 15)
        busy.time = date("2026-11-02T23:59:50Z")
        try store.upsert([busy])

        let row = try #require(try await engine.dashboard(now: midnight, calendar: utc).sources.first)

        #expect(row.clients == [ClientRow(client: "cli", perMinute: 3, today: 0)])
    }

    /// The dashboard shows `now`, whatever a clock ahead of ours may have written.
    @Test func anEventStillToComeIsNotTheLastActivity() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("past", ago: 600), event("future", ago: -600)])
        let row = try #require(try await engine.dashboard(now: now, calendar: utc).sources.first)
        #expect(row.lastActivity == now.addingTimeInterval(-600))
        #expect(!row.isActive)
    }

    /// A source that names no client has no sub-rows, and its tokens still count on its own row.
    @Test func eventsWithoutAClientAreNoClientRow() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", ago: 10, source: .pi, tokens: 15)])

        let row = try #require(try await engine.dashboard(now: now, calendar: utc).sources.first)

        #expect(row.clients.isEmpty)
        #expect(row.perMinute == 3)
    }

    @Test func sourcesWithoutQuotaCarryHourlyCost() async throws {
        let (engine, store) = try engine(preferences: preferences {
            $0.priceOverrides["test-grok"] = entry("test-grok", provider: "xai")
        })
        try store.upsert([
            event("claude", ago: 600, tokens: 500_000),
            event("pi", ago: 1_200, source: .pi, provider: "xai", model: "test-grok", tokens: 200_000),
        ])
        try store.record([snapshot()])

        let sources = try await engine.dashboard(now: now, calendar: utc).sources

        let claude = try #require(sources.first { $0.source == .claudeCode })
        let pi = try #require(sources.first { $0.source == .pi })
        #expect(claude.hasQuota)
        #expect(!pi.hasQuota)
        #expect(abs(pi.costLastHour.usd - 0.20) < 1e-9)
        #expect(abs(claude.costLastHour.usd - 0.50) < 1e-9)
    }

    /// (now − 3600, now].
    @Test func theHourlyCostHoldsNowAndNotItsStart() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("now", tokens: 1_000_000), event("start", ago: 3_600, tokens: 4_000_000)])
        let row = try #require(try await engine.dashboard(now: now, calendar: utc).sources.first)
        #expect(abs(row.costLastHour.usd - 1) < 1e-9)
    }

    /// Only today's events say which account a source is using.
    @Test func quotaNeedsAnEventToday() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("old", ago: 2 * 86_400)])
        try store.record([snapshot()])
        let row = try #require(try await engine.dashboard(now: now, calendar: utc).sources.first)
        #expect(!row.hasQuota)
    }

    @Test func quotaFollowsEachEventsProvider() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", ago: 10, source: .omp, provider: "openai-codex"), event("b", ago: 10, source: .pi, provider: "ollama")])
        try store.record([snapshot(.openai)])
        let sources = try await engine.dashboard(now: now, calendar: utc).sources
        #expect(sources.first { $0.source == .omp }?.hasQuota == true)
        #expect(sources.first { $0.source == .pi }?.hasQuota == false)
    }

    // MARK: Today

    @Test func todayStartsAtLocalMidnight() async throws {
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let (engine, store) = try engine()
        var yesterday = event("yesterday", tokens: 3)
        yesterday.time = date("2026-11-02T15:59:00Z")
        var today = event("today", tokens: 5)
        today.time = date("2026-11-02T16:01:00Z")
        try store.upsert([yesterday, today])

        let dashboard = try await engine.dashboard(now: date("2026-11-02T17:00:00Z"), calendar: shanghai)

        #expect(dashboard.today.tokens.input == 5)
        #expect(dashboard.sources.first?.today.input == 5)
    }

    @Test func todayCountsEverySourceAndItsCost() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            event("a", ago: 3_600, tokens: 1_000_000),
            event("b", ago: 3_600, source: .pi, tokens: 2_000_000),
            event("unpriced", ago: 3_600, source: .pi, model: "gemma4:12b", tokens: 4_000_000),
        ])

        let dashboard = try await engine.dashboard(now: now, calendar: utc)

        #expect(dashboard.today.tokens.input == 7_000_000)
        #expect(abs(dashboard.today.cost.usd - 3) < 1e-9)
        #expect(dashboard.today.cost.unpricedModels == ["gemma4:12b"])
        #expect(abs((dashboard.sources.first { $0.source == .pi }?.todayCost.usd ?? 0) - 2) < 1e-9)
    }

    @Test func speedsCoverTheLast24Hours() async throws {
        let (engine, store) = try engine()
        var timed = event("in", ago: 86_399, generationMs: 10_000)
        timed.tokens = TokenCounts(output: 600)
        var old = event("out", ago: 86_400, model: "old-model", generationMs: 10_000)
        old.tokens = TokenCounts(output: 600)
        try store.upsert([timed, old])

        let speeds = try await engine.dashboard(now: now, calendar: utc).today.speeds

        #expect(speeds == [ModelSpeed(model: "test-model", tokensPerSecond: 60, samples: 1, approximate: false)])
    }

    /// The Speed card's figures: a switched-off source's requests are in none of them, even of a model an enabled one uses too.
    @Test func speedsLeaveOutDisabledSources() async throws {
        let (engine, store) = try engine(preferences: preferences { $0.enabledSources = [.claudeCode] })
        var on = event("on", ago: 60, generationMs: 10_000)
        on.tokens = TokenCounts(output: 900)
        let off = [1, 2].map { index in
            var sample = event("off\(index)", ago: 120, source: .pi, generationMs: 10_000)
            sample.tokens = TokenCounts(output: 300)
            return sample
        }
        try store.upsert(off + [on])

        let speeds = try await engine.dashboard(now: now, calendar: utc).today.speeds

        #expect(speeds == [ModelSpeed(model: "test-model", tokensPerSecond: 90, samples: 1, approximate: false)])
    }

    // MARK: Quotas

    @Test func quotasComeInProviderThenWindowOrder() async throws {
        let (engine, store) = try engine()
        try store.record([
            snapshot(.xai, .weekly),
            snapshot(.openai, .weekly),
            snapshot(.anthropic, .weekly, scope: "Fable"),
            snapshot(.anthropic, .weekly, scope: "Atlas"),
            snapshot(.anthropic, .weekly),
            snapshot(.openai, .fiveHour),
            snapshot(.anthropic, .fiveHour),
        ])

        let quotas = try await engine.dashboard(now: now, calendar: utc).quotas

        let order = quotas.map { "\($0.snapshot.provider.rawValue) \($0.snapshot.window.rawValue) \($0.snapshot.scope ?? "-")" }
        #expect(order == [
            "anthropic fiveHour -", "anthropic weekly -", "anthropic weekly Atlas", "anthropic weekly Fable",
            "openai fiveHour -", "openai weekly -", "xai weekly -",
        ])
    }

    @Test func aProjectionUsesLocalUse() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("before", ago: 3_600, tokens: 10_000_000), event("after", ago: 300, tokens: 1_000_000)])
        try store.record([snapshot()])

        let projection = try #require(try await engine.dashboard(now: now, calendar: utc).quotas.first)

        #expect(projection.method == .calibrated)
        #expect(abs(projection.estimatedPercent - 22) < 1e-9)
    }

    @Test func theAlertFollowsTheProjections() async throws {
        let (engine, store) = try engine()
        try store.record([snapshot(used: 95)])
        #expect(try await engine.dashboard(now: now, calendar: utc).alert == .red)
    }

    /// The "count toward quota forecasts" switch.
    @Test func weightsCountOnlyTheQuotaSources() async throws {
        let (engine, store) = try engine(preferences: preferences { $0.quotaSources = [.pi] })
        try store.upsert([event("claude", ago: 3_600, tokens: 10_000_000)])
        try store.record([snapshot()])
        let projection = try #require(try await engine.dashboard(now: now, calendar: utc).quotas.first)
        #expect(projection.method == .windowAverage)
    }

    // MARK: Weights between ticks

    private func estimate(_ engine: Engine, after seconds: TimeInterval) async throws -> Double {
        let dashboard = try await engine.dashboard(now: now.addingTimeInterval(seconds), calendar: utc)
        return try #require(dashboard.quotas.first).estimatedPercent
    }

    /// Its outcome is `.unknown` from the snapshot alone, and it would be the longest pass of all, back to where the window opened: real
    /// limits a fortnight old cost most of the tick's quota reading, for an answer nothing looked at.
    @Test func aWindowLongOverCostsNoPassOverTheRows() async throws {
        let (engine, store) = try engine()
        let length = QuotaWindow.fiveHour.length
        try store.record([snapshot(resetsIn: -length, observedAgo: length + 600)])
        let dashboard = try await engine.dashboard(now: now)
        #expect(dashboard.quotas.map(\.outcome) == [.unknown])
        #expect(await engine.weightPasses == 0)
    }

    @Test func aWindowNotYetLongOverStillCostsItsPass() async throws {
        let (engine, store) = try engine()
        let length = QuotaWindow.fiveHour.length
        try store.record([snapshot(resetsIn: 1 - length, observedAgo: length + 600)])
        _ = try await engine.dashboard(now: now)
        #expect(await engine.weightPasses == 1)
    }

    /// What it spares must not be what a live limit needs.
    @Test func aWindowLongOverLeavesItsLiveNeighbourAlone() async throws {
        let (engine, store) = try engine()
        let length = QuotaWindow.fiveHour.length
        try store.record([snapshot(.openai, resetsIn: -2 * length, observedAgo: 3 * length), snapshot()])
        let dashboard = try await engine.dashboard(now: now)
        #expect(dashboard.quotas.count == 2)
        #expect(await engine.weightPasses == 1)
    }

    /// A tick is every second, and a full pass over the quota windows would cost more than the CPU budget allows.
    @Test func weightsAreNotRecomputedEveryTick() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("before", ago: 3_600, tokens: 10_000_000), event("after", ago: 300, tokens: 1_000_000)])
        try store.record([snapshot()])
        #expect(abs(try await estimate(engine, after: 0) - 22) < 1e-9)

        try store.upsert([event("new", ago: -1, tokens: 5_000_000)])

        #expect(abs(try await estimate(engine, after: 2) - 22) < 1e-9)
        #expect(abs(try await estimate(engine, after: 14) - 22) < 1e-9)
    }

    @Test func newDataRefreshesTheWeightsSoon() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("before", ago: 3_600, tokens: 10_000_000), event("after", ago: 300, tokens: 1_000_000)])
        try store.record([snapshot()])
        _ = try await estimate(engine, after: 0)

        try store.upsert([event("new", ago: -1, tokens: 5_000_000)])

        #expect(abs(try await estimate(engine, after: 15) - 32) < 1e-9)
    }

    /// Nothing new, so nothing to do for a while. But `recent` slides with the clock, so it cannot wait for ever.
    @Test func weightsRefreshAtACoarseIntervalWithoutNewData() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("before", ago: 1_790, tokens: 10_000_000)])
        try store.record([snapshot()])
        func outcome(after seconds: TimeInterval) async throws -> Projection.Outcome {
            try #require(try await engine.dashboard(now: now.addingTimeInterval(seconds), calendar: utc).quotas.first).outcome
        }

        #expect(try await outcome(after: 0) != .idle)
        #expect(try await outcome(after: 59) != .idle)
        #expect(try await outcome(after: 60) == .idle)
    }

    /// New weights and an old snapshot do not belong together: use since the old snapshot would be counted twice.
    @Test func aNewSnapshotAndItsWeightsChangeTogether() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("before", ago: 3_600, tokens: 10_000_000)])
        try store.record([snapshot(used: 20)])
        _ = try await estimate(engine, after: 0)

        try store.record([snapshot(used: 40, observedAgo: 100)])

        #expect(abs(try await estimate(engine, after: 2) - 20) < 1e-9)
        #expect(abs(try await estimate(engine, after: 15) - 40) < 1e-9)
    }

    /// Spec §5.5 rule 8: past its reset a snapshot is void, and the estimate is 0% plus use since then, from the first tick.
    /// Weights from before the reset would still count what came before it.
    @Test func aResetMakesTheWeightsDueAtOnce() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("before", ago: 3_600, tokens: 10_000_000), event("after", ago: 300, tokens: 2_500_000)])
        try store.record([snapshot(used: 50, resetsIn: 30)])
        #expect(abs(try await estimate(engine, after: 0) - 62.5) < 1e-9)

        #expect(try await estimate(engine, after: 31) == 0)
    }

    @Test func eachTickProjectsAgainWithCachedWeights() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("before", ago: 600, tokens: 10_000_000)])
        try store.record([snapshot(resetsIn: 30)])
        func resetsAt(after seconds: TimeInterval) async throws -> Date {
            try #require(try await engine.dashboard(now: now.addingTimeInterval(seconds), calendar: utc).quotas.first).resetsAt
        }

        #expect(try await resetsAt(after: 0) == now.addingTimeInterval(30))
        #expect(try await resetsAt(after: 31) == now.addingTimeInterval(18_030))
    }

    // MARK: Figures that move with the clock alone

    private func dashboard(_ engine: Engine, after seconds: TimeInterval) async throws -> Dashboard {
        try await engine.dashboard(now: now.addingTimeInterval(seconds), calendar: utc)
    }

    /// Not one new row in any of these tests: only the clock moves, and the figure must still be right on that tick.
    @Test func theRateFallsTheSecondAnEventLeavesTheWindow() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("old", ago: 290, tokens: 35), event("new", ago: 260, tokens: 25)])

        #expect(try await dashboard(engine, after: 0).perMinute == 12)
        #expect(try await dashboard(engine, after: 9).perMinute == 12)
        #expect(try await dashboard(engine, after: 10).perMinute == 5)
        #expect(try await dashboard(engine, after: 39).perMinute == 5)
        #expect(try await dashboard(engine, after: 40).perMinute == 0)
        #expect(try await dashboard(engine, after: 40).isIdle)
    }

    @Test func aSourcesRateFallsWithTheWindowToo() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", ago: 290, client: "cli", tokens: 35)])

        #expect(try await dashboard(engine, after: 0).sources.first?.perMinute == 7)
        #expect(try await dashboard(engine, after: 0).sources.first?.clients.first?.perMinute == 7)

        let later = try await dashboard(engine, after: 10)
        #expect(later.sources.first?.perMinute == 0)
        #expect(later.sources.first?.clients.first?.perMinute == 0)
        #expect(later.sources.first?.clients.first?.today == 35)
    }

    @Test func theSeriesMovesOnWithTheMinute() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", ago: 0, tokens: 3)])

        #expect(try await dashboard(engine, after: 0).series[59].input == 3)
        #expect(try await dashboard(engine, after: 59).series[59].input == 3)
        #expect(try await dashboard(engine, after: 60).series[58].input == 3)
        #expect(try await dashboard(engine, after: 60).series[59].input == 0)
        #expect(try await dashboard(engine, after: 3_600).series.allSatisfy { $0 == .zero })
    }

    @Test func anHourlyCostFallsOutWithNoNewRows() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", ago: 3_590, tokens: 1_000_000), event("b", ago: 60, tokens: 2_000_000)])
        func cost(after seconds: TimeInterval) async throws -> Double {
            try await dashboard(engine, after: seconds).sources.first?.costLastHour.usd ?? -1
        }

        #expect(abs(try await cost(after: 0) - 3) < 1e-9)
        #expect(abs(try await cost(after: 9) - 3) < 1e-9)
        #expect(abs(try await cost(after: 10) - 2) < 1e-9)
    }

    @Test func aSourceGoesInactiveAtFiveMinutesWithNoNewRows() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", ago: 290, source: .pi), event("b", ago: 280, source: .omp)])

        #expect(try await dashboard(engine, after: 10).sources.first { $0.source == .pi }?.isActive == true)
        #expect(try await dashboard(engine, after: 11).sources.first { $0.source == .pi }?.isActive == false)
        #expect(try await dashboard(engine, after: 11).sources.first { $0.source == .omp }?.isActive == true)
        #expect(try await dashboard(engine, after: 11).sources.map(\.source) == [.omp, .pi])
    }

    @Test func todayRollsAtMidnightWithNoNewRows() async throws {
        let nearMidnight = date("2026-11-03T23:59:30Z")
        let (engine, store) = try engine()
        var late = event("late", tokens: 3_000_000)
        late.time = date("2026-11-03T23:59:00Z")
        try store.upsert([late])

        let before = try await engine.dashboard(now: nearMidnight, calendar: utc)
        #expect(before.today.tokens.input == 3_000_000)
        #expect(abs(before.today.cost.usd - 3) < 1e-9)
        #expect(before.sources.first?.today.input == 3_000_000)

        let after = try await engine.dashboard(now: date("2026-11-04T00:00:00Z"), calendar: utc)
        #expect(after.today.tokens == .zero)
        #expect(after.today.cost.usd == 0)
        #expect(after.sources.first?.today == .zero)
        #expect(after.sources.first?.hasQuota == false)
    }

    @Test func aSpeedLeavesTheDayWithNoNewRows() async throws {
        let (engine, store) = try engine()
        var older = event("older", ago: 86_390, model: "m-old", generationMs: 10_000)
        older.tokens = TokenCounts(output: 600)
        var newer = event("newer", ago: 100, model: "m-new", generationMs: 10_000)
        newer.tokens = TokenCounts(output: 300)
        try store.upsert([older, newer])

        #expect(try await dashboard(engine, after: 9).today.speeds.map(\.model).sorted() == ["m-new", "m-old"])
        #expect(try await dashboard(engine, after: 10).today.speeds.map(\.model) == ["m-new"])
    }

    /// A median moves when one of several samples of a model leaves, not only when the model does.
    @Test func aMedianMovesWhenOneOfItsSamplesLeaves() async throws {
        let (engine, store) = try engine()
        var events: [UsageEvent] = []
        for (index, output) in [100, 200, 900].enumerated() {
            var sample = event("s\(index)", ago: 86_390 - Double(index) * 100, generationMs: 10_000)
            sample.tokens = TokenCounts(output: output)
            events.append(sample)
        }
        try store.upsert(events)

        #expect(try await dashboard(engine, after: 0).today.speeds.first?.tokensPerSecond == 20)
        #expect(try await dashboard(engine, after: 10).today.speeds.first?.tokensPerSecond == 55)
    }

    /// The window is (now − 24 h, now]: the first value past its start is still in it.
    @Test func aSampleJustInsideTheDayStays() async throws {
        let (engine, store) = try engine()
        let later = now.addingTimeInterval(10).timeIntervalSince1970
        var edge = event("edge", model: "m", generationMs: 10_000)
        edge.time = Date(timeIntervalSince1970: (later - 86_400).nextUp)
        edge.tokens = TokenCounts(output: 600)
        // Leaving on the same tick: samples are only looked at when one has gone.
        var gone = event("gone", ago: 86_395, model: "gone", generationMs: 10_000)
        gone.tokens = TokenCounts(output: 600)
        try store.upsert([edge, gone])

        #expect(try await dashboard(engine, after: 0).today.speeds.count == 2)
        #expect(try await dashboard(engine, after: 10).today.speeds.map(\.model) == ["m"])
    }

    /// Written with a clock ahead of ours: it counts once ours gets there, without any row changing then.
    @Test func anEventAheadOfTheClockJoinsWhenTheClockReachesIt() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("now", tokens: 15), event("soon", ago: -30, tokens: 25)])

        let before = try await dashboard(engine, after: 29)
        #expect(before.today.tokens.input == 15)
        #expect(before.sources.first?.lastActivity == now)
        #expect(before.series[59].input == 15)
        #expect(before.perMinute == 3)

        let reached = try await dashboard(engine, after: 30)
        #expect(reached.today.tokens.input == 40)
        #expect(reached.sources.first?.lastActivity == now.addingTimeInterval(30))
        #expect(reached.perMinute == 8)
        #expect(reached.series[59].input == 40)
    }

    /// A clock set back must not leave figures from the future on show.
    @Test func aClockSetBackReadsTheFiguresAgain() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", tokens: 3)])
        #expect(try await dashboard(engine, after: 10).today.tokens.input == 3)
        let earlier = try await dashboard(engine, after: -10)
        #expect(earlier.today.tokens.input == 0)
        #expect(earlier.perMinute == 0)
        #expect(earlier.series[59] == .zero)
    }

    /// The sample leaves after the figures were read, so going back past that reading is not enough to notice it has to return.
    @Test func aClockSetBackBringsBackASpeedThatLeft() async throws {
        let (engine, store) = try engine()
        var older = event("older", ago: 86_390, model: "m-old", generationMs: 10_000)
        older.tokens = TokenCounts(output: 600)
        try store.upsert([older])

        #expect(try await dashboard(engine, after: 0).today.speeds.map(\.model) == ["m-old"])
        #expect(try await dashboard(engine, after: 20).today.speeds.isEmpty)
        #expect(try await dashboard(engine, after: 5).today.speeds.map(\.model) == ["m-old"])
    }

    /// What the table holds in `(time − seconds, time]`, summed straight from it: no query the Engine uses is involved.
    private func sqlSum(_ column: String, in store: EventStore, at time: Date, seconds: Double = 300, sources: [Source]? = nil) throws -> Int {
        let end = time.timeIntervalSince1970
        let only = sources.map { " AND source IN (" + $0.map { "'\($0.rawValue)'" }.joined(separator: ",") + ")" } ?? ""
        return try store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(\(column)), 0) FROM event WHERE time > ? AND time <= ?\(only)", arguments: [end - seconds, end]) ?? 0
        }
    }

    private func spending(
        _ name: String,
        ago: TimeInterval = 10,
        source: Source = .claudeCode,
        client: String? = nil,
        model: String? = "test-model",
        tokens: TokenCounts
    ) -> UsageEvent {
        var spent = event(name, ago: ago, source: source, client: client, model: model)
        spent.tokens = tokens
        return spent
    }

    @Test func outputPerMinuteIsTheOutputOfTheWindow() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            spending("inside", ago: 299, tokens: TokenCounts(input: 5_000, output: 200)),
            spending("thinking", ago: 1, tokens: TokenCounts(output: 1_500, reasoning: 1_000)),
            spending("just out", ago: 300, tokens: TokenCounts(output: 25_000)),
        ])

        let dashboard = try await engine.dashboard(now: now, calendar: utc)

        #expect(dashboard.outputPerMinute == 340)
        #expect(dashboard.outputPerMinute == (try sqlSum("output", in: store, at: now)) / 5)
        #expect(dashboard.perMinute == 1_340)
    }

    @Test func costPerMinuteIsThePriceOfTheWindow() async throws {
        let card = Price(input: 3, output: 15, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6)
        let (engine, store) = try engine(preferences: preferences {
            $0.priceOverrides = ["test-model": PriceEntry(id: "test-model", provider: "anthropic", price: card, longContext: nil)]
        })
        try store.upsert([
            spending("a", tokens: TokenCounts(input: 5_000_000, output: 500_000)),
            spending("b", tokens: TokenCounts(cacheRead: 10_000_000, cacheWrite5m: 500_000, cacheWrite1h: 500_000)),
            spending("just out", ago: 300, tokens: TokenCounts(output: 1_000_000)),
        ])

        let cost = try await engine.dashboard(now: now, calendar: utc).costPerMinute

        // 15 + 7.5 for the first, 3 + 1.875 + 3 for the second: 30.375 over five minutes.
        #expect(abs(cost.usd - 6.075) < 1e-9)
        #expect(cost.unpricedModels.isEmpty)
        #expect(cost.unpricedTokens == 0)
    }

    /// The price is the effective table's, so an override moves the figure with no row and no time passing.
    @Test func anOverrideRepricesTheRateAtOnce() async throws {
        let original = try preferences()
        let (engine, store) = try engine(preferences: original)
        try store.upsert([spending("a", tokens: TokenCounts(input: 10_000_000))])
        #expect(abs(try await engine.dashboard(now: now, calendar: utc).costPerMinute.usd - 2) < 1e-9)

        var changed = original
        changed.priceOverrides["test-model"] = PriceEntry(id: "test-model", provider: "anthropic", price: flat(10), longContext: nil)
        await engine.apply(changed)

        #expect(abs(try await engine.dashboard(now: now, calendar: utc).costPerMinute.usd - 20) < 1e-9)
    }

    /// A new threshold moves a request into another band, which the window's kept groups were worked out against.
    @Test func aNewThresholdRepricesTheRate() async throws {
        let original = try preferences()
        let (engine, store) = try engine(preferences: original)
        try store.upsert([spending("a", tokens: TokenCounts(input: 60_000))])
        #expect(abs(try await engine.dashboard(now: now, calendar: utc).costPerMinute.usd - 0.012) < 1e-9)

        var changed = original
        changed.priceOverrides["test-model"] = entry("test-model", longContext: LongContextPrice(abovePromptTokens: 50_000, price: flat(10)))
        await engine.apply(changed)

        #expect(abs(try await engine.dashboard(now: now, calendar: utc).costPerMinute.usd - 0.12) < 1e-9)
    }

    @Test func anUnpricedModelIsLeftOutOfTheCostAndCounted() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            spending("priced", tokens: TokenCounts(input: 5_000_000)),
            spending("a1", model: "mystery-a", tokens: TokenCounts(input: 15)),
            spending("a2", model: "mystery-a", tokens: TokenCounts(input: 15)),
            spending("b", model: "mystery-b", tokens: TokenCounts(output: 25)),
            spending("nameless", model: nil, tokens: TokenCounts(output: 35)),
            spending("gone", ago: 300, model: "mystery-c", tokens: TokenCounts(input: 45)),
        ])

        let dashboard = try await engine.dashboard(now: now, calendar: utc)

        #expect(abs(dashboard.costPerMinute.usd - 1) < 1e-9)
        #expect(dashboard.costPerMinute.unpricedModels == ["mystery-a", "mystery-b"])
        #expect(dashboard.unpricedModelsInRate == 2)
        // A request that names no model has no price either, but it is no model to count.
        #expect(dashboard.costPerMinute.unpricedTokens == 18)
        // The token rates have no price to lose: they keep every token.
        #expect(dashboard.perMinute == 1_000_018)
        #expect(dashboard.outputPerMinute == 12)
    }

    @Test func aDisabledSourceIsInNoRateFigure() async throws {
        let (engine, store) = try engine(preferences: preferences { $0.enabledSources = [.claudeCode] })
        try store.upsert([
            spending("on", tokens: TokenCounts(input: 5_000_000, output: 500)),
            spending("off", source: .pi, tokens: TokenCounts(input: 25_000_000, output: 4_500)),
            spending("off, no price", source: .pi, model: "mystery", tokens: TokenCounts(input: 11)),
        ])

        let dashboard = try await engine.dashboard(now: now, calendar: utc)

        #expect(dashboard.outputPerMinute == 100)
        #expect(dashboard.outputPerMinute == (try sqlSum("output", in: store, at: now, sources: [.claudeCode])) / 5)
        #expect(abs(dashboard.costPerMinute.usd - 1.0001) < 1e-9)
        #expect(dashboard.costPerMinute.unpricedModels.isEmpty)
        #expect(dashboard.costPerMinute.unpricedTokens == 0)
        #expect(dashboard.unpricedModelsInRate == 0)
    }

    /// No row changes and the clock stands still, so only `apply` can say so.
    @Test func switchingASourceOffTakesItOutOfEveryRateFigureAtOnce() async throws {
        let all = try preferences()
        let (engine, store) = try engine(preferences: all)
        try store.upsert([
            spending("on", tokens: TokenCounts(output: 5_000_000)),
            spending("off", source: .pi, model: "mystery", tokens: TokenCounts(output: 4_500)),
        ])
        let before = try await engine.dashboard(now: now, calendar: utc)
        #expect(before.outputPerMinute == 1_000_900)
        #expect(before.unpricedModelsInRate == 1)

        var fewer = all
        fewer.enabledSources = [.claudeCode]
        await engine.apply(fewer)

        let after = try await engine.dashboard(now: now, calendar: utc)
        #expect(after.outputPerMinute == 1_000_000)
        #expect(abs(after.costPerMinute.usd - 1) < 1e-9)
        #expect(after.unpricedModelsInRate == 0)
    }

    /// Not one new row: the figures must still be right on the tick an event leaves.
    @Test func everyRateFigureFallsTheSecondAnEventLeavesTheWindow() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            spending("old", ago: 290, model: "mystery", tokens: TokenCounts(output: 35)),
            spending("new", ago: 260, tokens: TokenCounts(output: 10_000_000)),
        ])

        let before = try await dashboard(engine, after: 9)
        #expect(before.outputPerMinute == 2_000_007)
        #expect(before.unpricedModelsInRate == 1)

        let after = try await dashboard(engine, after: 10)
        #expect(after.outputPerMinute == 2_000_000)
        #expect(after.unpricedModelsInRate == 0)
        #expect(abs(after.costPerMinute.usd - 2) < 1e-9)

        let empty = try await dashboard(engine, after: 40)
        #expect(empty.outputPerMinute == 0)
        #expect(empty.costPerMinute.usd == 0)
    }

    @Test func aNewRowShowsInEveryRateFigureOnTheNextTick() async throws {
        let (engine, store) = try engine()
        try store.upsert([spending("first", tokens: TokenCounts(output: 5_000_000))])
        #expect(try await dashboard(engine, after: 0).outputPerMinute == 1_000_000)

        try store.upsert([spending("second", ago: 5, tokens: TokenCounts(output: 10_000_000))])

        let next = try await dashboard(engine, after: 1)
        #expect(next.outputPerMinute == 3_000_000)
        #expect(abs(next.costPerMinute.usd - 3) < 1e-9)
    }

    @Test func everyRateIsPerMinuteOverTheFiveMinutes() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            spending("early", ago: 280, client: "cli", tokens: TokenCounts(input: 1_000_000, output: 2_000)),
            spending("late", ago: 5, client: "cli", tokens: TokenCounts(output: 3_000)),
            spending("just out", ago: 300, client: "cli", tokens: TokenCounts(output: 9_000_000)),
        ])

        let dashboard = try await engine.dashboard(now: now, calendar: utc)

        #expect(dashboard.perMinute == (try sqlSum("input + output", in: store, at: now)) / 5)
        #expect(dashboard.perMinute == 201_000)
        #expect(dashboard.perSecond == 3_350)
        #expect(dashboard.lastMinute == TokenCounts(input: 200_000, output: 1_000))
        #expect(dashboard.outputPerMinute == 1_000)
        #expect(abs(dashboard.costPerMinute.usd - 0.201) < 1e-9)
        let row = try #require(dashboard.sources.first)
        #expect(row.perMinute == 201_000)
        #expect(row.clients.first?.perMinute == 201_000)
    }

    /// Two tokens in five minutes round to nothing a minute, and something is still running.
    @Test func aFewTokensAreNotIdle() async throws {
        let (engine, store) = try engine()
        try store.upsert([spending("little", model: "mystery", tokens: TokenCounts(input: 2))])

        let dashboard = try await engine.dashboard(now: now, calendar: utc)

        #expect(dashboard.perMinute == 0)
        #expect(!dashboard.isIdle)
        #expect(dashboard.unpricedModelsInRate == 1)
    }

    /// Two tokens over five minutes round to nothing a minute. The cost still leaves them out, and "no price" rests on its saying so.
    @Test(arguments: ["mystery", nil] as [String?])
    func aFewUnpricedTokensAreStillUnpriced(model: String?) async throws {
        let (engine, store) = try engine()
        try store.upsert([spending("little", model: model, tokens: TokenCounts(input: 2))])

        let cost = try await engine.dashboard(now: now, calendar: utc).costPerMinute

        #expect(cost.usd == 0)
        #expect(cost.unpricedTokens == 1)
    }

    @Test func aFewUnpricedTokensBesideAPricedModelAreStillUnpriced() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            spending("priced", tokens: TokenCounts(input: 5_000_000)),
            spending("little", model: "mystery", tokens: TokenCounts(input: 2)),
        ])

        let cost = try await engine.dashboard(now: now, calendar: utc).costPerMinute

        #expect(abs(cost.usd - 1) < 1e-9)
        #expect(cost.unpricedTokens == 1)
        #expect(cost.unpricedModels == ["mystery"])
    }

    /// Nothing left out is nothing to report: the floor is for tokens there are.
    @Test func noUnpricedTokensStayNone() async throws {
        let (engine, store) = try engine()
        try store.upsert([spending("priced", tokens: TokenCounts(input: 5_000_000))])

        #expect(try await engine.dashboard(now: now, calendar: utc).costPerMinute.unpricedTokens == 0)
    }

    /// Idle is no events in the window, whatever they hold.
    @Test func anEventWithNoTokensIsNotIdle() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("empty", tokens: 0)])

        #expect(!(try await engine.dashboard(now: now, calendar: utc).isIdle))
    }

    /// Whole tokens a minute, to the nearest: 12 over five minutes is 2.4 and 13 is 2.6. `perSecond` keeps the fraction.
    @Test(arguments: [(12, 2), (13, 3)])
    func aRateIsRoundedToTheNearestToken(tokens: Int, perMinute: Int) async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", tokens: tokens)])

        let dashboard = try await engine.dashboard(now: now, calendar: utc)

        #expect(dashboard.perMinute == perMinute)
        #expect(abs(dashboard.perSecond - Double(tokens) / 300) < 1e-12)
    }

    @Test func anEventLeavesTheWindowAtFiveMinutes() async throws {
        let (engine, store) = try engine()
        try store.upsert([spending("a", ago: 100, tokens: TokenCounts(output: 500))])

        #expect(try await dashboard(engine, after: 199).outputPerMinute == 100)
        #expect(try await dashboard(engine, after: 200).outputPerMinute == 0)
        #expect(try await dashboard(engine, after: 200).isIdle)
    }

    /// A figure on the dashboard that moves with the clock would redraw the menu bar every second, whatever the user is doing.
    @Test func aQuietDashboardIsTheSameFromOneTickToTheNext() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", ago: 3_600, tokens: 1_000)])
        try store.record([snapshot(used: 20, resetsIn: 7_200)])

        let first = try await dashboard(engine, after: 0)
        let second = try await dashboard(engine, after: 1)

        #expect(!first.quotas.isEmpty)
        #expect(first == second)
    }

    @Test func costSeriesIsTheSeriesInDollars() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            spending("now", ago: 0, tokens: TokenCounts(input: 1_000_000, output: 2_000_000)),
            spending("older", ago: 120, tokens: TokenCounts(cacheRead: 3_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)),
        ])

        let dashboard = try await engine.dashboard(now: now, calendar: utc)

        try #require(dashboard.costSeries.count == 60)
        #expect(dashboard.costSeries[59] == CategoryCost(input: 1, output: 2))
        #expect(dashboard.costSeries[57] == CategoryCost(cacheRead: 3, cacheWrite: 2))
        #expect(dashboard.costSeries[58] == .zero)
    }

    @Test func costSeriesCountsEnabledSourcesOnly() async throws {
        let (engine, store) = try engine(preferences: preferences { $0.enabledSources = [.claudeCode] })
        try store.upsert([
            spending("on", ago: 0, tokens: TokenCounts(input: 1_000_000)),
            spending("off", ago: 0, source: .pi, tokens: TokenCounts(input: 5_000_000)),
        ])

        #expect(try await engine.dashboard(now: now, calendar: utc).costSeries[59].input == 1)
    }

    @Test func anUnpricedModelIsInNoLayerOfTheCostSeries() async throws {
        let (engine, store) = try engine()
        try store.upsert([spending("a", ago: 0, model: "mystery", tokens: TokenCounts(input: 1_000_000))])

        let dashboard = try await engine.dashboard(now: now, calendar: utc)

        #expect(dashboard.costSeries[59].total == 0)
        #expect(dashboard.costSeries[59].unpricedTokens > 0)
        #expect(dashboard.series[59].input == 1_000_000)
    }

    /// Not one new row: only the clock moves, and each dollar has to move with it.
    @Test func theCostSeriesMovesOnWithTheMinute() async throws {
        let (engine, store) = try engine()
        try store.upsert([spending("a", ago: 0, tokens: TokenCounts(input: 1_000_000))])
        #expect(try await dashboard(engine, after: 59).costSeries[59].input == 1)

        let next = try await dashboard(engine, after: 60)

        #expect(next.costSeries[59] == .zero)
        #expect(next.costSeries[58].input == 1)
    }

    @Test func aNewRowShowsInTheCostSeriesOnTheNextTick() async throws {
        let (engine, store) = try engine()
        try store.upsert([spending("first", ago: 0, tokens: TokenCounts(input: 1_000_000))])
        #expect(try await dashboard(engine, after: 0).costSeries[59].input == 1)

        try store.upsert([spending("second", ago: 0, tokens: TokenCounts(input: 2_000_000))])

        #expect(try await dashboard(engine, after: 1).costSeries[59].input == 3)
    }

    /// Prices change with no row and no time passing, so only `apply` can say so.
    @Test func anOverrideRepricesTheCostSeriesAtOnce() async throws {
        let original = try preferences()
        let (engine, store) = try engine(preferences: original)
        try store.upsert([spending("a", ago: 0, tokens: TokenCounts(input: 1_000_000))])
        #expect(try await engine.dashboard(now: now, calendar: utc).costSeries[59].input == 1)

        var changed = original
        changed.priceOverrides["test-model"] = PriceEntry(id: "test-model", provider: "anthropic", price: flat(10), longContext: nil)
        await engine.apply(changed)

        #expect(try await engine.dashboard(now: now, calendar: utc).costSeries[59].input == 10)
    }

    @Test func aHeldDashboardKeepsItsSeriesAndItsDollarsTogether() async throws {
        let (engine, store) = try engine()
        try store.upsert([spending("soon", ago: -30, tokens: TokenCounts(input: 1_000_000))])

        let before = try await dashboard(engine, after: 29)
        #expect(before.series[59] == .zero)
        #expect(before.costSeries[59] == .zero)

        let reached = try await dashboard(engine, after: 30)
        #expect(reached.series[59].input == 1_000_000)
        #expect(reached.costSeries[59].input == 1)
    }

    @Test func latestRequestIsTheNewestOfTheEnabledSources() async throws {
        let (engine, store) = try engine(preferences: preferences { $0.enabledSources = [.claudeCode, .codex] })
        try store.upsert([
            spending("older", ago: 500, tokens: TokenCounts(output: 1)),
            spending("newer", ago: 200, source: .codex, tokens: TokenCounts(output: 1)),
            spending("off", ago: 100, source: .pi, tokens: TokenCounts(output: 1)),
        ])

        #expect(try await engine.dashboard(now: now, calendar: utc).latestRequest == now.addingTimeInterval(-200))
    }

    @Test func thereIsNoLatestRequestWithNoUse() async throws {
        let (engine, _) = try engine()

        #expect(try await engine.dashboard(now: now, calendar: utc).latestRequest == nil)
    }

    // MARK: Insights

    /// `tokens` on the day `days` before `now`, at the same time of day less `ago`.
    private func past(
        _ days: Int,
        ago: TimeInterval = 0,
        source: Source = .claudeCode,
        model: String? = "test-model",
        tokens: TokenCounts = TokenCounts(output: 100)
    ) -> UsageEvent {
        spending("\(source.rawValue)-\(days)-\(ago)-\(model ?? "none")", ago: Double(days) * 86_400 + ago, source: source, model: model, tokens: tokens)
    }

    private func newYork() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        return calendar
    }

    @Test func aDayOfUseIsADayBeforeTodayWithAnEvent() async throws {
        let (engine, store) = try engine()
        try store.upsert([past(1), past(3), spending("today", ago: 5, tokens: TokenCounts(output: 1))])

        #expect(try await engine.insights(now: now, calendar: utc).daysOfUse == 2)
    }

    @Test func aDayOfADisabledSourceIsNoDayOfUse() async throws {
        let (engine, store) = try engine(preferences: preferences { $0.enabledSources = [.claudeCode] })
        try store.upsert([past(1), past(2, source: .pi)])

        #expect(try await engine.insights(now: now, calendar: utc).daysOfUse == 1)
    }

    @Test func onlyTheNewestFourteenDaysAreKept() async throws {
        let (engine, store) = try engine()
        try store.upsert((1...16).map { past($0, ago: 60, tokens: TokenCounts(output: $0 > 14 ? 1_000_000 : 100)) })

        let inputs = try await engine.insightInputs(now: now, calendar: utc)

        #expect(try await engine.insights(now: now, calendar: utc).daysOfUse == 14)
        #expect(inputs.usualDays.count == 14)
        #expect(inputs.usualDays.allSatisfy { $0.output == 100 })
    }

    @Test func theWalkGoesBackNinetyCalendarDays() async throws {
        let (engine, store) = try engine()
        try store.upsert([past(90), past(91)])

        #expect(try await engine.insights(now: now, calendar: utc).daysOfUse == 1)
    }

    /// At 10:00 a day has what it had by 10:00, not its whole total.
    @Test func aUsualDayStandsAsItDidAtThisTimeOfDay() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            past(1, ago: 3_600, tokens: TokenCounts(output: 100)),
            past(1, ago: -3_600, tokens: TokenCounts(output: 900)),
        ])

        #expect(try await engine.insightInputs(now: now, calendar: utc).usualDays.map(\.output) == [100])
    }

    /// Halfway through a quarter hour, halfway through what that quarter hour added.
    @Test func aUsualDayIsInterpolatedWithinItsQuarterHour() async throws {
        let (engine, store) = try engine()
        try store.upsert([past(1, ago: 3_600, tokens: TokenCounts(output: 100)), past(1, ago: -60, tokens: TokenCounts(output: 800))])

        let halfway = now.addingTimeInterval(450)

        #expect(try await engine.insightInputs(now: halfway, calendar: utc).usualDays.map(\.output) == [500])
    }

    @Test func theCostOfAUsualDayIsPricedTokensOnly() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            past(1, ago: 60, tokens: TokenCounts(input: 1_000_000)),
            past(1, ago: 120, model: "mystery", tokens: TokenCounts(input: 5_000_000, output: 40)),
        ])

        let day = try #require(try await engine.insightInputs(now: now, calendar: utc).usualDays.first)

        #expect(abs(day.cost - 1) < 1e-9)
        #expect(day.output == 40)
    }

    @Test func thereIsNoBandUnderSevenDaysOfUse() async throws {
        let (engine, store) = try engine()
        try store.upsert((1...6).map { past($0, ago: 60) })

        let insights = try await engine.insights(now: now, calendar: utc)

        #expect(insights.daysOfUse == 6)
        #expect(insights.cost.band.isEmpty)
        #expect(insights.output.band.isEmpty)
        #expect(insights.tokens.band.isEmpty)
        #expect(insights.output.usualNow == nil)
    }

    @Test func theBandAppearsAtSevenDaysOfUse() async throws {
        let (engine, store) = try engine()
        try store.upsert((1...7).map { past($0, ago: 60) })

        let curve = try await engine.insights(now: now, calendar: utc).output

        #expect(curve.band.count == 96)
        #expect(curve.band.first?.fraction == 1.0 / 96)
        #expect(curve.band.last?.fraction == 1)
        #expect(curve.usualNow == 100)
    }

    @Test func theBandIsTheQuartilesOfTheDaysAtEachQuarterHour() async throws {
        let (engine, store) = try engine()
        try store.upsert((1...7).map { past($0, ago: 60, tokens: TokenCounts(output: $0 * 100)) })

        let band = try #require(try await engine.insights(now: now, calendar: utc).output.band.last)

        #expect(band.low == 250)
        #expect(band.median == 400)
        #expect(band.high == 550)
        #expect(band.hour == 24)
    }

    @Test func todayIsALineFromMidnightToNow() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            spending("morning", ago: 7_200, tokens: TokenCounts(output: 30)),
            spending("just now", ago: 60, tokens: TokenCounts(output: 70)),
        ])
        let at = now.addingTimeInterval(450)

        let line = try await engine.insights(now: at, calendar: utc).output.today

        #expect(line.first == UsualCurve.Point(fraction: 0, value: 0))
        #expect(line.last?.value == 100)
        #expect(abs((line.last?.fraction ?? 0) - 36_450.0 / 86_400) < 1e-9)
        #expect(line.map(\.value) == line.map(\.value).sorted())
        #expect(line.first { abs($0.fraction - 33.0 / 96) < 1e-9 }?.value == 30)
    }

    /// Today so far against as much of the week before, cut at the time of day it is now: steady use must not read as a fall every
    /// morning, and the sentence sits beside the Week columns, so it speaks of the same days.
    @Test func theWeeksCountTodayAndCutTheOneBeforeAtThisTimeOfDay() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            spending("today", ago: 5, tokens: TokenCounts(output: 1)),
            past(6, tokens: TokenCounts(output: 2)),
            past(7, ago: 1, tokens: TokenCounts(output: 4)),
            past(7, tokens: TokenCounts(output: 8)),
            past(13, ago: 36_000, tokens: TokenCounts(output: 16)),
            past(13, ago: 36_001, tokens: TokenCounts(output: 32)),
        ])

        let inputs = try await engine.insightInputs(now: now, calendar: utc)

        #expect(inputs.outputLastSevenDays == 3)
        #expect(inputs.outputSevenDaysBefore == 20)
    }

    @Test func todayReachesTheInputsFromTheDashboard() async throws {
        let (engine, store) = try engine(preferences: preferences { $0.anthropicQueryEnabled = false })
        try store.upsert([spending("a", tokens: TokenCounts(input: 1_000_000, output: 5))])
        try store.record([snapshot()])

        let inputs = try await engine.insightInputs(now: now, calendar: utc)

        #expect(inputs.todayTokens == TokenCounts(input: 1_000_000, output: 5))
        #expect(abs(inputs.todayCost.usd - 1.000005) < 1e-9)
        #expect(inputs.limits.count == 1)
        #expect(!inputs.anthropicQueryEnabled)
    }

    @Test func todaysCacheFiguresAreEnabledSourcesOnly() async throws {
        let card = Price(input: 3, output: 15, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6)
        let (engine, store) = try engine(preferences: preferences {
            $0.enabledSources = [.claudeCode]
            $0.priceOverrides = ["test-model": PriceEntry(id: "test-model", provider: "anthropic", price: card, longContext: nil)]
        })
        try store.upsert([
            spending("on", tokens: TokenCounts(input: 1_000_000, cacheRead: 3_000_000)),
            spending("off", source: .pi, tokens: TokenCounts(cacheRead: 9_000_000)),
        ])

        let cache = try await engine.insights(now: now, calendar: utc).cache

        #expect(cache.hitRate == 0.75)
        #expect(abs(cache.saving.usd - 8.1) < 1e-9)
    }

    @Test func theDailyHitRateIsTheLastSevenDaysWithUse() async throws {
        let (engine, store) = try engine()
        try store.upsert((1...8).map { past($0 * 2, tokens: TokenCounts(input: 100 - $0, cacheRead: $0)) } + [
            spending("today", tokens: TokenCounts(input: 50, cacheRead: 50)),
        ])

        let rates = try await engine.insights(now: now, calendar: utc).cache.dailyHitRates

        #expect(rates == [0.06, 0.05, 0.04, 0.03, 0.02, 0.01, 0.5].map { $0 })
    }

    @Test func thereIsNoHitRateWithNoPromptToday() async throws {
        let (engine, _) = try engine()

        #expect(try await engine.insights(now: now, calendar: utc).cache.hitRate == nil)
    }

    /// Two models at different prices, so that cost and tokens give opposite answers and neither can pass for the other.
    private func dearAndCheap() throws -> Preferences {
        try preferences {
            $0.priceOverrides["dear-model"] = PriceEntry(id: "dear-model", provider: "anthropic", price: flat(9), longContext: nil)
        }
    }

    /// 3M cheap tokens are $3 and 1M dear ones $9: by tokens Claude Code is ahead 3 to 1, and by cost Codex is.
    @Test func aCLIsShareIsOfTheCostWhenAllOfItHasAPrice() async throws {
        let (engine, store) = try engine(preferences: dearAndCheap())
        try store.upsert([
            spending("a", tokens: TokenCounts(input: 3_000_000)),
            spending("b", source: .codex, model: "dear-model", tokens: TokenCounts(input: 1_000_000)),
        ])

        let insights = try await engine.insights(now: now, calendar: utc)

        #expect(insights.results.clis?.basis == .cost)
        #expect(insights.clis.shares == [CLIFigures.Share(source: .codex, fraction: 0.75), CLIFigures.Share(source: .claudeCode, fraction: 0.25)])
    }

    /// With tokens left out of the cost, a share of it would be a share of the part that has a price. The sentence goes by tokens
    /// then, so the bar has to.
    @Test func aCLIsShareIsOfTheTokensWhenSomeHaveNoPrice() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            spending("a", tokens: TokenCounts(input: 1_000)),
            spending("b", source: .codex, model: "mystery", tokens: TokenCounts(input: 3_000)),
        ])

        let insights = try await engine.insights(now: now, calendar: utc)

        #expect(insights.results.clis?.basis == .tokens)
        #expect(insights.clis.shares == [CLIFigures.Share(source: .codex, fraction: 0.75), CLIFigures.Share(source: .claudeCode, fraction: 0.25)])
    }

    @Test func theSpeedIsOfTheModelWithTheMostSamples() async throws {
        let (engine, store) = try engine()
        func timed(_ name: String, ago: TimeInterval, model: String, output: Int) -> UsageEvent {
            var event = event(name, ago: ago, model: model, generationMs: 1_000)
            event.tokens = TokenCounts(output: output)
            return event
        }
        var events = (0..<3).map { timed("few\($0)", ago: 60, model: "few", output: 900) }
        events += (0..<5).map { timed("many\($0)", ago: 120, model: "many", output: 100) }
        events += (0..<5).map { timed("day1-\($0)", ago: 86_400 * 2, model: "many", output: 200) }
        events += (0..<4).map { timed("thin-\($0)", ago: 86_400 * 3, model: "many", output: 300) }
        events += (0..<5).map { timed("day4-\($0)", ago: 86_400 * 4, model: "many", output: 400) }
        try store.upsert(events)

        let speed = try #require(try await engine.insightInputs(now: now, calendar: utc).speed)

        #expect(speed.model == "many")
        #expect(speed.today == 100)
        #expect(speed.dailyMedians == [400, 200])
    }

    @Test func theSpeedLeavesOutDisabledSources() async throws {
        let (engine, store) = try engine(preferences: preferences { $0.enabledSources = [.claudeCode] })
        var off = event("off", ago: 60, source: .pi, model: "other", generationMs: 1_000)
        off.tokens = TokenCounts(output: 500)
        try store.upsert([off])

        #expect(try await engine.insightInputs(now: now, calendar: utc).speed == nil)
    }

    /// A request of `model` at `output` tokens a second, `ago` seconds before `now`.
    private func timedRequest(_ name: String, ago: TimeInterval, model: String, output: Int, source: Source = .claudeCode) -> UsageEvent {
        var event = event(name, ago: ago, source: source, model: model, generationMs: 1_000)
        event.tokens = TokenCounts(output: output)
        return event
    }

    /// The Speed page gives rule P for the model it shows, which need not be the card's: its last 24 hours against its own usual range.
    @Test func theSpeedPageHasRulePForTheModelItShows() async throws {
        let (engine, store) = try await liveEngine()
        var events = (0..<5).map { timedRequest("many\($0)", ago: 120, model: "many", output: 100) }
        events += (0..<3).map { timedRequest("few\($0)", ago: 60, model: "few", output: 900) }
        for day in 1...7 {
            events += (0..<5).map { timedRequest("few-\(day)-\($0)", ago: 86_400 * Double(day), model: "few", output: 90 + 10 * day) }
        }
        try store.upsert(events)

        let chosen = try await engine.speedInsight(model: "few", now: now, calendar: utc)
        let card = try await engine.speedInsight(model: nil, now: now, calendar: utc)

        #expect(chosen == SpeedInsight(rule: .p9, model: "few", value: 900, range: UsualRange(p25: 115, median: 130, p75: 145)))
        #expect(card == SpeedInsight(rule: .p4(daysLeft: 6), model: "many", value: 100, range: nil))
        #expect(card == (try await engine.insights(now: now, calendar: utc)).results.speed)
    }

    /// Rule P speaks of the last 24 hours, so a model last used before them, or only on a source turned off, has none.
    @Test func aModelWithNoRequestInTheLastDayHasNoRuleP() async throws {
        let (engine, store) = try engine(preferences: preferences { $0.enabledSources = [.claudeCode] })
        try store.upsert([
            timedRequest("many", ago: 60, model: "many", output: 100),
            timedRequest("old", ago: 86_400 * 3, model: "old", output: 100),
            timedRequest("off", ago: 60, model: "off", output: 100, source: .pi),
        ])

        #expect(try await engine.speedInsight(model: "old", now: now, calendar: utc) == nil)
        #expect(try await engine.speedInsight(model: "off", now: now, calendar: utc) == nil)
    }

    /// The When card is the exception: like the Calendar it leads to, it keeps every source.
    @Test func theHourGridIsTheLastThirtyDaysOfEverySource() async throws {
        let (engine, store) = try engine(preferences: preferences { $0.enabledSources = [.claudeCode] })
        try store.upsert([
            past(1, tokens: TokenCounts(input: 5)),
            past(30, source: .pi, tokens: TokenCounts(input: 7)),
            past(31, tokens: TokenCounts(input: 1_000)),
        ])

        let grid = try await engine.insights(now: now, calendar: utc).hourOfWeek

        #expect(grid.count == 7)
        #expect(grid.flatMap { $0 }.reduce(0, +) == 12)
    }

    @Test func theResultsComeFromTheInputs() async throws {
        let (engine, store) = try engine()
        try store.upsert([past(1), past(2), spending("today", tokens: TokenCounts(output: 1))])
        await engine.start()
        #expect(try await eventually { (try? await engine.dashboard(now: now, calendar: utc).progress.phase) == .live })

        let insights = try await engine.insights(now: now, calendar: utc)

        #expect(insights.results == Insights.compute(try await engine.insightInputs(now: now, calendar: utc)))
        #expect(insights.results.today.rule == .h2(soFar: 3))
    }

    // MARK: How often they are read

    @Test func insightsStandForAMinute() async throws {
        let (engine, store) = try engine()
        try store.upsert([spending("first", ago: 5, tokens: TokenCounts(output: 1))])
        let first = try await engine.insights(now: now, calendar: utc)
        try store.upsert([spending("second", ago: 3, tokens: TokenCounts(output: 2))])

        #expect(try await engine.insights(now: now.addingTimeInterval(59), calendar: utc) == first)
        #expect(try await engine.insights(now: now.addingTimeInterval(60), calendar: utc).output.today.last?.value == 3)
    }

    @Test func aClockSetBackReadsTheInsightsAgain() async throws {
        let (engine, store) = try engine()
        try store.upsert([spending("a", ago: 0, tokens: TokenCounts(output: 1))])
        #expect(try await engine.insights(now: now, calendar: utc).output.today.last?.value == 1)

        #expect(try await engine.insights(now: now.addingTimeInterval(-10), calendar: utc).output.today.last?.value == 0)
    }

    @Test func aNewDayReadsTheInsightsAgain() async throws {
        let (engine, store) = try engine()
        let lateEvening = date("2026-11-03T23:59:50Z")
        var yesterday = spending("a", tokens: TokenCounts(output: 1))
        yesterday.time = date("2026-11-03T23:00:00Z")
        try store.upsert([yesterday])
        #expect(try await engine.insights(now: lateEvening, calendar: utc).daysOfUse == 0)

        #expect(try await engine.insights(now: date("2026-11-04T00:00:10Z"), calendar: utc).daysOfUse == 1)
    }

    /// An engine with the logs read, so the phase is `.live`, and past days read once.
    private func liveEngine() async throws -> (engine: Engine, store: EventStore) {
        let (engine, store) = try engine()
        await engine.start()
        let utc = utc
        let now = now
        #expect(try await eventually { (try? await engine.dashboard(now: now, calendar: utc).progress.phase) == .live })
        return (engine, store)
    }

    /// A rescan finds a root that appeared with its old logs: no change of preferences, and the phase stays `.live`.
    @Test func aRescanThatBringsPastDaysReadsThemAgain() async throws {
        let (engine, store) = try await liveEngine()
        try store.upsert([past(1)])
        #expect(try await engine.insights(now: now, calendar: utc).daysOfUse == 1)

        try store.upsert([past(2), past(3)])

        #expect(try await engine.insights(now: now.addingTimeInterval(60), calendar: utc).daysOfUse == 3)
    }

    /// The same rows, more tokens: the count alone would not show it.
    @Test func aRewrittenPastRowReadsPastDaysAgain() async throws {
        let (engine, store) = try await liveEngine()
        try store.upsert([past(1, ago: 60, tokens: TokenCounts(output: 100))])
        #expect(try await engine.insightInputs(now: now, calendar: utc).usualDays.map(\.output) == [100])

        try store.upsert([past(1, ago: 60, tokens: TokenCounts(output: 500))])

        #expect(try await engine.insightInputs(now: now, calendar: utc).usualDays.map(\.output) == [500])
    }

    /// The same tokens at another time of day: the sums alone would not show it.
    @Test func aPastRowThatMovesReadsPastDaysAgain() async throws {
        let (engine, store) = try await liveEngine()
        var moving = past(1, ago: 60, tokens: TokenCounts(output: 100))
        try store.upsert([moving])
        #expect(try await engine.insightInputs(now: now, calendar: utc).usualDays.map(\.output) == [100])

        moving.time = moving.time.addingTimeInterval(3_600)
        try store.upsert([moving])

        #expect(try await engine.insightInputs(now: now, calendar: utc).usualDays.map(\.output) == [0])
    }

    /// Writes to today are what a busy machine does all day: they say nothing of past days, so they must not cost a walk.
    @Test func aRowForTodayWalksNoPastDays() async throws {
        let (engine, store) = try await liveEngine()
        try store.upsert([past(1)])
        _ = try await engine.insights(now: now, calendar: utc)
        let walks = await engine.pastDayWalks

        try store.upsert([spending("today", ago: 5, tokens: TokenCounts(output: 1))])
        let insights = try await engine.insights(now: now.addingTimeInterval(60), calendar: utc)

        #expect(await engine.pastDayWalks == walks)
        #expect(insights.output.today.last?.value == 1)
    }

    @Test func aStoreThatDidNotChangeWalksNoPastDays() async throws {
        let (engine, store) = try await liveEngine()
        try store.upsert([past(1)])
        _ = try await engine.insights(now: now, calendar: utc)
        let walks = await engine.pastDayWalks

        _ = try await engine.insights(now: now.addingTimeInterval(60), calendar: utc)

        #expect(await engine.pastDayWalks == walks)
    }

    @Test func aChangeToPastDaysCostsOneWalk() async throws {
        let (engine, store) = try await liveEngine()
        try store.upsert([past(1)])
        _ = try await engine.insights(now: now, calendar: utc)
        let walks = await engine.pastDayWalks

        try store.upsert([past(2)])
        _ = try await engine.insights(now: now.addingTimeInterval(60), calendar: utc)
        // A write to today moves the generation, so the next read looks again, and has to find past days as they were last read.
        try store.upsert([spending("today", ago: 5, tokens: TokenCounts(output: 1))])
        _ = try await engine.insights(now: now.addingTimeInterval(120), calendar: utc)

        #expect(await engine.pastDayWalks == walks + 1)
    }

    /// Day by day these add up, and over the walk they do not. A fingerprint says whether to read: it must not be what stops a read.
    @Test func aFingerprintThatCannotBeHadStopsNoRead() async throws {
        let (engine, store) = try await liveEngine()
        try store.upsert([past(1, tokens: TokenCounts(input: 1 << 62)), past(2, tokens: TokenCounts(input: 1 << 62))])

        #expect(try await engine.insights(now: now, calendar: utc).daysOfUse == 2)

        try store.upsert([spending("today", ago: 5, tokens: TokenCounts(output: 1))])
        #expect(try await engine.insights(now: now.addingTimeInterval(60), calendar: utc).daysOfUse == 2)
    }

    /// What cannot be told is not a change: reading again every minute would be the cost of a store that holds a damaged row.
    @Test func aFingerprintThatCannotBeHadCostsNoWalk() async throws {
        let (engine, store) = try await liveEngine()
        try store.upsert([past(1, tokens: TokenCounts(input: 1 << 62)), past(2, tokens: TokenCounts(input: 1 << 62))])
        _ = try await engine.insights(now: now, calendar: utc)
        let walks = await engine.pastDayWalks

        try store.upsert([spending("today", ago: 5, tokens: TokenCounts(output: 1))])
        _ = try await engine.insights(now: now.addingTimeInterval(60), calendar: utc)

        #expect(await engine.pastDayWalks == walks)
    }

    /// A fingerprint that was there and no longer can be had means rows changed. Past days are read once, and then it is quiet again.
    @Test func losingTheFingerprintIsAChangeOnce() async throws {
        let (engine, store) = try await liveEngine()
        try store.upsert([past(1)])
        #expect(try await engine.insights(now: now, calendar: utc).daysOfUse == 1)
        let walks = await engine.pastDayWalks

        try store.upsert([past(2, tokens: TokenCounts(input: 1 << 62)), past(3, tokens: TokenCounts(input: 1 << 62))])
        #expect(try await engine.insights(now: now.addingTimeInterval(60), calendar: utc).daysOfUse == 3)
        #expect(await engine.pastDayWalks == walks + 1)

        try store.upsert([spending("today", ago: 5, tokens: TokenCounts(output: 1))])
        _ = try await engine.insights(now: now.addingTimeInterval(120), calendar: utc)
        #expect(await engine.pastDayWalks == walks + 1)
    }

    /// While the logs are read rows pour in by the thousand, and nothing may yet say that days are missing. The walk waits for the end.
    @Test func noWalkFollowsRowsWhileTheLogsAreRead() async throws {
        let (engine, store) = try engine()
        try store.upsert([past(1)])
        _ = try await engine.insights(now: now, calendar: utc)
        let walks = await engine.pastDayWalks

        try store.upsert([past(2)])
        _ = try await engine.insights(now: now.addingTimeInterval(60), calendar: utc)

        #expect(await engine.pastDayWalks == walks)
    }

    /// Until the logs are read, past days wait for the next local day, or for the logs to finish.
    @Test func whileTheLogsAreReadPastDaysAreReadOnceADay() async throws {
        let (engine, store) = try engine()
        try store.upsert([past(1)])
        #expect(try await engine.insights(now: now, calendar: utc).daysOfUse == 1)

        try store.upsert([past(2)])

        #expect(try await engine.insights(now: now.addingTimeInterval(120), calendar: utc).daysOfUse == 1)
        #expect(try await engine.insights(now: now.addingTimeInterval(86_400), calendar: utc).daysOfUse == 2)
    }

    @Test func aChangeOfPreferencesReadsPastDaysAgain() async throws {
        let all = try preferences()
        let (engine, store) = try engine(preferences: all)
        try store.upsert([past(1), past(2, source: .pi)])
        #expect(try await engine.insights(now: now, calendar: utc).daysOfUse == 2)

        var fewer = all
        fewer.enabledSources = [.claudeCode]
        await engine.apply(fewer)

        #expect(try await engine.insights(now: now, calendar: utc).daysOfUse == 1)
    }

    /// A new install has months of logs still to read: waiting for midnight would say "needs 7 days" all day.
    @Test func theLogsFinishingReadsPastDaysAgain() async throws {
        let (engine, store) = try engine()
        #expect(try await engine.insights(now: now, calendar: utc).daysOfUse == 0)
        try store.upsert([past(1)])

        await engine.start()
        #expect(try await eventually { (try? await engine.dashboard(now: now, calendar: utc).progress.phase) == .live })

        #expect(try await engine.insights(now: now, calendar: utc).daysOfUse == 1)
    }

    /// 02:00 in UTC is today; in New York it is still yesterday evening, so a change of time zone moves it into the past.
    @Test func anotherTimeZoneReadsPastDaysAgain() async throws {
        let (engine, store) = try engine()
        var evening = spending("a", tokens: TokenCounts(output: 1))
        evening.time = date("2026-11-03T02:00:00Z")
        try store.upsert([evening])
        #expect(try await engine.insights(now: now, calendar: utc).daysOfUse == 0)

        #expect(try await engine.insights(now: now, calendar: try newYork()).daysOfUse == 1)
    }

    /// A rebuild runs from Settings with the panel shut, so nothing need read the insights while the phase is away from `.live`.
    @Test func aRebuildReadsPastDaysAgain() async throws {
        let (engine, store) = try engine()
        try store.upsert([past(1), past(2)])
        await engine.start()
        #expect(try await eventually { (try? await engine.dashboard(now: now, calendar: utc).progress.phase) == .live })
        #expect(try await engine.insights(now: now, calendar: utc).daysOfUse == 2)

        try await engine.rebuildIndex()

        #expect(try await engine.insights(now: now, calendar: utc).daysOfUse == 0)
    }

    /// Turning a source on brings its old logs in through a rescan, with the phase at `.live` throughout. Read during that rescan,
    /// past days would say "needs 7 days" until midnight with all of them in the store.
    @Test func aRescanAfterAChangeReadsPastDaysAgain() async throws {
        let home = try makeTempDir()
        var events: [URL: UsageEvent] = [:]
        for day in 1...3 {
            let file = home.appendingPathComponent("\(day).jsonl")
            try write(["x"], to: file)
            events[file] = past(day)
        }
        var off = Preferences.defaults(home: home)
        off.roots = SourceRoots(roots: [.claudeCode: [home.path]])
        off.enabledSources = []
        var on = off
        on.enabledSources = [.claudeCode]
        let reader = DatedReader(events: events)
        let engine = try Engine(
            store: .inMemory(),
            home: home,
            preferences: off,
            readers: [reader],
            token: { nil },
            send: { _ in throw CancellationError() }
        )

        await engine.apply(on)
        _ = try await engine.insights(now: now, calendar: utc)

        #expect(try await eventually { reader.finished >= events.count })
        #expect(try await eventually { (try? await engine.insights(now: now, calendar: utc).daysOfUse) == events.count })
    }

    /// The bar and the sentence beside it say the same share, whichever basis today allows.
    @Test(arguments: ["dear-model", "mystery"])
    func theBarAndTheSentenceAgree(model: String) async throws {
        let (engine, store) = try engine(preferences: dearAndCheap())
        try store.upsert([
            spending("a", tokens: TokenCounts(input: 1_000_000)),
            spending("b", source: .codex, model: model, tokens: TokenCounts(input: 3_000_000)),
        ])

        let insights = try await engine.insights(now: now, calendar: utc)

        let top = try #require(insights.clis.shares.first)
        let sentence = try #require(insights.results.clis)
        #expect(top.source == sentence.source)
        #expect(Int((top.fraction * 100).rounded()) == sentence.percent)
    }

    /// The same day in the same zone, but rows of the hour grid start from the calendar's first weekday.
    @Test func anotherFirstWeekdayReadsPastDaysAgain() async throws {
        let (engine, store) = try engine()
        try store.upsert([past(1)])
        var mondayFirst = utc
        mondayFirst.firstWeekday = 2
        var sundayFirst = utc
        sundayFirst.firstWeekday = 1

        let sunday = try await engine.insights(now: now, calendar: sundayFirst).hourOfWeek
        let monday = try await engine.insights(now: now, calendar: mondayFirst).hourOfWeek

        #expect(sunday != monday)
    }

    // MARK: Clock changes

    /// New York, 8 March 2026: 02:00 to 03:00 never happens. The curve of that day still has 96 steps, flat across the gap.
    @Test func aDayWithAHourSkippedKeepsItsCurve() async throws {
        let calendar = try newYork()
        let (engine, store) = try engine()
        var early = spending("early", tokens: TokenCounts(output: 10))
        early.time = date("2026-03-08T06:30:00Z") // 01:30 EST
        var late = spending("late", tokens: TokenCounts(output: 20))
        late.time = date("2026-03-08T07:30:00Z") // 03:30 EDT
        try store.upsert([early, late])

        let curves = try await engine.dayCurves(now: date("2026-03-09T16:00:00Z"), calendar: calendar)

        let day = try #require(curves.first)
        #expect(day.output.count == 96)
        #expect(day.output[7] == 10)
        #expect(day.output[8...13].allSatisfy { $0 == 10 })
        #expect(day.output[14] == 30)
        #expect(day.output[95] == 30)
    }

    /// New York, 1 November 2026: 01:00 to 02:00 happens twice, and both add up in its slots.
    @Test func aDayWithAHourRepeatedKeepsItsCurve() async throws {
        let calendar = try newYork()
        let (engine, store) = try engine()
        var first = spending("first", tokens: TokenCounts(output: 10))
        first.time = date("2026-11-01T05:30:00Z") // 01:30 EDT
        var second = spending("second", tokens: TokenCounts(output: 20))
        second.time = date("2026-11-01T06:30:00Z") // 01:30 EST
        try store.upsert([first, second])

        let curves = try await engine.dayCurves(now: date("2026-11-02T16:00:00Z"), calendar: calendar)

        let day = try #require(curves.first)
        #expect(day.output[5] == 0)
        #expect(day.output[6] == 30)
    }

    /// New York, 1 November 2026: at 01:05 EST the clock has gone back past 01:30 EDT, and what was used then is still today's.
    @Test func todaysLineHoldsAllOfTodayInARepeatedHour() async throws {
        let (engine, store) = try engine()
        var first = spending("first", tokens: TokenCounts(output: 1_000))
        first.time = date("2026-11-01T05:30:00Z")
        try store.upsert([first])

        let insights = try await engine.insights(now: date("2026-11-01T06:05:00Z"), calendar: try newYork())

        #expect(insights.output.today.last?.value == 1_000)
    }

    /// A position in the day goes by the clock, or a day of 23 hours would not line up with the others at the same time of day.
    @Test func aPositionInTheDayGoesByTheClock() throws {
        let calendar = try newYork()

        #expect(DayCurve.fraction(of: date("2026-03-08T16:00:00Z"), calendar: calendar) == 0.5) // noon EDT, 11 hours after midnight
        #expect(DayCurve.fraction(of: date("2026-11-01T17:00:00Z"), calendar: calendar) == 0.5) // noon EST, 13 hours after midnight
        #expect(DayCurve.fraction(of: date("2026-06-15T04:00:00Z"), calendar: calendar) == 0)
    }

    @Test func dayCurvesAreOldestFirstAndAtMostFourteen() async throws {
        let (engine, store) = try engine()
        try store.upsert((1...16).map { past($0) })

        let days = try await engine.dayCurves(now: now, calendar: utc).map(\.day)

        #expect(days.count == 14)
        #expect(days == days.sorted())
        #expect(days.last == utc.date(byAdding: .day, value: -1, to: utc.startOfDay(for: now)))
    }

    @Test func theValueOfACurveIsInterpolated() {
        var values = [Double](repeating: 0, count: 96)
        values[1] = 10
        for slot in 2..<96 { values[slot] = 30 }

        #expect(DayCurve.value(of: values, at: 0) == 0)
        #expect(DayCurve.value(of: values, at: 1.5 / 96) == 5)
        #expect(DayCurve.value(of: values, at: 2.5 / 96) == 20)
        #expect(DayCurve.value(of: values, at: 1) == 30)
    }

    /// The chart sits beside the rate, so the two count the same sources.
    @Test func theSeriesCountsEnabledSourcesOnly() async throws {
        let (engine, store) = try engine(preferences: preferences { $0.enabledSources = [.claudeCode] })
        try store.upsert([event("on", tokens: 15), event("off", source: .pi, tokens: 5)])

        let dashboard = try await dashboard(engine, after: 0)

        #expect(dashboard.perMinute == 3)
        #expect(dashboard.series[59].input == 15)
    }

    /// No row changes and the clock stands still, so only `apply` can say that the kept series is out of date.
    @Test func switchingASourceOffTakesItOutOfTheSeriesAtOnce() async throws {
        let all = try preferences()
        let (engine, store) = try engine(preferences: all)
        try store.upsert([event("on", tokens: 3), event("off", source: .pi, tokens: 5)])
        #expect(try await dashboard(engine, after: 0).series[59].input == 8)

        var fewer = all
        fewer.enabledSources = [.claudeCode]
        await engine.apply(fewer)
        #expect(try await dashboard(engine, after: 0).series[59].input == 3)

        await engine.apply(all)
        #expect(try await dashboard(engine, after: 0).series[59].input == 8)

        var none = all
        none.enabledSources = []
        await engine.apply(none)
        #expect(try await dashboard(engine, after: 0).series[59] == .zero)
    }

    @Test func aSwitchedOffSourcesQuotaFileIsLeftUnread() async throws {
        let home = try makeTempDir()
        try Data(Self.claudeConfig.utf8).write(to: home.appendingPathComponent(".claude.json"))
        let all = try preferences()
        var fewer = all
        fewer.enabledSources = [.pi]
        let (engine, store) = try engine(home: home, preferences: fewer)

        await engine.poller.pollOnce()
        #expect(try store.latestSnapshots().isEmpty)

        await engine.apply(all)
        await engine.poller.pollOnce()
        #expect(!(try store.latestSnapshots().isEmpty))
    }

    /// A full window past its reset, a snapshot stops being a forecast. Nothing is written then: only `now` says so.
    @Test func aQuotaStopsBeingCurrentWithNoNewRows() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("before", ago: 3_600, tokens: 10_000_000)])
        try store.record([snapshot(used: 95, resetsIn: 30)])

        let before = try #require(try await dashboard(engine, after: 18_029).quotas.first)
        #expect(before.hasRecentData)

        let after = try #require(try await dashboard(engine, after: 18_030).quotas.first)
        #expect(!after.hasRecentData)
        #expect(after.outcome == .unknown)
    }

    /// A row that lands is on the next tick, wherever it falls, including under a newer event.
    @Test func aNewRowShowsOnTheNextTick() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("newest", tokens: 3)])
        #expect(try await dashboard(engine, after: 0).today.tokens.input == 3)

        try store.upsert([event("older", ago: 7_200, source: .pi, tokens: 5)])

        let next = try await dashboard(engine, after: 1)
        #expect(next.today.tokens.input == 8)
        #expect(next.sources.map(\.source).contains(.pi))
    }

    /// The store's merge rewrites a row without adding one: the newest event stays the same, and the figures must not.
    @Test func aRewrittenRowShowsOnTheNextTick() async throws {
        let (engine, store) = try engine()
        var first = event("a", ago: 100)
        first.tokens = TokenCounts(output: 10)
        try store.upsert([first, event("newest", tokens: 1)])
        #expect(try await dashboard(engine, after: 0).today.tokens.output == 10 + 0)

        first.tokens = TokenCounts(output: 500)
        try store.upsert([first])

        #expect(try await dashboard(engine, after: 1).today.tokens.output == 500)
    }

    @Test func aNewSnapshotShowsInHasQuotaOnTheNextTick() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", ago: 10)])
        #expect(try await dashboard(engine, after: 0).sources.first?.hasQuota == false)

        try store.record([snapshot()])

        #expect(try await dashboard(engine, after: 1).sources.first?.hasQuota == true)
    }

    /// The real check on anything kept between ticks: at every step of a run, an engine that has been ticking says exactly what
    /// one seeing the store for the first time says. Quotas are left out, as weights are kept on purpose (see the tests above).
    @Test func aLongRunningEngineAgreesWithAFreshOneAtEveryStep() async throws {
        let store = try EventStore.inMemory()
        let shared = try preferences()
        let (longRunning, _) = try engine(store: store, preferences: shared)
        func differences(at seconds: TimeInterval) async throws -> String? {
            let at = now.addingTimeInterval(seconds)
            var kept = try await longRunning.dashboard(now: at, calendar: utc)
            let (fresh, _) = try engine(store: store, preferences: shared)
            var expected = try await fresh.dashboard(now: at, calendar: utc)
            kept.quotas = []
            expected.quotas = []
            kept.alert = .none
            expected.alert = .none
            return kept == expected ? nil : "at +\(seconds): \(kept) != \(expected)"
        }
        var writes: [TimeInterval: [UsageEvent]] = [:]
        var sampled = event("timed", ago: 86_000, model: "m-old", startTime: now.addingTimeInterval(-86_012))
        sampled.tokens = TokenCounts(output: 600)
        try store.upsert([sampled, event("hour", ago: 3_500, source: .pi, tokens: 4), event("rate", ago: 55, client: "cli", tokens: 9)])
        writes[7] = [event("w1", ago: -7, client: "cli", tokens: 11)]
        writes[8] = [event("w2", ago: -8, source: .codex, client: "codex-tui", provider: "openai", tokens: 13)]
        writes[9] = [event("w3", ago: -9, model: "mystery", tokens: 3)]
        writes[100] = [event("back-dated", ago: 4_000, source: .grok, tokens: 17)]
        writes[150] = [event("ahead", ago: -300, tokens: 19)]
        for second in stride(from: 0.0, through: 620, by: 1) {
            if let batch = writes[second] { try store.upsert(batch) }
            if second == 60 { try store.record([snapshot()]) }
            if let difference = try await differences(at: second) {
                Issue.record(Comment(rawValue: difference))
                return
            }
        }
    }

    // MARK: Apply

    @Test func applyTakesEffectAtOnce() async throws {
        let original = try preferences()
        let (engine, store) = try engine(preferences: original)
        try store.upsert([event("a", ago: 10, tokens: 1_000_000)])
        #expect(abs(try await engine.dashboard(now: now, calendar: utc).today.cost.usd - 1) < 1e-9)

        var changed = original
        changed.priceOverrides["test-model"]?.price = flat(3)
        await engine.apply(changed)

        #expect(await engine.prices.entry(for: "test-model")?.price == flat(3))
        #expect(abs(try await engine.dashboard(now: now, calendar: utc).today.cost.usd - 3) < 1e-9)
    }

    /// Overrides replace bundled rows; dropping one brings the bundled row back rather than keeping the old override.
    @Test func applyStartsFromTheBundledPrices() async throws {
        let bundled = try PriceTable.bundled().entry(for: "claude-opus-5-5")
        let original = try preferences { $0.priceOverrides["claude-opus-5-5"] = entry("claude-opus-5-5") }
        let (engine, _) = try engine(preferences: original)
        #expect(await engine.prices.entry(for: "claude-opus-5-5")?.price == flat(1))

        var changed = original
        changed.priceOverrides = [:]
        await engine.apply(changed)

        #expect(await engine.prices.entry(for: "claude-opus-5-5") == bundled)
    }

    @Test func applyRefreshesTheWeightsAtOnce() async throws {
        let original = try preferences()
        let (engine, store) = try engine(preferences: original)
        try store.upsert([event("before", ago: 3_600, tokens: 10_000_000)])
        try store.record([snapshot()])
        #expect(try await engine.dashboard(now: now, calendar: utc).quotas.first?.method == .calibrated)

        var changed = original
        changed.quotaSources = []
        await engine.apply(changed)

        #expect(try await engine.dashboard(now: now, calendar: utc).quotas.first?.method == .windowAverage)
    }

    /// A source switched off is in no forecast, whatever its "counts towards limits" box says.
    @Test func aDisabledSourceWeighsInNoForecast() async throws {
        let (engine, store) = try engine(preferences: preferences { $0.enabledSources = [.codex] })
        try store.upsert([event("off", ago: 3_600, tokens: 10_000_000)])
        try store.record([snapshot()])

        #expect(try await engine.dashboard(now: now, calendar: utc).quotas.first?.method == .windowAverage)
    }

    /// What was kept was worked out under the old settings: a source back on brings its figures back with it.
    @Test func applyRereadsWhatWasKept() async throws {
        let original = try preferences { $0.enabledSources = [.claudeCode] }
        let (engine, store) = try engine(preferences: original)
        try store.upsert([event("a", ago: 10, tokens: 3), event("b", ago: 10, source: .pi, tokens: 5)])
        #expect(try await engine.dashboard(now: now, calendar: utc).today.tokens.input == 3)

        var changed = original
        changed.enabledSources = [.claudeCode, .pi]
        await engine.apply(changed)

        let dashboard = try await engine.dashboard(now: now, calendar: utc)
        #expect(dashboard.today.tokens.input == 8)
        #expect(dashboard.sources.first { $0.source == .pi }?.today.input == 5)
    }

    /// The price bands are worked out in the query, so a new threshold changes what is kept, not only what it is multiplied by.
    @Test func aNewThresholdRepricesToday() async throws {
        let original = try preferences()
        let (engine, store) = try engine(preferences: original)
        try store.upsert([event("a", ago: 10, tokens: 60_000)])
        #expect(abs(try await engine.dashboard(now: now, calendar: utc).today.cost.usd - 0.06) < 1e-9)

        var changed = original
        changed.priceOverrides["test-model"] = entry("test-model", longContext: LongContextPrice(abovePromptTokens: 50_000, price: flat(10)))
        await engine.apply(changed)

        let dashboard = try await engine.dashboard(now: now, calendar: utc)
        #expect(abs(dashboard.today.cost.usd - 0.6) < 1e-9)
        #expect(abs((dashboard.sources.first?.costLastHour.usd ?? 0) - 0.6) < 1e-9)
    }

    @Test func applyChangesTheEnabledSources() async throws {
        let original = try preferences()
        let (engine, store) = try engine(preferences: original)
        try store.upsert([event("a", ago: 10, source: .pi)])
        #expect(try await engine.dashboard(now: now, calendar: utc).sources.count == 1)

        var changed = original
        changed.enabledSources = [.claudeCode]
        await engine.apply(changed)

        #expect(try await engine.dashboard(now: now, calendar: utc).sources.isEmpty)
    }

    // MARK: The Anthropic fetcher

    @Test func noFetcherUnlessTheUserTurnedTheQueryOn() async throws {
        let fetches = FetchLog()
        let (engine, _) = try engine(fetches: fetches)

        await engine.poller.fetchIfDue()

        #expect(await engine.fetcher == nil)
        #expect(fetches.tokens == 0)
    }

    @Test func turningTheQueryOnStartsFetching() async throws {
        let fetches = FetchLog()
        let original = try preferences()
        let (engine, _) = try engine(preferences: original, fetches: fetches)

        var on = original
        on.anthropicQueryEnabled = true
        await engine.apply(on)
        await engine.poller.fetchIfDue()

        #expect(fetches.tokens == 1)
    }

    @Test func aPreferenceThatStartsOnIsOnFromTheStart() async throws {
        let fetches = FetchLog()
        let (engine, _) = try engine(preferences: preferences { $0.anthropicQueryEnabled = true }, fetches: fetches)
        await engine.poller.fetchIfDue()
        #expect(fetches.tokens == 1)
    }

    @Test func turningTheQueryOffStopsFetching() async throws {
        let fetches = FetchLog()
        let original = try preferences { $0.anthropicQueryEnabled = true }
        let (engine, _) = try engine(preferences: original, fetches: fetches)

        var off = original
        off.anthropicQueryEnabled = false
        await engine.apply(off)
        await engine.poller.fetchIfDue()

        #expect(fetches.tokens == 0)
    }

    /// A new fetcher would forget a Retry-After back-off.
    @Test func thereIsOnlyEverOneFetcher() async throws {
        let fetches = FetchLog()
        let on = try preferences { $0.anthropicQueryEnabled = true }
        var off = on
        off.anthropicQueryEnabled = false
        let (engine, _) = try engine(preferences: on, fetches: fetches)
        let first = try #require(await engine.fetcher)

        await engine.apply(on)
        await engine.apply(off)
        await engine.apply(on)

        #expect(await engine.fetcher === first)
    }

    /// The promise behind the consent sheet: once off, nothing goes out. A cycle may already be inside `fetch`, waiting on the keychain,
    /// past every check the poller makes; it must still stop short of the request.
    @Test func aFetchAlreadyUnderWaySendsNothingOnceTheQueryIsOff() async throws {
        let fetches = FetchLog(holdsToken: true)
        let on = try preferences { $0.anthropicQueryEnabled = true }
        var off = on
        off.anthropicQueryEnabled = false
        let (engine, _) = try engine(preferences: on, fetches: fetches)

        let cycle = Task { await engine.poller.fetchIfDue() }
        for _ in 0..<500 where fetches.tokens == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(fetches.tokens == 1)

        await engine.apply(off)
        fetches.releaseToken()
        await cycle.value

        #expect(fetches.sends == 0)
    }

    /// The app saves settings in order, so if `apply` waited for its rescan, a "no" would wait behind it, with requests still going out.
    @Test func turningTheQueryOffDoesNotWaitForARescan() async throws {
        let fetches = FetchLog()
        let home = try makeTempDir()
        let files = try (0..<40).map { index in
            let file = home.appendingPathComponent("\(index).jsonl")
            try write(["x"], to: file)
            return file
        }
        var on = Preferences.defaults(home: home)
        on.roots = SourceRoots(roots: [.claudeCode: [home.path]])
        on.enabledSources = [.claudeCode]
        on.anthropicQueryEnabled = true
        var off = on
        off.anthropicQueryEnabled = false
        let engine = try Engine(
            store: .inMemory(),
            home: home,
            preferences: on,
            readers: [SlowReader(files: files)],
            token: { try fetches.token() },
            send: { try await fetches.send($0) }
        )

        let clock = ContinuousClock()
        let started = clock.now
        await engine.apply(on)
        await engine.apply(off)
        let elapsed = started.duration(to: clock.now)
        await engine.poller.fetchIfDue()

        #expect(elapsed < .seconds(1))
        #expect(fetches.tokens == 0)
        #expect(fetches.sends == 0)
    }

    /// Off in the Engine means off for the token too: a cycle that starts after the "no" does not touch the keychain.
    @Test func noTokenIsReadOnceTheQueryIsOff() async throws {
        let fetches = FetchLog()
        let on = try preferences { $0.anthropicQueryEnabled = true }
        var off = on
        off.anthropicQueryEnabled = false
        let (engine, _) = try engine(preferences: on, fetches: fetches)
        let fetcher = try #require(await engine.fetcher)

        await engine.apply(off)
        _ = await fetcher.fetch()

        #expect(fetches.tokens == 0)
        #expect(fetches.sends == 0)
    }

    /// Settings saved one after the other land in that order, however long each rescan takes.
    @Test func sourceChangesReachTheIngestorInOrder() async throws {
        let home = try makeTempDir()
        let files = try (0..<10).map { index in
            let file = home.appendingPathComponent("\(index).jsonl")
            try write(["x"], to: file)
            return file
        }
        var off = Preferences.defaults(home: home)
        off.roots = SourceRoots(roots: [.claudeCode: [home.path]])
        off.enabledSources = []
        var on = off
        on.enabledSources = [.claudeCode]
        let reader = SlowReader(files: files)
        let engine = try Engine(
            store: .inMemory(),
            home: home,
            preferences: off,
            readers: [reader],
            token: { nil },
            send: { _ in throw CancellationError() }
        )

        await engine.apply(on)
        await engine.apply(off)

        // The slow rescan of the first change is what a later change could land before, so it has to be over first: seen any
        // sooner, "off" could be the state only until "on" lands.
        #expect(try await eventually { reader.finished >= files.count })
        #expect(try await eventually { await engine.statuses().first?.enabled == false })
    }

    // MARK: Overview

    private var all: TimeRange {
        TimeRange(start: date("2026-01-01T00:00:00Z"), end: date("2027-01-01T00:00:00Z"))
    }

    @Test func overviewBreaksDownByDimension() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            event("a", ago: 10, project: "/p/one", tokens: 1_000_000),
            event("b", ago: 10, source: .pi, project: "/p/two", model: "gemma4:12b", tokens: 3_000_000),
        ])

        let overview = try await engine.overview(range: all, calendar: utc)

        #expect(overview.tokens.input == 4_000_000)
        #expect(abs(overview.cost.usd - 1) < 1e-9)
        #expect(overview.cost.unpricedModels == ["gemma4:12b"])
        #expect(overview.byModel.map(\.key) == ["gemma4:12b", "test-model"])
        #expect(overview.byProject.map(\.key) == ["/p/two", "/p/one"])
        #expect(abs(overview.byProject[1].cost.usd - 1) < 1e-9)
    }

    /// A source reads as its product name; the row is for people, and the raw value is an implementation detail.
    @Test func overviewNamesSources() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", tokens: 5), event("b", source: .omp, tokens: 3)])
        #expect(try await engine.overview(range: all, calendar: utc).bySource.map(\.key) == ["Claude Code", "oh-my-pi"])
    }

    /// The app has the words for this, in both languages. The tokens still count.
    @Test func overviewLeavesAMissingModelOrProjectEmpty() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", project: nil, model: nil, tokens: 5)])
        let overview = try await engine.overview(range: all, calendar: utc)
        #expect(overview.byModel.map(\.key) == [""])
        #expect(overview.byProject.map(\.key) == [""])
        #expect(overview.byModel.first?.tokens.input == 5)
    }

    @Test func overviewFollowsTheRange() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("in", ago: 10, tokens: 3), event("out", ago: 7_200, tokens: 5)])
        let hour = TimeRange(start: now.addingTimeInterval(-3_600), end: now)
        #expect(try await engine.overview(range: hour, calendar: utc).tokens.input == 3)
    }

    @Test func overviewCarriesSpeeds() async throws {
        let (engine, store) = try engine()
        var timed = event("a", ago: 10, generationMs: 10_000)
        timed.tokens = TokenCounts(output: 600)
        try store.upsert([timed])
        #expect(try await engine.overview(range: all, calendar: utc).speeds.map(\.tokensPerSecond) == [60])
    }

    @Test func overviewBreaksEachSourceDownByClient() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            event("a", ago: 10, client: "cli", tokens: 1_000_000),
            event("b", ago: 20, client: "cli", tokens: 1_000_000),
            event("c", ago: 10, client: "claude-desktop", tokens: 5_000_000),
            event("d", ago: 10, source: .codex, client: "codex-tui", tokens: 3_000_000),
        ])

        let overview = try await engine.overview(range: all, calendar: utc)

        #expect(Set(overview.clientsBySource.keys) == Set(overview.bySource.map(\.key)))
        let claude = try #require(overview.clientsBySource["Claude Code"])
        #expect(claude.map(\.key) == ["claude-desktop", "cli"])
        #expect(claude.map(\.tokens.input) == [5_000_000, 2_000_000])
        #expect(abs(claude[1].cost.usd - 2) < 1e-9)
        #expect(overview.clientsBySource["Codex"]?.map(\.key) == ["codex-tui"])
    }

    /// The same rule as the dashboard: a source that names no client has no sub-rows.
    @Test func overviewClientsLeaveOutEventsWithoutAClient() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            event("named", ago: 10, client: "cli", tokens: 3),
            event("unnamed", ago: 20, tokens: 5),
            event("elsewhere", ago: 10, source: .pi, tokens: 7),
        ])

        let overview = try await engine.overview(range: all, calendar: utc)

        #expect(overview.clientsBySource["Claude Code"]?.map(\.tokens.input) == [3])
        #expect(overview.clientsBySource["pi"] == nil)
    }

    @Test func overviewClientsFollowTheRange() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("in", ago: 10, client: "cli", tokens: 3), event("out", ago: 7_200, client: "cli", tokens: 5)])
        let hour = TimeRange(start: now.addingTimeInterval(-3_600), end: now)
        #expect(try await engine.overview(range: hour, calendar: utc).clientsBySource["Claude Code"]?.map(\.tokens.input) == [3])
    }

    @Test func overviewClientCostsNameWhatIsUnpriced() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", client: "cli", model: "gemma4:12b", tokens: 3)])
        let row = try #require(try await engine.overview(range: all, calendar: utc).clientsBySource["Claude Code"]?.first)
        #expect(row.cost.unpricedModels == ["gemma4:12b"])
    }

    /// R7: the band comes from the effective table. 50,000 is no bundled threshold.
    @Test func costsUseTheEffectiveTablesThresholds() async throws {
        let long = LongContextPrice(abovePromptTokens: 50_000, price: flat(10))
        let (engine, store) = try engine(preferences: preferences {
            $0.priceOverrides["test-model"] = entry("test-model", longContext: long)
        })
        try store.upsert([event("a", ago: 10, client: "cli", tokens: 60_000)])

        #expect(abs(try await engine.overview(range: all, calendar: utc).cost.usd - 0.6) < 1e-9)
        #expect(abs((try await engine.overview(range: all, calendar: utc).clientsBySource["Claude Code"]?.first?.cost.usd ?? 0) - 0.6) < 1e-9)
        #expect(abs(try await engine.dashboard(now: now, calendar: utc).today.cost.usd - 0.6) < 1e-9)
        #expect(abs((try await engine.log(filter: .all, before: nil, limit: 1).first?.costUSD ?? 0) - 0.6) < 1e-9)
        #expect(abs((try await engine.heatmaps(now: now, range: all, calendar: utc).days.last?.costUSD ?? 0) - 0.6) < 1e-9)
    }

    // MARK: Log

    @Test func logRowsCarryCostAndSpeed() async throws {
        let (engine, store) = try engine()
        var exact = event("exact", ago: 10, generationMs: 10_000)
        exact.tokens = TokenCounts(output: 600)
        var approximate = event("approximate", ago: 20, startTime: now.addingTimeInterval(-32))
        approximate.tokens = TokenCounts(output: 600)
        let unpriced = event("unpriced", ago: 30, model: "gemma4:12b", tokens: 5)
        try store.upsert([exact, approximate, unpriced])

        let rows = try await engine.log(filter: .all, before: nil, limit: 10)

        #expect(rows.map(\.event.dedupKey) == ["claudeCode:exact", "claudeCode:approximate", "claudeCode:unpriced"])
        #expect(abs((rows[0].costUSD ?? 0) - 0.0006) < 1e-12)
        #expect(rows[0].tokensPerSecond == 60)
        #expect(!rows[0].approximateSpeed)
        #expect(rows[1].tokensPerSecond == 50)
        #expect(rows[1].approximateSpeed)
        #expect(rows[2].costUSD == nil)
        #expect(rows[2].tokensPerSecond == nil)
        #expect(!rows[2].approximateSpeed)
    }

    @Test func logFollowsTheFilterAndPage() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", ago: 10), event("b", ago: 20), event("c", ago: 30, source: .pi)])

        let first = try await engine.log(filter: EventFilter(sources: [.claudeCode]), before: nil, limit: 1)
        #expect(first.map(\.event.dedupKey) == ["claudeCode:a"])

        let second = try await engine.log(filter: EventFilter(sources: [.claudeCode]), before: first[0].event.time, limit: 1)
        #expect(second.map(\.event.dedupKey) == ["claudeCode:b"])
    }

    // MARK: Heatmaps

    @Test func heatmapDaysAreTheLast365LocalDaysEndingToday() async throws {
        let (engine, store) = try engine()
        try store.upsert([
            event("now", tokens: 3),
            event("oldest", ago: 364 * 86_400, tokens: 5),
            event("too-old", ago: 365 * 86_400 + 40_000, tokens: 7),
        ])

        let days = try await engine.heatmaps(now: now, range: all, calendar: utc).days

        #expect(days.count == 365)
        #expect(days.last?.day == date("2026-11-03T00:00:00Z"))
        #expect(days.first?.day == date("2025-11-04T00:00:00Z"))
        #expect(days.last?.tokens == 3)
        #expect(days.first?.tokens == 5)
        #expect(days.map(\.tokens).reduce(0, +) == 8)
    }

    /// Cuba skips midnight on 8 March: that day's cell starts at 01:00, and there is still exactly one of it.
    @Test func heatmapDaysFollowTheLocalCalendar() async throws {
        var havana = Calendar(identifier: .gregorian)
        havana.timeZone = try #require(TimeZone(identifier: "America/Havana"))
        let (engine, store) = try engine()
        var skipped = event("skipped", tokens: 5)
        skipped.time = date("2026-03-08T05:10:00Z")
        try store.upsert([skipped])

        let days = try await engine.heatmaps(now: now, range: all, calendar: havana).days

        #expect(days.count == 365)
        #expect(Set(days.map(\.day)).count == 365)
        #expect(days.first { $0.day == date("2026-03-08T05:00:00Z") }?.tokens == 5)
    }

    @Test func heatmapCellsCarryCost() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("a", ago: 10, tokens: 2_000_000)])
        let days = try await engine.heatmaps(now: now, range: all, calendar: utc).days
        #expect(abs((days.last?.costUSD ?? 0) - 2) < 1e-9)
    }

    /// The day grid is always a year; the hour-of-week grid is what the range picker asks for.
    @Test func hourOfWeekFollowsTheRange() async throws {
        let (engine, store) = try engine()
        try store.upsert([event("in", ago: 3_600, tokens: 3), event("out", ago: 8 * 86_400, tokens: 5)])
        let week = TimeRange(start: now.addingTimeInterval(-7 * 86_400), end: now)

        let heatmaps = try await engine.heatmaps(now: now, range: week, calendar: utc)

        #expect(heatmaps.hourOfWeek.joined().reduce(0, +) == 3)
        #expect(heatmaps.days.map(\.tokens).reduce(0, +) == 8)
    }

    // MARK: Lifecycle

    private func assistantLine(request: String) -> String {
        jsonLine([
            "type": "assistant", "requestId": request, "timestamp": "2026-11-03T09:00:00.000Z",
            "message": ["role": "assistant", "model": "test-model", "usage": ["input_tokens": 3, "output_tokens": 5]],
        ])
    }

    /// A Claude root with one transcript, and an engine with the real reader.
    private func engineWithTranscript(store: EventStore) throws -> Engine {
        let home = try makeTempDir()
        try write([assistantLine(request: "r1")], to: home.appendingPathComponent(".claude/projects/p/a.jsonl"))
        var preferences = Preferences.defaults(home: home)
        preferences.enabledSources = [.claudeCode]
        preferences.priceOverrides = ["test-model": entry("test-model")]
        return try Engine(store: store, home: home, preferences: preferences, readers: [ClaudeCodeReader()], token: { nil }, send: { _ in throw CancellationError() })
    }

    /// The file behind the store's cursor, for a test that takes it away.
    private func transcript(of store: EventStore) throws -> URL? {
        try store.cursorKeys().first.map { URL(fileURLWithPath: String($0.dropFirst("claudeCode:".count))) }
    }

    private func waitUntilLive(_ engine: Engine) async throws {
        for _ in 0..<500 {
            if try await engine.dashboard(now: now, calendar: utc).progress.phase == .live { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the backfill never finished")
    }

    private func engineWithSlowFiles(count: Int) throws -> Engine {
        let home = try makeTempDir()
        let files = try (0..<count).map { index in
            let file = home.appendingPathComponent("\(index).jsonl")
            try write(["x"], to: file)
            return file
        }
        var preferences = Preferences.defaults(home: home)
        preferences.roots = SourceRoots(roots: [.claudeCode: [home.path]])
        preferences.enabledSources = [.claudeCode]
        return try Engine(store: .inMemory(), home: home, preferences: preferences, readers: [SlowReader(files: files)], token: { nil }, send: { _ in throw CancellationError() })
    }

    /// What `dashboard` says about `progress` until `isDone`.
    private func watchProgress(_ engine: Engine, until isDone: @Sendable () async -> Bool) async throws -> [IngestProgress] {
        var seen: [IngestProgress] = []
        for _ in 0..<1_000 {
            seen.append(try await engine.dashboard(now: now, calendar: utc).progress)
            if await isDone() { return seen }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("it never finished")
        return seen
    }

    @Test func progressMovesDuringABackfill() async throws {
        let engine = try engineWithSlowFiles(count: 20)
        await engine.start()

        var seen: [IngestProgress] = []
        for _ in 0..<1_000 {
            let progress = try await engine.dashboard(now: now, calendar: utc).progress
            seen.append(progress)
            if progress.phase == .live { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(seen.contains { $0.phase == .recent && (1..<20).contains($0.filesDone) && $0.filesTotal == 20 })
        #expect(seen.last == IngestProgress(phase: .live, filesDone: 20, filesTotal: 20))
    }

    @Test func progressMovesDuringARebuild() async throws {
        let engine = try engineWithSlowFiles(count: 20)
        await engine.start()
        try await waitUntilLive(engine)

        let rebuild = Task { try await engine.rebuildIndex() }
        let done = OSAllocatedUnfairLock(initialState: false)
        let finished = Task {
            _ = try? await rebuild.value
            done.withLock { $0 = true }
        }
        let seen = try await watchProgress(engine) { done.withLock { $0 } }
        await finished.value

        #expect(seen.contains { $0.phase == .recent && (1..<20).contains($0.filesDone) })
        #expect(try await engine.dashboard(now: now, calendar: utc).progress == IngestProgress(phase: .live, filesDone: 20, filesTotal: 20))
    }

    /// A view's `.task` cancels its work when the view goes away, and the rebuild goes on regardless. If its last word on `progress`
    /// were lost, the app would say it is still indexing until it was relaunched.
    @Test func aCancelledRebuildStillEndsLive() async throws {
        let engine = try engineWithSlowFiles(count: 8)
        await engine.start()
        try await waitUntilLive(engine)

        let rebuild = Task { try await engine.rebuildIndex() }
        try await Task.sleep(for: .milliseconds(100))
        rebuild.cancel()
        _ = try? await rebuild.value

        #expect(try await engine.dashboard(now: now, calendar: utc).progress == IngestProgress(phase: .live, filesDone: 8, filesTotal: 8))
    }

    /// The tracker holds the engine: one left running would keep it alive and waking for ever.
    @Test func aFinishedBackfillLeavesNothingRunning() async throws {
        weak var released: Engine?
        do {
            let engine = try engineWithTranscript(store: .inMemory())
            released = engine
            await engine.start()
            try await waitUntilLive(engine)
        }
        for _ in 0..<200 where released != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(released == nil)
    }

    @Test func aFinishedRebuildLeavesNothingRunning() async throws {
        weak var released: Engine?
        do {
            let engine = try engineWithTranscript(store: .inMemory())
            released = engine
            await engine.start()
            try await waitUntilLive(engine)
            try await engine.rebuildIndex()
        }
        for _ in 0..<200 where released != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(released == nil)
    }

    /// A backfill adds old events, which the check for new data cannot see: the newest event stays the same.
    @Test func aFinishedBackfillRefreshesTheWeightsAtOnce() async throws {
        let store = try EventStore.inMemory()
        let engine = try engineWithTranscript(store: store)
        try store.upsert([event("after", ago: 300, tokens: 1_000_000)])
        try store.record([snapshot()])
        #expect(try await engine.dashboard(now: now, calendar: utc).quotas.first?.method == .windowAverage)

        await engine.start()
        try await waitUntilLive(engine)

        #expect(try await engine.dashboard(now: now.addingTimeInterval(1), calendar: utc).quotas.first?.method == .calibrated)
    }

    @Test func aFinishedRebuildRefreshesTheWeightsAtOnce() async throws {
        let store = try EventStore.inMemory()
        let engine = try engineWithTranscript(store: store)
        await engine.start()
        try await waitUntilLive(engine)
        try store.record([snapshot()])
        #expect(try await engine.dashboard(now: now, calendar: utc).quotas.first?.method == .calibrated)

        // Away goes the only event that calibrated it, so a stale entry would still say calibrated.
        try FileManager.default.removeItem(at: try #require(try transcript(of: store)))
        try await engine.rebuildIndex()

        #expect(try await engine.dashboard(now: now.addingTimeInterval(1), calendar: utc).quotas.first?.method == .windowAverage)
    }

    @Test func startBackfillsAndReportsProgress() async throws {
        let store = try EventStore.inMemory()
        let engine = try engineWithTranscript(store: store)
        #expect(try await engine.dashboard(now: now, calendar: utc).progress.phase == .idle)

        await engine.start()
        try await waitUntilLive(engine)

        #expect(try store.eventCount(source: .claudeCode) == 1)
        let progress = try await engine.dashboard(now: now, calendar: utc).progress
        #expect(progress == IngestProgress(phase: .live, filesDone: 1, filesTotal: 1))
    }

    @Test func startingTwiceBackfillsOnce() async throws {
        let reader = CountingReader()
        let home = try makeTempDir()
        var preferences = Preferences.defaults(home: home)
        preferences.roots = SourceRoots(roots: [.claudeCode: [home.path]])
        preferences.enabledSources = [.claudeCode]
        let engine = try Engine(store: .inMemory(), home: home, preferences: preferences, readers: [reader], token: { nil }, send: { _ in throw CancellationError() })

        await engine.start()
        await engine.start()
        try await waitUntilLive(engine)
        try await Task.sleep(for: .milliseconds(100))

        #expect(reader.count == 1)
    }

    @Test func statusesComeFromTheIngestor() async throws {
        let store = try EventStore.inMemory()
        let engine = try engineWithTranscript(store: store)
        await engine.start()
        try await waitUntilLive(engine)

        let statuses = await engine.statuses()

        #expect(statuses.map(\.source) == [.claudeCode])
        #expect(statuses.first?.events == 1)
    }

    @Test func rebuildIndexReadsEverythingAgainAndKeepsSnapshots() async throws {
        let store = try EventStore.inMemory()
        let engine = try engineWithTranscript(store: store)
        await engine.start()
        try await waitUntilLive(engine)
        try store.upsert([event("not-in-any-file", ago: 10, source: .pi)])
        try store.record([snapshot()])

        try await engine.rebuildIndex()

        #expect(try store.eventCount(source: nil) == 1)
        #expect(try store.latestSnapshots().count == 1)
    }

    @Test func thePublicInitOpensItsDatabase() async throws {
        let url = try makeTempDir().appendingPathComponent("Tacho/tacho.sqlite")
        let engine = try Engine(databaseURL: url, home: makeTempDir(), preferences: preferences(), readers: [])
        #expect(try await engine.dashboard(now: now, calendar: utc).isIdle)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Preferences

    @Test func preferencesDefaults() throws {
        let home = try makeTempDir()
        let defaults = Preferences.defaults(home: home)
        #expect(defaults.rateUnit == .perMinute)
        #expect(defaults.menuBarStyle == .rate)
        #expect(defaults.enabledSources == Set(Source.allCases))
        #expect(defaults.quotaSources == Set(Source.allCases))
        #expect(defaults.roots == SourceRoots.defaults(home: home))
        #expect(!defaults.anthropicQueryEnabled)
        #expect(!defaults.askedAboutAnthropicQuery)
        #expect(defaults.priceOverrides.isEmpty)
        #expect(defaults.language == .system)
        #expect(defaults.rateMode == .output)
        #expect(defaults.pinnedCards == [.output, .cache, .speed, .clis, .tokens, .when])
    }

    @Test func preferencesRoundTrip() throws {
        var preferences = Preferences.defaults(home: try makeTempDir())
        preferences.rateUnit = .perSecond
        preferences.menuBarStyle = .fiveHourPercent
        preferences.enabledSources = [.pi, .grok]
        preferences.quotaSources = [.codex]
        preferences.roots.roots[.pi] = ["/elsewhere/pi"]
        preferences.anthropicQueryEnabled = true
        preferences.askedAboutAnthropicQuery = true
        preferences.priceOverrides = ["m": entry("m")]
        preferences.language = .zhHans
        preferences.rateMode = .cost
        preferences.pinnedCards = [.when, .output]

        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))

        #expect(decoded == preferences)
    }

    private func decoded(removing keys: [String] = [], setting values: [String: Any] = [:]) throws -> (result: Preferences, source: Preferences) {
        var source = Preferences.defaults(home: try makeTempDir())
        source.rateUnit = .perSecond
        source.menuBarStyle = .iconOnly
        source.enabledSources = [.pi]
        source.quotaSources = [.codex]
        source.anthropicQueryEnabled = true
        source.askedAboutAnthropicQuery = true
        source.priceOverrides = ["m": entry("m")]
        source.language = .en
        source.rateMode = .allTokens
        source.pinnedCards = [.cache]
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        for key in keys { object[key] = nil }
        object.merge(values) { $1 }
        let data = try JSONSerialization.data(withJSONObject: object)
        return (try JSONDecoder().decode(Preferences.self, from: data), source)
    }

    /// Saved by a version that did not have the key: one setting takes its default, and the others survive.
    @Test func aMissingPreferenceKeepsTheOthers() throws {
        let (result, source) = try decoded(removing: ["language"])
        #expect(result.language == .system)
        var expected = source
        expected.language = .system
        #expect(result == expected)
    }

    @Test func eachMissingPreferenceTakesItsOwnDefaultAndNothingElse() throws {
        let defaults = Preferences.defaults(home: FileManager.default.homeDirectoryForCurrentUser)
        let keys: [(name: String, restore: (inout Preferences) -> Void)] = [
            ("rateUnit", { $0.rateUnit = defaults.rateUnit }),
            ("menuBarStyle", { $0.menuBarStyle = defaults.menuBarStyle }),
            ("enabledSources", { $0.enabledSources = defaults.enabledSources }),
            ("quotaSources", { $0.quotaSources = defaults.quotaSources }),
            ("roots", { $0.roots = defaults.roots }),
            ("anthropicQueryEnabled", { $0.anthropicQueryEnabled = defaults.anthropicQueryEnabled }),
            ("askedAboutAnthropicQuery", { $0.askedAboutAnthropicQuery = defaults.askedAboutAnthropicQuery }),
            ("priceOverrides", { $0.priceOverrides = defaults.priceOverrides }),
            ("language", { $0.language = defaults.language }),
            ("rateMode", { $0.rateMode = defaults.rateMode }),
            ("pinnedCards", { $0.pinnedCards = defaults.pinnedCards }),
        ]
        for key in keys {
            let (result, source) = try decoded(removing: [key.name])
            var expected = source
            key.restore(&expected)
            #expect(result == expected, "\(key.name)")
        }
    }

    /// Settings saved before rate modes existed, or by a later version with one this build does not have.
    @Test func aRateModeThisBuildCannotReadIsOutput() throws {
        let (result, source) = try decoded(setting: ["rateMode": "joules"])
        #expect(result.rateMode == .output)
        var expected = source
        expected.rateMode = .output
        #expect(result == expected)
    }

    @Test(arguments: [RateMode.output, .allTokens, .cost])
    func everyRateModeRoundTrips(mode: RateMode) throws {
        var preferences = Preferences.defaults(home: try makeTempDir())
        preferences.rateMode = mode
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.rateMode == mode)
    }

    @Test func noKeysAtAllIsTheDefaults() throws {
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(decoded == Preferences.defaults(home: FileManager.default.homeDirectoryForCurrentUser))
    }

    /// `anthropicQueryEnabled` gates the only network request Tacho makes: without the user's word for it, the answer is no.
    @Test func consentIsNeverAssumed() throws {
        let (result, _) = try decoded(removing: ["anthropicQueryEnabled", "askedAboutAnthropicQuery"])
        #expect(!result.anthropicQueryEnabled)
        #expect(!result.askedAboutAnthropicQuery)

        let (unreadable, _) = try decoded(setting: ["anthropicQueryEnabled": "yes"])
        #expect(!unreadable.anthropicQueryEnabled)
    }

    /// Saved by a newer version, after a downgrade: a value this build cannot read is no reason to lose the rest.
    @Test func anUnreadablePreferenceKeepsTheOthers() throws {
        let (result, source) = try decoded(setting: ["menuBarStyle": "fromTheFuture"])
        #expect(result.menuBarStyle == .rate)
        #expect(result.rateUnit == source.rateUnit)
        #expect(result.enabledSources == source.enabledSources)
    }

    /// Preferences that are not a JSON object at all are not preferences.
    @Test func somethingElseEntirelyIsStillAnError() {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Preferences.self, from: Data("[1]".utf8)) }
    }
}
