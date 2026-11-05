import Foundation
import GRDB
import Testing
@testable import TachoKit

/// What a Mac that has never run Tacho shows, exercised against a temporary home. Nothing here reads or writes a real home directory.
struct FreshMachineTests {
    private let now = date("2026-11-05T15:00:00Z")
    private let utc: Calendar

    init() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        utc = calendar
    }

    private func home() throws -> URL { try makeTempDir() }

    private func preferences(_ home: URL, _ change: (inout Preferences) -> Void = { _ in }) -> Preferences {
        var preferences = Preferences.defaults(home: home)
        preferences.askedAboutSources = true
        preferences.askedAboutAnthropicQuery = true
        change(&preferences)
        return preferences
    }

    private func engine(
        home: URL,
        store: EventStore? = nil,
        readers: [any SourceReader] = [],
        enabled: Set<Source>? = nil
    ) throws -> Engine {
        try Engine(
            store: store ?? EventStore.inMemory(),
            home: home,
            preferences: preferences(home) { if let enabled { $0.enabledSources = enabled } },
            readers: readers,
            token: { nil },
            send: { _ in throw CancellationError() }
        )
    }

    /// One Claude Code response for `request` at `time`, priced as claude-opus-4-5.
    private func sessionLine(request: String, at time: String, input: Int = 1_000_000, output: Int = 0) -> String {
        #"{"type":"assistant","timestamp":"\#(time)","requestId":"\#(request)","sessionId":"s1","cwd":"/p","entrypoint":"cli","message":{"id":"m-\#(request)","role":"assistant","model":"claude-opus-4-5","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
    }

    private func waitUntilLive(_ engine: Engine) async throws {
        for _ in 0..<2_000 {
            if try await engine.dashboard(now: now, calendar: utc).progress.phase == .live { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the backfill never finished")
    }

    private func denying(_ url: URL, _ body: () async throws -> Void) async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        try await body()
    }

    // MARK: No CLI, one session, every source off

    @Test func noCLIShowsAnIdleMeterAndSaysComparisonsNeedHistory() async throws {
        let home = try home()
        let engine = try engine(home: home, readers: Ingestor.defaultReaders())
        await engine.start()
        try await waitUntilLive(engine)

        let dashboard = try await engine.dashboard(now: now, calendar: utc)
        #expect(dashboard.isIdle)
        #expect(dashboard.perMinute == 0)
        #expect(dashboard.sources.isEmpty)
        #expect(dashboard.today.tokens == .zero)
        #expect(dashboard.quotas.isEmpty)
        #expect(dashboard.progress.phase == .live)
        #expect(dashboard.progress.filesTotal == 0)

        let insights = try await engine.insights(now: now, calendar: utc)
        #expect(insights.daysOfUse == 0)
        #expect(insights.results.today.rule == .h2(soFar: 0))
        #expect(insights.results.week == .w4(soFar: 0))
        #expect(insights.results.limits.rule == .l7)

        let week = try await engine.detail(range: .week, now: now, calendar: utc)
        let month = try await engine.detail(range: .month, now: now, calendar: utc)
        #expect(week.totals.tokens == .zero)
        #expect(month.totals.tokens == .zero)
        #expect(week.highlights.weekOutput == .w4(soFar: 0))
        #expect(!week.previousIsFull)
        #expect(week.usualCost.daily == nil)
        #expect(month.usualTokens.daily == nil)
    }

    /// A million input tokens of claude-opus-4-5 is $5. Week and Month count today, so the session is in both, and with no earlier day it compares with nothing.
    @Test func oneSessionCountsInEveryRangeAndComparesWithNothing() async throws {
        let home = try home()
        try write(
            [sessionLine(request: "r1", at: "2026-11-05T15:00:00.000Z")],
            to: home.appendingPathComponent(".claude/projects/p/s.jsonl")
        )
        let store = try EventStore.inMemory()
        let engine = try engine(home: home, store: store, readers: [ClaudeCodeReader()], enabled: [.claudeCode])
        await engine.start()
        try await waitUntilLive(engine)

        let dashboard = try await engine.dashboard(now: now, calendar: utc)
        #expect(dashboard.today.tokens.input == 1_000_000)
        #expect(dashboard.today.tokens.output == 0)
        #expect(abs(dashboard.today.cost.usd - 5) < 1e-9)
        #expect(dashboard.today.cost.unpricedTokens == 0)
        #expect(dashboard.sources.map(\.source) == [.claudeCode])
        #expect(try store.eventCount(source: nil) == 1)

        let day = try await engine.detail(range: .day, now: now, calendar: utc)
        #expect(day.totals.tokens.input == 1_000_000)
        #expect(abs(day.totals.cost.usd - 5) < 1e-9)

        let insights = try await engine.insights(now: now, calendar: utc)
        #expect(insights.daysOfUse == 0)
        #expect(insights.results.today.rule == .h2(soFar: 1))
        #expect(insights.results.week == .w4(soFar: 1))
        #expect(insights.results.limits.rule == .l7)
        let week = try await engine.detail(range: .week, now: now, calendar: utc)
        let month = try await engine.detail(range: .month, now: now, calendar: utc)
        #expect(week.totals.tokens.input == 1_000_000)
        #expect(month.totals.tokens.input == 1_000_000)
        #expect(abs(week.totals.cost.usd - 5) < 1e-9)
        #expect(abs(month.totals.cost.usd - 5) < 1e-9)
        #expect(week.highlights.weekOutput == .w4(soFar: 1))
        #expect(week.highlights.weekTokens == .w4(soFar: 1))
        #expect(!week.previousIsFull)
        #expect(week.medianCost == nil)
        #expect(month.medianCost == nil)
        #expect(week.usualCost.daily == nil)
        #expect(month.usualTokens.daily == nil)
    }

    /// A Mac with no Claude Code gets no advice about a query that has nothing to read.
    @Test func aMacWithoutClaudeCodeGetsNoClaudeAdvice() async throws {
        let home = try home()
        let store = try EventStore.inMemory()
        let engine = try engine(home: home, store: store, enabled: [.codex])
        let insights = try await engine.insights(now: now, calendar: utc)
        #expect(insights.results.limits.rule == .l9)
    }

    /// A clock set back leaves the newest log in its future: Today loses it, and the panel needs to know why.
    @Test func aRowAheadOfTheClockIsReported() async throws {
        let home = try home()
        let store = try EventStore.inMemory()
        let engine = try engine(home: home, store: store, enabled: [.claudeCode])
        let ahead = now.addingTimeInterval(3_600)
        try store.upsert([UsageEvent(source: .claudeCode, dedupKey: "claudeCode:ahead", time: ahead, tokens: TokenCounts(input: 4))])
        let dashboard = try await engine.dashboard(now: now, calendar: utc)
        #expect(dashboard.today.tokens == .zero)
        #expect(dashboard.latestRequest == nil)
        #expect(dashboard.newestEvent == ahead)
    }

    /// Yesterday is one day of history. The week chart counts it, and does not call that a fall from a week that never happened.
    @Test func oneEarlierDayFillsThatColumnAndDoesNotCompareAMissingWeek() async throws {
        let home = try home()
        let store = try EventStore.inMemory()
        let engine = try engine(home: home, store: store, enabled: [.claudeCode])
        await engine.start()
        try await waitUntilLive(engine)
        try store.upsert([
            UsageEvent(
                source: .claudeCode, dedupKey: "claudeCode:yesterday", model: "claude-opus-4-5",
                time: date("2026-11-04T15:00:00Z"), tokens: TokenCounts(input: 1_000_000)
            ),
        ])

        let week = try await engine.detail(range: .week, now: now, calendar: utc)
        let month = try await engine.detail(range: .month, now: now, calendar: utc)
        #expect(week.totals.tokens.input == 1_000_000)
        #expect(month.totals.tokens.input == 1_000_000)
        #expect(week.columns.filter(\.hasUse).count == 1)
        #expect(!week.previousIsFull)
        #expect(week.highlights.weekOutput == .w4(soFar: 1))
        #expect(week.highlights.cost.allSatisfy { highlight in
            if case .d4 = highlight { return false }
            if case .d5 = highlight { return false }
            return true
        })

        let insights = try await engine.insights(now: now, calendar: utc)
        #expect(insights.daysOfUse == 1)
        #expect(insights.results.week == .w4(soFar: 1))
        #expect(insights.results.limits.rule == .l7)
    }

    /// The account limit is separate from the one day of logs. With a fresh snapshot the page shows that percent, not "no quota".
    @Test func oneDayWithAQuotaShowsThatLimit() async throws {
        let home = try home()
        let store = try EventStore.inMemory()
        let engine = try engine(home: home, store: store, enabled: [.claudeCode])
        await engine.start()
        try await waitUntilLive(engine)
        try store.upsert([
            UsageEvent(
                source: .claudeCode, dedupKey: "claudeCode:today", provider: "anthropic", model: "claude-opus-4-5",
                time: now, tokens: TokenCounts(input: 1_000)
            ),
        ])
        try store.record([
            QuotaSnapshot(
                provider: .anthropic, window: .fiveHour, usedPercent: 40,
                resetsAt: now.addingTimeInterval(10_800), observedAt: now.addingTimeInterval(-60), origin: .claudeCache
            ),
        ])

        let dashboard = try await engine.dashboard(now: now, calendar: utc)
        let quota = try #require(dashboard.quotas.first)
        #expect(quota.hasRecentData)
        #expect(quota.estimatedPercent.isFinite)
        #expect(quota.estimatedPercent >= 40)
        #expect(quota.estimatedPercent <= 100)
        // A 40% snapshot can already be "runs out before reset" from its own pace. What it must not say is that there is no quota.
        let limits = try await engine.insights(now: now, calendar: utc).results.limits
        #expect(limits.limit != nil)
        #expect(limits.rule != .l6 && limits.rule != .l7 && limits.rule != .l8)
    }

    /// Switching every source off leaves the rows in the store and takes them off the meter, the speed included.
    @Test func everySourceOffShowsNothingAndDoesNotFail() async throws {
        let home = try home()
        var on = preferences(home) { $0.enabledSources = [.claudeCode] }
        let store = try EventStore.inMemory()
        let engine = try Engine(
            store: store, home: home, preferences: on, readers: [], token: { nil }, send: { _ in throw CancellationError() }
        )
        try store.upsert([
            UsageEvent(
                source: .claudeCode, dedupKey: "claudeCode:fast", model: "m", time: now, generationMs: 10_000,
                tokens: TokenCounts(output: 600)
            ),
        ])
        let shown = try await engine.dashboard(now: now, calendar: utc)
        #expect(shown.today.tokens.output == 600)
        #expect(shown.today.speeds.map(\.model) == ["m"])

        on.enabledSources = []
        await engine.apply(on)
        let hidden = try await engine.dashboard(now: now, calendar: utc)
        #expect(hidden.isIdle)
        #expect(hidden.perMinute == 0)
        #expect(hidden.sources.isEmpty)
        #expect(hidden.today.tokens == .zero)
        #expect(hidden.today.speeds.isEmpty)
        #expect(hidden.series.allSatisfy { $0 == .zero })

        let insights = try await engine.insights(now: now, calendar: utc)
        #expect(insights.results.limits.rule == .l9)
        let week = try await engine.detail(range: .week, now: now, calendar: utc)
        #expect(week.totals.tokens == .zero)
        #expect(try store.eventCount(source: nil) == 1)
    }

    // MARK: Unreadable, symlink, damaged log

    @Test func aSymlinkedCLIDirectoryIsReadAsTheDirectoryItNames() async throws {
        let home = try home()
        let elsewhere = try makeTempDir()
        try write([sessionLine(request: "r1", at: "2026-11-05T15:00:00.000Z", input: 10, output: 4)], to: elsewhere.appendingPathComponent("projects/p/s.jsonl"))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude"), withDestinationURL: elsewhere)
        let store = try EventStore.inMemory()
        let engine = try engine(home: home, store: store, readers: [ClaudeCodeReader()], enabled: [.claudeCode])
        await engine.start()
        try await waitUntilLive(engine)

        #expect(try store.eventCount(source: nil) == 1)
        #expect(try await engine.dashboard(now: now, calendar: utc).today.tokens == TokenCounts(input: 10, output: 4))
        let status = try #require(await engine.statuses().first { $0.source == .claudeCode })
        #expect(status.skipped == 0)
        #expect(status.files == 1)
    }

    @Test func anUnreadableCLIDirectoryIsSkippedAndTheAppStillOpens() async throws {
        let home = try home()
        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let store = try EventStore.inMemory()
        let engine = try engine(home: home, store: store, readers: [ClaudeCodeReader()], enabled: [.claudeCode])
        try await denying(claude) {
            await engine.start()
            try await waitUntilLive(engine)
            let status = try #require(await engine.statuses().first { $0.source == .claudeCode })
            #expect(status.skipped == 1)
            #expect(status.files == 0)
            #expect(try store.eventCount(source: nil) == 0)
            let dashboard = try await engine.dashboard(now: now, calendar: utc)
            #expect(dashboard.isIdle)
            #expect(dashboard.progress.phase == .live)
        }
    }

    @Test func oneUnreadableProjectLeavesTheSessionBesideIt() async throws {
        let home = try home()
        let projects = home.appendingPathComponent(".claude/projects")
        try write([sessionLine(request: "r1", at: "2026-11-05T15:00:00.000Z", input: 7, output: 1)], to: projects.appendingPathComponent("open/s.jsonl"))
        let hidden = projects.appendingPathComponent("shut")
        try write([sessionLine(request: "r2", at: "2026-11-05T15:00:00.000Z", input: 9, output: 1)], to: hidden.appendingPathComponent("t.jsonl"))
        let store = try EventStore.inMemory()
        let engine = try engine(home: home, store: store, readers: [ClaudeCodeReader()], enabled: [.claudeCode])
        try await denying(hidden) {
            await engine.start()
            try await waitUntilLive(engine)
            #expect(try store.eventCount(source: nil) == 1)
            #expect(try await engine.dashboard(now: now, calendar: utc).today.tokens.input == 7)
            let status = try #require(await engine.statuses().first { $0.source == .claudeCode })
            #expect(status.files == 1)
            #expect(status.skipped == 1)
        }
    }

    @Test func aCorruptLineIsSkippedAndAHalfWrittenLineWaits() async throws {
        let home = try home()
        let file = home.appendingPathComponent(".claude/projects/p/s.jsonl")
        let good = sessionLine(request: "r1", at: "2026-11-05T15:00:00.000Z", input: 3, output: 1)
        let broken = #"{"type":"assistant","message":{"usage":"#
        let partial = sessionLine(request: "r2", at: "2026-11-05T15:00:00.000Z", input: 5, output: 1)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((good + "\n" + broken + "\n" + partial).utf8).write(to: file)

        let store = try EventStore.inMemory()
        let engine = try engine(home: home, store: store, readers: [ClaudeCodeReader()], enabled: [.claudeCode])
        await engine.start()
        try await waitUntilLive(engine)
        #expect(try store.eventCount(source: nil) == 1)
        #expect(try await engine.dashboard(now: now, calendar: utc).today.tokens.input == 3)
        #expect(await engine.statuses().first { $0.source == .claudeCode }?.skipped == 1)

        try append("\n", to: file)
        await engine.apply(preferences(home) { $0.enabledSources = [.claudeCode] })
        #expect(try await eventually { (try? store.eventCount(source: nil)) == 2 })
        #expect(try await engine.dashboard(now: now, calendar: utc).today.tokens.input == 8)
        #expect(await engine.statuses().first { $0.source == .claudeCode }?.skipped == 1)
    }

    // MARK: The index

    @Test func aSoundDatabaseIsLeftWhereItIs() async throws {
        let folder = try home()
        let url = folder.appendingPathComponent("tacho.sqlite")
        let seeded = try EventStore(url: url)
        try seeded.upsert([
            UsageEvent(source: .claudeCode, dedupKey: "claudeCode:kept", time: now, tokens: TokenCounts(input: 4)),
        ])
        let engine = try Engine(databaseURL: url, home: try home(), preferences: preferences(try home()), readers: [])
        #expect(try await engine.dashboard(now: now, calendar: utc).today.tokens.input == 4)
        #expect(!engine.indexWasSetAside)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.allSatisfy { !$0.contains("unusable") })
    }

    @Test func aCorruptDatabaseIsSetAsideAndAFreshOneOpens() async throws {
        let folder = try home()
        let url = folder.appendingPathComponent("tacho.sqlite")
        let garbage = Data("not a database".utf8)
        try garbage.write(to: url)
        let engine = try Engine(databaseURL: url, home: folder, preferences: preferences(folder), readers: [])
        #expect(try await engine.dashboard(now: now, calendar: utc).isIdle)
        let kept = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("unusable") }
        let databases = kept.filter {
            !$0.lastPathComponent.hasSuffix("-wal") && !$0.lastPathComponent.hasSuffix("-shm")
        }
        #expect(databases.count == 1)
        #expect(try Data(contentsOf: databases[0]) == garbage)
        #expect(engine.indexWasSetAside)
    }

    @Test func anOldSchemaIsSetAsideAndAFreshOneOpens() throws {
        let folder = try home()
        let url = folder.appendingPathComponent("tacho.sqlite")
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [
            url.path,
            "CREATE TABLE event (id INTEGER PRIMARY KEY); CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY); INSERT INTO grdb_migrations (identifier) VALUES ('v1');",
        ]
        try sqlite.run()
        sqlite.waitUntilExit()
        #expect(sqlite.terminationStatus == 0)

        _ = try Engine(databaseURL: url, home: folder, preferences: preferences(folder), readers: [])
        let reopened = try EventStore(url: url)
        #expect(try reopened.eventCount(source: nil) == 0)
        try reopened.upsert([
            UsageEvent(source: .claudeCode, dedupKey: "claudeCode:new", time: now, tokens: TokenCounts(input: 1)),
        ])
        #expect(try reopened.eventCount(source: nil) == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains { $0.contains("unusable") })
    }

    /// What every install has on its first launch after sync arrived: the backup is taken, the rows stay, and nothing is set aside.
    @Test func anIndexFromBeforeSyncIsMigratedAndNotSetAside() async throws {
        let folder = try home()
        let url = folder.appendingPathComponent("tacho.sqlite")
        try SyncTests.writeCurrentSchema(at: url)

        _ = try Engine(databaseURL: url, home: folder, preferences: preferences(folder), readers: [])

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.allSatisfy { !$0.contains("unusable") })
        #expect(names.contains("tacho.sqlite.bak"))
        let store = try EventStore(url: url)
        #expect(try store.eventCount(source: nil) == 1)
        let others = try await store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event WHERE machine <> ?", arguments: [store.machineId])
        }
        #expect(others == 0)
    }

    /// The migrations say this file is current and the table says otherwise, which no query could recover from later.
    @Test func anIndexMissingTheMachineColumnIsSetAside() async throws {
        let folder = try home()
        let url = folder.appendingPathComponent("tacho.sqlite")
        try SyncTests.writeCurrentSchema(at: url)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v2')")
            try db.execute(sql: "CREATE TABLE install (id INTEGER PRIMARY KEY CHECK (id = 1), machineId TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO install (id, machineId) VALUES (1, ?)", arguments: [UUID().uuidString])
        }
        try queue.close()

        _ = try Engine(databaseURL: url, home: folder, preferences: preferences(folder), readers: [])

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains { $0.contains("unusable") })
        let reopened = try EventStore(url: url)
        try reopened.upsert([
            UsageEvent(source: .claudeCode, dedupKey: "claudeCode:new", time: now, tokens: TokenCounts(input: 1)),
        ])
        #expect(try reopened.eventCount(source: nil) == 1)
    }

    @Test func anIndexWithNoMachineIdIsSetAside() async throws {
        let folder = try home()
        let url = folder.appendingPathComponent("tacho.sqlite")
        do {
            let store = try EventStore(url: url)
            try store.upsert([UsageEvent(source: .claudeCode, dedupKey: "claudeCode:old", time: now, tokens: TokenCounts(input: 1))])
        }
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in try db.execute(sql: "DELETE FROM install") }
        try queue.close()

        _ = try Engine(databaseURL: url, home: folder, preferences: preferences(folder), readers: [])

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains { $0.contains("unusable") })
        #expect(try EventStore(url: url).eventCount(source: nil) == 0)
    }

    /// A file this process cannot open is not a damaged index. Moving it would need a guess, and the original has to stay.
    @Test func anUnreadableDatabaseIsLeftWhereItIs() throws {
        let folder = try home()
        let url = folder.appendingPathComponent("tacho.sqlite")
        try Data("not a database".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        #expect(throws: (any Error).self) {
            _ = try Engine(databaseURL: url, home: folder, preferences: preferences(folder), readers: [])
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.allSatisfy { !$0.contains("unusable") })
    }

    // MARK: Clock

    /// Read once at the event's own time, then with the clock an hour earlier: the future row leaves the meter and comes back.
    @Test func aClockMovedBackHidesTheFutureAndDoesNotStick() async throws {
        let home = try home()
        let store = try EventStore.inMemory()
        let engine = try engine(home: home, store: store, enabled: [.claudeCode])
        await engine.start()
        try await waitUntilLive(engine)
        try store.upsert([
            UsageEvent(source: .claudeCode, dedupKey: "claudeCode:now", time: now, tokens: TokenCounts(input: 11)),
        ])

        #expect(try await engine.dashboard(now: now, calendar: utc).today.tokens.input == 11)
        let earlier = now.addingTimeInterval(-3_600)
        let hidden = try await engine.dashboard(now: earlier, calendar: utc)
        #expect(hidden.today.tokens.input == 0)
        #expect(hidden.perMinute == 0)
        let insights = try await engine.insights(now: earlier, calendar: utc)
        #expect(insights.daysOfUse == 0)
        #expect(insights.results.week == .w4(soFar: 0))
        _ = try await engine.detail(range: .week, now: earlier, calendar: utc)
        _ = try await engine.detail(range: .month, now: earlier, calendar: utc)
        #expect(try await engine.dashboard(now: now, calendar: utc).today.tokens.input == 11)
    }

    // MARK: A large log, generated

    @Test func aLogLargerThanOneReadStillCountsEveryResponse() async throws {
        let home = try home()
        let file = home.appendingPathComponent(".claude/projects/p/big.jsonl")
        let count = 2_500
        let pad = String(repeating: "x", count: 1_800)
        var text = ""
        text.reserveCapacity(count * 2_000)
        for index in 0..<count {
            text += #"{"type":"assistant","timestamp":"2026-11-05T15:00:00.000Z","requestId":"r\#(index)","pad":"\#(pad)","message":{"id":"m\#(index)","role":"assistant","model":"claude-opus-4-5","usage":{"input_tokens":1,"output_tokens":2}}}"# + "\n"
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        #expect(size > LineReader.defaultChunkSize)

        let store = try EventStore.inMemory()
        let engine = try engine(home: home, store: store, readers: [ClaudeCodeReader()], enabled: [.claudeCode])
        let clock = ContinuousClock()
        let started = clock.now
        await engine.start()
        try await waitUntilLive(engine)
        let elapsed = started.duration(to: clock.now)

        #expect(try store.eventCount(source: nil) == count)
        #expect(try await engine.dashboard(now: now, calendar: utc).today.tokens == TokenCounts(input: count, output: count * 2))
        #expect(elapsed < .seconds(30))
    }
}

/// Whether `condition` comes true, however loaded the machine is.
private func eventually(_ condition: () async throws -> Bool) async throws -> Bool {
    for _ in 0..<2_000 {
        if try await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return try await condition()
}
