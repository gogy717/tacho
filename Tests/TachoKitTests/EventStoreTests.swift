import Foundation
import GRDB
import SQLite3
import Testing
@testable import TachoKit

struct EventStoreTests {
    private let t0 = date("2026-11-03T09:00:00Z")
    private let t1 = date("2026-11-03T10:00:00Z")
    private let t2 = date("2026-11-03T10:05:00Z")
    private let t3 = date("2026-11-03T10:10:00Z")

    private func event(_ key: String = "claudeCode:req-1", source: Source = .claudeCode, output: Int, at time: Date) -> UsageEvent {
        UsageEvent(source: source, dedupKey: key, time: time, tokens: TokenCounts(output: output))
    }

    private func snapshot(
        _ provider: QuotaProvider = .anthropic,
        _ window: QuotaWindow = .fiveHour,
        scope: String? = nil,
        used: Double = 10,
        at observedAt: Date
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            window: window,
            scope: scope,
            usedPercent: used,
            resetsAt: observedAt.addingTimeInterval(window.length),
            observedAt: observedAt,
            origin: .claudeCache,
            plan: "max"
        )
    }

    /// The `output` and `time` of the store's only event.
    private func onlyEvent(in store: EventStore) throws -> (output: Int, time: Date) {
        let rows = try store.reader.read { try Row.fetchAll($0, sql: "SELECT output, time FROM event") }
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        return (row["output"], Date(timeIntervalSince1970: row["time"]))
    }

    private func snapshotRowCount(in store: EventStore) throws -> Int? {
        try store.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM quotaSnapshot") }
    }

    /// How many times SQLite's progress handler fires, once per 100 virtual-machine instructions, while `body` runs.
    private func sqliteWork(in store: EventStore, during body: () throws -> Void) throws -> Int {
        let ticks = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        ticks.initialize(to: 0)
        defer { ticks.deallocate() }
        try store.reader.read { db in
            sqlite3_progress_handler(db.sqliteConnection, 100, { context in
                context?.assumingMemoryBound(to: Int.self).pointee += 1
                return 0
            }, ticks)
        }
        defer { _ = try? store.reader.read { sqlite3_progress_handler($0.sqliteConnection, 0, nil, nil) } }
        try body()
        return ticks.pointee
    }

    // MARK: Merge rule

    @Test func upsertKeepsLargerOutputThenLaterTime() throws {
        let store = try EventStore.inMemory()
        try store.upsert([event(output: 500, at: t1)])

        try store.upsert([event(output: 500, at: t2)])
        var stored = try onlyEvent(in: store)
        #expect(stored.output == 500)
        #expect(stored.time == t2)

        try store.upsert([event(output: 400, at: t3)])
        stored = try onlyEvent(in: store)
        #expect(stored.output == 500)
        #expect(stored.time == t2)

        try store.upsert([event(output: 600, at: t0)])
        stored = try onlyEvent(in: store)
        #expect(stored.output == 600)
        #expect(stored.time == t0)
    }

    @Test func upsertIgnoresEqualOutputAtAnEarlierTime() throws {
        let store = try EventStore.inMemory()
        try store.upsert([event(output: 500, at: t2)])
        try store.upsert([event(output: 500, at: t1)])
        #expect(try onlyEvent(in: store).time == t2)
    }

    @Test func upsertIsIdempotent() throws {
        let store = try EventStore.inMemory()
        let batch = [event(output: 500, at: t1)]
        try store.upsert(batch)
        try store.upsert(batch)
        #expect(try store.eventCount(source: nil) == 1)
    }

    @Test func aWinningUpsertReplacesEveryColumn() throws {
        let store = try EventStore.inMemory()
        try store.upsert([
            UsageEvent(
                source: .codex, client: "old client", dedupKey: "k", sessionId: "old session", project: "old project", isSubagent: true,
                provider: "old provider", model: "old model", time: t1, startTime: t0, generationMs: 7, speed: "old speed", geo: "old geo",
                tokens: TokenCounts(input: 1, output: 2, reasoning: 3, cacheRead: 4, cacheWrite5m: 5, cacheWrite1h: 6)
            ),
        ])
        // Every column has a value of its own, so that two bindings swapped, or a column left out, cannot pass.
        try store.upsert([
            UsageEvent(
                source: .omp, client: "new client", dedupKey: "k", sessionId: "new session", project: "new project", isSubagent: false,
                provider: "new provider", model: "new model", time: t2, startTime: t1, generationMs: 17, speed: "new speed", geo: "new geo",
                tokens: TokenCounts(input: 11, output: 12, reasoning: 13, cacheRead: 14, cacheWrite5m: 15, cacheWrite1h: 16)
            ),
        ])

        let row = try #require(try store.reader.read { try Row.fetchOne($0, sql: "SELECT * FROM event") })
        #expect(row["source"] as String == "omp")
        for (column, value) in [
            "client": "new client", "sessionId": "new session", "project": "new project", "provider": "new provider",
            "model": "new model", "speed": "new speed", "geo": "new geo",
        ] {
            #expect(row[column] as String? == value, "\(column)")
        }
        for (column, value) in ["input": 11, "output": 12, "reasoning": 13, "cacheRead": 14, "cacheWrite5m": 15, "cacheWrite1h": 16] {
            #expect(row[column] as Int == value, "\(column)")
        }
        #expect(row["isSubagent"] as Bool == false)
        #expect(row["time"] as Double == t2.timeIntervalSince1970)
        #expect(row["startTime"] as Double == t1.timeIntervalSince1970)
        #expect(row["generationMs"] as Double == 17)
    }

    @Test func eventCountFiltersBySource() throws {
        let store = try EventStore.inMemory()
        try store.upsert([
            event("claudeCode:a", output: 1, at: t1),
            event("claudeCode:b", output: 1, at: t1),
            event("codex:a", source: .codex, output: 1, at: t1),
        ])
        #expect(try store.eventCount(source: nil) == 3)
        #expect(try store.eventCount(source: .claudeCode) == 2)
        #expect(try store.eventCount(source: .codex) == 1)
        #expect(try store.eventCount(source: .grok) == 0)
    }

    // MARK: Cursors

    @Test func cursorsRoundTrip() throws {
        let store = try EventStore.inMemory()
        let key = "claudeCode:/logs/a.jsonl"
        let otherKey = "codex:/logs/b.jsonl.zst"
        // An mtime one ulp off a whole second, which unix seconds cannot hold, and state bytes that are not UTF-8.
        let mtime = Date(timeIntervalSinceReferenceDate: 815_000_000.000000119)
        let cursor = FileCursor(inode: 42, size: 2_048, offset: 1_024, mtime: mtime, state: Data([0x00, 0xFF, 0x7B]), complete: true)

        try store.setCursor(cursor, for: key)
        try store.setCursor(FileCursor(inode: 7, size: 1, offset: 1, mtime: t1), for: otherKey)
        #expect(try store.cursor(key) == cursor)
        #expect(Set(try store.cursorKeys()) == [key, otherKey])

        try store.removeCursor(key)
        #expect(try store.cursor(key) == nil)
        #expect(try store.cursorKeys() == [otherKey])
    }

    @Test func setCursorReplacesTheOldCursor() throws {
        let store = try EventStore.inMemory()
        let key = "claudeCode:/logs/a.jsonl"
        let newer = FileCursor(inode: 42, size: 200, offset: 200, mtime: t2)
        try store.setCursor(FileCursor(inode: 42, size: 100, offset: 100, mtime: t1), for: key)
        try store.setCursor(newer, for: key)
        #expect(try store.cursor(key) == newer)
        #expect(try store.cursorKeys() == [key])
    }

    // MARK: Quota snapshots

    @Test func latestSnapshotPerProviderWindowScope() throws {
        let store = try EventStore.inMemory()
        let newest = snapshot(used: 12, at: t2)
        let scoped = snapshot(.anthropic, .weekly, scope: "Fable", used: 9, at: t1)
        try store.record([snapshot(used: 10, at: t1), newest, scoped])

        let latest = try store.latestSnapshots()
        #expect(latest.count == 2)
        #expect(latest.first { $0.window == .fiveHour } == newest)
        #expect(latest.first { $0.window == .weekly } == scoped)
    }

    @Test func accountWideAndScopedLimitsStayApart() throws {
        let store = try EventStore.inMemory()
        let accountWide = snapshot(.anthropic, .weekly, used: 14, at: t1)
        let scoped = snapshot(.anthropic, .weekly, scope: "Fable", used: 9, at: t1)
        try store.record([accountWide, scoped])

        let latest = try store.latestSnapshots()
        #expect(latest.count == 2)
        #expect(latest.first { $0.scope == nil } == accountWide)
        #expect(latest.first { $0.scope == "Fable" } == scoped)
    }

    /// Codex logs a snapshot with every rate-limited count, so a limit piles up thousands of rows.
    @Test func latestSnapshotsFindsTheNewestOfEveryLimitInALongHistory() throws {
        let store = try EventStore.inMemory()
        let limits: [(provider: QuotaProvider, window: QuotaWindow, scope: String?)] = [
            (.anthropic, .fiveHour, nil), (.anthropic, .weekly, nil), (.anthropic, .weekly, "Fable"), (.anthropic, .weekly, "Opus"),
            (.openai, .fiveHour, nil), (.openai, .weekly, nil), (.xai, .weekly, nil),
        ]
        // Newest first, so the row wanted is the first of its limit to go in, not the last.
        for step in (0..<1_200).reversed() {
            let observedAt = t0.addingTimeInterval(Double(step) * 60)
            try store.record(limits.map { snapshot($0.provider, $0.window, scope: $0.scope, used: Double(step % 100), at: observedAt) })
        }

        let newest = t0.addingTimeInterval(1_199 * 60)
        let latest = try store.latestSnapshots()
        #expect(latest.count == limits.count)
        for limit in limits {
            let found = latest.filter { $0.provider == limit.provider && $0.window == limit.window && $0.scope == limit.scope }
            #expect(found == [snapshot(limit.provider, limit.window, scope: limit.scope, used: 99, at: newest)])
        }
    }

    /// The dashboard asks every second. `EXPLAIN QUERY PLAN` says SEARCH even for a seek that then steps through a whole
    /// limit, so this counts the work SQLite really does.
    @Test func latestSnapshotsCostsTheSameHoweverLongTheHistory() throws {
        let store = try EventStore.inMemory()
        func recordHistory(_ steps: Range<Int>) throws {
            try store.record(steps.flatMap { step in
                let observedAt = t0.addingTimeInterval(Double(step) * 60)
                return [snapshot(.openai, .fiveHour, at: observedAt), snapshot(.openai, .weekly, at: observedAt)]
            })
        }

        try recordHistory(0..<10)
        let short = try sqliteWork(in: store) { _ = try store.latestSnapshots() }
        try recordHistory(10..<10_000)
        let long = try sqliteWork(in: store) { _ = try store.latestSnapshots() }

        #expect(try store.latestSnapshots().count == 2)
        #expect(long <= short + 1)

        // The counter has to see a full scan of those rows, or the comparison above would hold whatever the query did.
        let fullScan = try sqliteWork(in: store) {
            _ = try store.reader.read { try Double.fetchOne($0, sql: "SELECT sum(usedPercent) FROM quotaSnapshot") }
        }
        #expect(fullScan > 100)
        #expect(fullScan > long * 10)
    }

    /// `pollOnce` re-reads a cache that still holds the same observation; most limits have no scope.
    @Test func recordIgnoresDuplicatesOfAnUnscopedLimit() throws {
        let store = try EventStore.inMemory()
        let observed = snapshot(used: 10, at: t1)
        try store.record([observed])
        try store.record([observed])
        #expect(try snapshotRowCount(in: store) == 1)

        // The same limit and time with another figure: the first row stays, where a replace would take the second.
        try store.record([snapshot(used: 20, at: t1)])
        #expect(try snapshotRowCount(in: store) == 1)
        #expect(try store.latestSnapshots().map(\.usedPercent) == [10])
    }

    @Test func recordIgnoresDuplicatesOfAScopedLimit() throws {
        let store = try EventStore.inMemory()
        let observed = snapshot(.anthropic, .weekly, scope: "Fable", used: 9, at: t1)
        try store.record([observed, observed])
        #expect(try snapshotRowCount(in: store) == 1)

        try store.record([snapshot(.anthropic, .weekly, scope: "Fable", used: 20, at: t1)])
        #expect(try snapshotRowCount(in: store) == 1)
        #expect(try store.latestSnapshots().map(\.usedPercent) == [9])
    }

    @Test func latestSnapshotsSkipsRowsThisBuildCannotRead() throws {
        let url = try makeTempDir().appendingPathComponent("tacho.sqlite")
        let store = try EventStore(url: url)
        let known = snapshot(at: t1)
        try store.record([known])
        // Written by a newer build, as seen after a downgrade.
        let other = try DatabaseQueue(path: url.path)
        try other.write {
            try $0.execute(sql: """
                INSERT INTO quotaSnapshot (provider, "window", scope, usedPercent, resetsAt, observedAt, origin)
                VALUES ('zeta', 'fiveHour', '', 1, 2, 3, 'claudeCache')
                """)
        }
        #expect(try store.latestSnapshots() == [known])
    }

    // MARK: Generation

    /// What a kept figure is checked against. A write that changes no row must not count, or an idle app would keep recomputing.
    @Test func generationCountsWritesThatChangeRows() throws {
        let store = try EventStore.inMemory()
        let start = store.generation

        try store.upsert([event(output: 500, at: t1)])
        #expect(store.generation == start + 1)

        try store.upsert([event(output: 500, at: t1)])
        #expect(store.generation == start + 1)

        try store.upsert([event(output: 600, at: t1)])
        #expect(store.generation == start + 2)

        try store.upsert([event(output: 100, at: t1)])
        #expect(store.generation == start + 2)

        try store.upsert([])
        #expect(store.generation == start + 2)
    }

    @Test func generationCountsNewSnapshots() throws {
        let store = try EventStore.inMemory()
        let start = store.generation
        let observed = snapshot(at: t1)

        try store.record([observed])
        #expect(store.generation == start + 1)

        try store.record([observed])
        #expect(store.generation == start + 1)
    }

    @Test func generationCountsAReset() throws {
        let store = try EventStore.inMemory()
        try store.upsert([event(output: 500, at: t1)])
        let before = store.generation

        try store.resetIndex()

        #expect(store.generation == before + 1)
    }

    /// Where a file was read up to changes no figure.
    @Test func cursorsDoNotCountAsChanges() throws {
        let store = try EventStore.inMemory()
        let start = store.generation
        try store.setCursor(FileCursor(inode: 1, size: 1, offset: 1, mtime: t1), for: "claudeCode:/a")
        try store.removeCursor("claudeCode:/a")
        #expect(store.generation == start)
    }

    /// The counter moves after the commit: anyone who sees a new value finds the new rows.
    @Test func aNewGenerationMeansTheRowsAreThere() throws {
        let url = try makeTempDir().appendingPathComponent("tacho.sqlite")
        let store = try EventStore(url: url)
        let before = store.generation
        try store.upsert([event(output: 500, at: t1)])
        #expect(store.generation > before)
        #expect(try store.eventCount(source: nil) == 1)
    }

    // MARK: Reset

    @Test func resetIndexKeepsSnapshots() throws {
        let store = try EventStore.inMemory()
        try store.upsert([event(output: 500, at: t1)])
        try store.setCursor(FileCursor(inode: 1, size: 1, offset: 1, mtime: t1), for: "claudeCode:/logs/a.jsonl")
        let observed = snapshot(at: t1)
        try store.record([observed])

        try store.resetIndex()

        #expect(try store.eventCount(source: nil) == 0)
        #expect(try store.cursorKeys().isEmpty)
        #expect(try store.latestSnapshots() == [observed])
    }

    // MARK: Schema

    @Test func datesAreStoredAsUnixSeconds() throws {
        let store = try EventStore.inMemory()
        try store.upsert([UsageEvent(source: .claudeCode, dedupKey: "claudeCode:k", time: t1, startTime: t0, tokens: .zero)])
        try store.record([snapshot(at: t1)])

        let event = try #require(try store.reader.read {
            try Row.fetchOne($0, sql: "SELECT typeof(time) AS kind, typeof(startTime) AS startKind, time, startTime FROM event")
        })
        #expect(event["kind"] as String == "real")
        #expect(event["startKind"] as String == "real")
        #expect(event["time"] as Double == t1.timeIntervalSince1970)
        #expect(event["startTime"] as Double == t0.timeIntervalSince1970)

        let quota = try #require(try store.reader.read {
            try Row.fetchOne($0, sql: "SELECT typeof(observedAt) AS observedKind, typeof(resetsAt) AS resetsKind, observedAt FROM quotaSnapshot")
        })
        #expect(quota["observedKind"] as String == "real")
        #expect(quota["resetsKind"] as String == "real")
        #expect(quota["observedAt"] as Double == t1.timeIntervalSince1970)
    }

    /// Task 11 writes SQL against these names; `logPage` pages on `(time, id)`.
    @Test func eventTableHasTheColumnsAndIndexesQueriesRelyOn() throws {
        let store = try EventStore.inMemory()
        try store.reader.read { db in
            let columns = try db.columns(in: "event")
            #expect(Set(columns.map(\.name)) == [
                "id", "source", "client", "dedupKey", "sessionId", "project", "isSubagent", "provider", "model", "time", "startTime",
                "generationMs", "speed", "geo", "input", "output", "reasoning", "cacheRead", "cacheWrite5m", "cacheWrite1h", "machine",
            ])
            #expect(Set(columns.filter { !$0.isNotNull }.map(\.name)) == [
                "id", "client", "sessionId", "project", "provider", "model", "startTime", "generationMs", "speed", "geo",
            ])
            #expect(try db.table("event", hasUniqueKey: ["machine", "dedupKey"]))
            let indexed = Set(try db.indexes(on: "event").map(\.columns))
            #expect(indexed.isSuperset(of: [["time"], ["source", "time"], ["model"], ["project"]]))
        }
    }

    // MARK: Files

    @Test func aFileStoreIsWALAndSurvivesReopening() throws {
        let url = try makeTempDir().appendingPathComponent("tacho.sqlite")
        try EventStore(url: url).upsert([event(output: 500, at: t1)])

        let reopened = try EventStore(url: url)
        #expect(try reopened.eventCount(source: nil) == 1)
        #expect(try reopened.reader.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") } == "wal")
    }

    /// `~/Library/Application Support/Tacho` does not exist on first launch.
    @Test func aFileStoreCreatesItsDirectory() throws {
        let url = try makeTempDir().appendingPathComponent("Application Support/Tacho/tacho.sqlite")
        let store = try EventStore(url: url)
        #expect(try store.eventCount(source: nil) == 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
