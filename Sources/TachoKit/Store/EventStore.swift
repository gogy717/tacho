import Foundation
import GRDB
import os

/// Tacho's database: every usage event read so far, how far each file has been read, and every quota observation.
///
/// Dates are stored as REAL unix seconds, so queries can compare and bucket them in SQL.
public final class EventStore: Sendable {
    private let writer: any DatabaseWriter

    /// This install's id: a random UUID drawn once, never from the host name, a serial or the user name. Foreign rows carry another.
    public let machineId: String

    /// How many writes have changed events or snapshots. The same value means every query would answer as it did, so figures can be
    /// kept between reads. The database can't say: `PRAGMA data_version` is per connection, and a pool hands out several.
    var generation: Int { changes.withLock { $0 } }
    private let changes = OSAllocatedUnfairLock(initialState: 0)

    /// Read access for the queries built on this store.
    var reader: any DatabaseReader { writer }

    /// `<database>.bak`, written once before the machine migration and never replaced.
    static func backupURL(for database: URL) -> URL {
        database.appendingPathExtension("bak")
    }

    /// Opens the database at `url` in WAL mode, creating it and its directory on first use.
    ///
    /// A store from the previous schema is copied to `backupURL` first. The copy is a consistent snapshot, so a migration that fails
    /// leaves the previous file beside the original.
    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.backupBeforeMachineMigration(url)
        try self.init(writer: DatabasePool(path: url.path))
    }

    /// An empty store that lives as long as the returned object.
    public static func inMemory() throws -> EventStore {
        try EventStore(writer: DatabaseQueue())
    }

    private init(writer: any DatabaseWriter) throws {
        try Self.migrator.migrate(writer)
        self.writer = writer
        self.machineId = try Self.installedMachineId(in: writer)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE event (
                    id INTEGER PRIMARY KEY,
                    source TEXT NOT NULL,
                    client TEXT,
                    dedupKey TEXT NOT NULL UNIQUE,
                    sessionId TEXT,
                    project TEXT,
                    isSubagent INTEGER NOT NULL,
                    provider TEXT,
                    model TEXT,
                    time REAL NOT NULL,
                    startTime REAL,
                    generationMs REAL,
                    speed TEXT,
                    geo TEXT,
                    input INTEGER NOT NULL,
                    output INTEGER NOT NULL,
                    reasoning INTEGER NOT NULL,
                    cacheRead INTEGER NOT NULL,
                    cacheWrite5m INTEGER NOT NULL,
                    cacheWrite1h INTEGER NOT NULL
                );
                CREATE INDEX event_time ON event (time);
                CREATE INDEX event_source_time ON event (source, time);
                CREATE INDEX event_model ON event (model);
                CREATE INDEX event_project ON event (project);

                CREATE TABLE cursor (
                    key TEXT PRIMARY KEY,
                    json TEXT NOT NULL
                );

                -- scope is '' for an account-wide limit: SQLite treats NULLs in a primary key as distinct,
                -- so a NULL scope would let the same observation in twice.
                CREATE TABLE quotaSnapshot (
                    provider TEXT NOT NULL,
                    "window" TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    usedPercent REAL NOT NULL,
                    resetsAt REAL NOT NULL,
                    observedAt REAL NOT NULL,
                    origin TEXT NOT NULL,
                    plan TEXT,
                    PRIMARY KEY (provider, "window", scope, observedAt)
                ) WITHOUT ROWID;
                """)
        }
        // The unique key becomes (machine, dedupKey). SQLite cannot rewrite a column UNIQUE, so the table is rebuilt.
        // Existing rows are this install's: there was nowhere else for them to have come from. The id is drawn here, once.
        migrator.registerMigration("v2") { db in
            let machineId = try Self.makeMachineId()
            try db.execute(sql: """
                CREATE TABLE install (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    machineId TEXT NOT NULL
                );
                """)
            try db.execute(sql: "INSERT INTO install (id, machineId) VALUES (1, ?)", arguments: [machineId])
            try db.execute(sql: """
                CREATE TABLE event_v2 (
                    id INTEGER PRIMARY KEY,
                    source TEXT NOT NULL,
                    client TEXT,
                    dedupKey TEXT NOT NULL,
                    sessionId TEXT,
                    project TEXT,
                    isSubagent INTEGER NOT NULL,
                    provider TEXT,
                    model TEXT,
                    time REAL NOT NULL,
                    startTime REAL,
                    generationMs REAL,
                    speed TEXT,
                    geo TEXT,
                    input INTEGER NOT NULL,
                    output INTEGER NOT NULL,
                    reasoning INTEGER NOT NULL,
                    cacheRead INTEGER NOT NULL,
                    cacheWrite5m INTEGER NOT NULL,
                    cacheWrite1h INTEGER NOT NULL,
                    machine TEXT NOT NULL DEFAULT '\(machineId)',
                    UNIQUE (machine, dedupKey)
                );
                """)
            try db.execute(sql: """
                INSERT INTO event_v2 (
                    id, source, client, dedupKey, sessionId, project, isSubagent, provider, model, time, startTime,
                    generationMs, speed, geo, input, output, reasoning, cacheRead, cacheWrite5m, cacheWrite1h, machine
                )
                SELECT
                    id, source, client, dedupKey, sessionId, project, isSubagent, provider, model, time, startTime,
                    generationMs, speed, geo, input, output, reasoning, cacheRead, cacheWrite5m, cacheWrite1h, ?
                FROM event
                """, arguments: [machineId])
            try db.execute(sql: "DROP TABLE event")
            try db.execute(sql: "ALTER TABLE event_v2 RENAME TO event")
            try db.execute(sql: """
                CREATE INDEX event_time ON event (time);
                CREATE INDEX event_source_time ON event (source, time);
                CREATE INDEX event_model ON event (model);
                CREATE INDEX event_project ON event (project);
                """)
        }
        return migrator
    }

    /// A random UUID. Checked before it is placed in the schema, where it cannot be a bound parameter.
    private static func makeMachineId() throws -> String {
        let id = UUID().uuidString
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEF-")
        guard UUID(uuidString: id) != nil, id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw StoreOpenError(description: "could not draw a machine id")
        }
        return id
    }

    private static func installedMachineId(in writer: any DatabaseReader) throws -> String {
        let id = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT machineId FROM install WHERE id = 1")
        }
        guard let id, UUID(uuidString: id) != nil else {
            throw MissingMachineId()
        }
        return id
    }

    /// Copies a v1 store to `backupURL` before v2 runs. A new store has nothing to copy. An existing copy is left as it is.
    private static func backupBeforeMachineMigration(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let source = try DatabaseQueue(path: url.path)
        let pending = try source.read { db -> Bool in
            guard try db.tableExists("grdb_migrations") else { return false }
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            return applied.contains("v1") && !applied.contains("v2")
        }
        guard pending else { return }
        let backupURL = backupURL(for: url)
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        let destination = try DatabaseQueue(path: backupURL.path)
        try source.backup(to: destination)
        // Checkpoint outside a transaction: inside one, SQLite reports the table as locked.
        _ = try destination.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
    }

    /// A write that moves `generation` if it changed any row. It moves after the commit, so whoever sees the new value finds the new
    /// rows; someone reading in between keeps figures that are newer than their value says, and computes them once more.
    private func writeCounted(_ updates: (Database) throws -> Void) throws {
        let changed = try writer.write { db -> Bool in
            let before = db.totalChangesCount
            try updates(db)
            return db.totalChangesCount != before
        }
        if changed {
            changes.withLock { $0 += 1 }
        }
    }

    // MARK: Events

    /// Adds `events`, merging each into the row that has its `dedupKey` on this machine.
    ///
    /// A row is replaced only by a larger `output`, or by an equal one with a later `time`, so a response ends up with
    /// the same row whatever order its lines and forked copies are read in (spec §5.3). Every row written here is this
    /// install's. Another machine's rows arrive through `importForeign` and are not touched.
    public func upsert(_ events: [UsageEvent]) throws {
        try writeCounted { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO event (
                    source, client, dedupKey, sessionId, project, isSubagent, provider, model, time, startTime,
                    generationMs, speed, geo, input, output, reasoning, cacheRead, cacheWrite5m, cacheWrite1h, machine
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(machine, dedupKey) DO UPDATE SET
                    source = excluded.source,
                    client = excluded.client,
                    sessionId = excluded.sessionId,
                    project = excluded.project,
                    isSubagent = excluded.isSubagent,
                    provider = excluded.provider,
                    model = excluded.model,
                    time = excluded.time,
                    startTime = excluded.startTime,
                    generationMs = excluded.generationMs,
                    speed = excluded.speed,
                    geo = excluded.geo,
                    input = excluded.input,
                    output = excluded.output,
                    reasoning = excluded.reasoning,
                    cacheRead = excluded.cacheRead,
                    cacheWrite5m = excluded.cacheWrite5m,
                    cacheWrite1h = excluded.cacheWrite1h
                WHERE excluded.output > event.output OR (excluded.output = event.output AND excluded.time > event.time)
                """)
            for event in events {
                try statement.execute(arguments: [
                    event.source.rawValue, event.client, event.dedupKey, event.sessionId, event.project, event.isSubagent,
                    event.provider, event.model, event.time.timeIntervalSince1970, event.startTime?.timeIntervalSince1970,
                    event.generationMs, event.speed, event.geo, event.tokens.input, event.tokens.output, event.tokens.reasoning,
                    event.tokens.cacheRead, event.tokens.cacheWrite5m, event.tokens.cacheWrite1h, machineId,
                ])
            }
        }
    }

    /// Merges another machine's rows. `events` already carry the export key, and they have no project, path or session to store.
    /// The same key again changes a row only under the upsert rule. This install's own id is refused: those rows are already here
    /// under their raw keys, and the hash cannot find them.
    func importForeign(machine: String, events: [ForeignUsage]) throws {
        guard machine != machineId, !events.isEmpty else { return }
        try writeCounted { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO event (
                    source, client, dedupKey, sessionId, project, isSubagent, provider, model, time, startTime,
                    generationMs, speed, geo, input, output, reasoning, cacheRead, cacheWrite5m, cacheWrite1h, machine
                )
                VALUES (?, ?, ?, NULL, NULL, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(machine, dedupKey) DO UPDATE SET
                    source = excluded.source,
                    client = excluded.client,
                    isSubagent = excluded.isSubagent,
                    provider = excluded.provider,
                    model = excluded.model,
                    time = excluded.time,
                    startTime = excluded.startTime,
                    generationMs = excluded.generationMs,
                    speed = excluded.speed,
                    input = excluded.input,
                    output = excluded.output,
                    reasoning = excluded.reasoning,
                    cacheRead = excluded.cacheRead,
                    cacheWrite5m = excluded.cacheWrite5m,
                    cacheWrite1h = excluded.cacheWrite1h
                WHERE excluded.output > event.output OR (excluded.output = event.output AND excluded.time > event.time)
                """)
            for event in events {
                try statement.execute(arguments: [
                    event.source, event.client, event.dedupKey, event.isSubagent, event.provider, event.model,
                    event.time, event.startTime, event.generationMs, event.speed, event.input, event.output,
                    event.reasoning, event.cacheRead, event.cacheWrite5m, event.cacheWrite1h, machine,
                ])
            }
        }
    }

    /// The number of events of `source`, or of every source when nil.
    public func eventCount(source: Source?) throws -> Int {
        try writer.read { db in
            if let source {
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event WHERE source = ?", arguments: [source.rawValue]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
        }
    }

    /// Forgets this machine's events and every cursor, so its logs are read again from the start. Quota snapshots stay.
    /// Another machine's rows stay too: there are no logs here to reread them from.
    public func resetIndex() throws {
        try writeCounted { db in
            try db.execute(sql: "DELETE FROM event WHERE machine = ?", arguments: [machineId])
            try db.execute(sql: "DELETE FROM cursor")
        }
    }

    // MARK: Cursors

    /// The cursor stored under `key`, which is `"<source.rawValue>:<path>"`.
    public func cursor(_ key: String) throws -> FileCursor? {
        let json = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT json FROM cursor WHERE key = ?", arguments: [key])
        }
        return try json.map { try JSONDecoder().decode(FileCursor.self, from: Data($0.utf8)) }
    }

    public func setCursor(_ cursor: FileCursor, for key: String) throws {
        let json = String(decoding: try JSONEncoder().encode(cursor), as: UTF8.self)
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO cursor (key, json) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET json = excluded.json",
                arguments: [key, json]
            )
        }
    }

    public func removeCursor(_ key: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM cursor WHERE key = ?", arguments: [key])
        }
    }

    public func cursorKeys() throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: "SELECT key FROM cursor")
        }
    }

    // MARK: Quota snapshots

    /// Adds `snapshots`, ignoring any already recorded for the same provider, window, scope and `observedAt`.
    public func record(_ snapshots: [QuotaSnapshot]) throws {
        try writeCounted { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO quotaSnapshot (provider, "window", scope, usedPercent, resetsAt, observedAt, origin, plan)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT DO NOTHING
                """)
            for snapshot in snapshots {
                try statement.execute(arguments: [
                    snapshot.provider.rawValue, snapshot.window.rawValue, snapshot.scope ?? "", snapshot.usedPercent,
                    snapshot.resetsAt.timeIntervalSince1970, snapshot.observedAt.timeIntervalSince1970,
                    snapshot.origin.rawValue, snapshot.plan,
                ])
            }
        }
    }

    /// The newest snapshot of every (provider, window, scope).
    ///
    /// Codex logs a snapshot with every rate-limited count and the dashboard asks every second, so this must not read the
    /// whole history. The primary key sorts a limit's rows by `observedAt`: walking it backwards, the first row of a limit
    /// is its newest, and the next limit is one seek away. That seek compares all four key columns, with `observedAt` below
    /// any real value; comparing only the first three makes SQLite step back through every row of the limit just read.
    public func latestSnapshots() throws -> [QuotaSnapshot] {
        let newestFirst = #"ORDER BY provider DESC, "window" DESC, scope DESC, observedAt DESC LIMIT 1"#
        return try writer.read { db in
            var latest: [QuotaSnapshot] = []
            var next = try Row.fetchOne(db, sql: "SELECT * FROM quotaSnapshot \(newestFirst)")
            while let row = next {
                if let snapshot = Self.snapshot(from: row) { latest.append(snapshot) }
                next = try Row.fetchOne(
                    db,
                    sql: #"SELECT * FROM quotaSnapshot WHERE (provider, "window", scope, observedAt) < (?, ?, ?, ?) \#(newestFirst)"#,
                    arguments: [row["provider"], row["window"], row["scope"], -Double.infinity]
                )
            }
            return latest
        }
    }

    /// Nil for a row this build cannot name, such as one left by a newer version.
    private static func snapshot(from row: Row) -> QuotaSnapshot? {
        guard
            let provider = QuotaProvider(rawValue: row["provider"]),
            let window = QuotaWindow(rawValue: row["window"]),
            let origin = QuotaOrigin(rawValue: row["origin"])
        else { return nil }
        let scope: String = row["scope"]
        return QuotaSnapshot(
            provider: provider,
            window: window,
            scope: scope.isEmpty ? nil : scope,
            usedPercent: row["usedPercent"],
            resetsAt: Date(timeIntervalSince1970: row["resetsAt"]),
            observedAt: Date(timeIntervalSince1970: row["observedAt"]),
            origin: origin,
            plan: row["plan"]
        )
    }
}

/// The index is recorded as current and has no id for this install, so nothing can be written to it. It goes the way of a damaged file.
struct MissingMachineId: Error, CustomStringConvertible {
    var description: String { "install has no machine id" }
}

private struct StoreOpenError: Error, CustomStringConvertible {
    var description: String
}
