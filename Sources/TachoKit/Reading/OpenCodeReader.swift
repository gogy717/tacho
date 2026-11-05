import Foundation
import GRDB

/// Reads OpenCode's database, `~/.local/share/opencode/opencode.db`.
///
/// An assistant row of the `message` table is one model call, its usage in the row's JSON `data`. OpenCode rewrites a row as the
/// call goes on and stamps `time_updated` each time, so that column is the cursor: a row seen again later is the same call, under
/// the same key, for the store to merge. Tokens are read from `message` only: the `part` table's step-finish rows repeat
/// them, and the `session` table sums them.
///
/// `completed − created` includes the time tools ran, so an event has no generation time.
public struct OpenCodeReader: SourceReader {
    public init() {}

    public var source: Source { .opencode }

    /// `root` is the database file itself.
    public func discover(root: URL) throws -> [URL] {
        FileManager.default.fileExists(atPath: root.path) ? [root] : []
    }

    public func read(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let file = try FileSnapshot(of: handle)
        let journal = Journal(of: url)

        // `time_updated` has no index, so the query below reads the whole file. Something touches `-shm` every few seconds with no
        // new data, and a rescan comes here too. Every commit changes the database or its journal, so if neither did, nothing is new,
        // unless the last read left the journal out and it can be read now: `Journal` holds what decides that too.
        if let cursor, let last = Self.remembered(in: cursor), last.journal == journal,
           cursor.inode == file.inode, cursor.size == file.size, cursor.mtime == file.mtime {
            return ReadResult(events: [], quotas: [], cursor: cursor, skipped: 0)
        }

        // Where another file stopped says nothing about this one, whose rows may all be older.
        let remembered = cursor.flatMap { $0.inode == file.inode ? Self.remembered(in: $0) : nil }
        let since = cursor.flatMap { $0.inode == file.inode ? Self.lastSeen(in: $0) : nil } ?? 0
        let pass = try ReadOnlySQLite.open(url).read { db in
            var pass = Pass(since: since, answers: remembered?.answers)
            // `>=`, not `>`: a row can be committed after a read that stopped at its millisecond, and a row's last write has no later
            // one to bring it back. The row at the cursor comes back with every read, for the store to merge.
            let rows = try Row.fetchCursor(
                db,
                sql: "SELECT id, session_id, time_created, time_updated, data FROM message WHERE time_updated >= ?",
                arguments: [since]
            )
            while let row = try rows.next() {
                pass.consume(row)
            }
            return pass
        }
        let next = FileCursor(
            inode: file.inode,
            size: file.size,
            offset: file.size,
            mtime: file.mtime,
            state: try JSONEncoder().encode(Remembered(lastSeen: pass.lastSeen, journal: journal, answers: pass.answers))
        )
        return ReadResult(events: pass.events, quotas: [], cursor: next, skipped: pass.skipped)
    }

    /// What a read leaves in `FileCursor.state`, beside the database's own size and time in the cursor.
    private struct Remembered: Codable {
        var lastSeen: Int64
        /// nil when there was no journal.
        var journal: Journal?
        /// The answers since the last row with usage. nil with none, and in a cursor from before it.
        var answers: AnswersWithoutUsage?
    }

    /// The `-wal` beside the database. In WAL mode a commit lands here and leaves the database file alone.
    private struct Journal: Codable, Equatable {
        var size: Int64
        var mtime: Date
        /// nil in a cursor older than this, which then reads once more.
        var modes: Modes?

        /// What decides, beside the size, whether `ReadOnlySQLite` takes the journal in. These can change with no size or time moving,
        /// and rows a read left out would then stay hidden. Not `-shm`'s time: that moves every few seconds with no new data.
        struct Modes: Codable, Equatable {
            var database: mode_t?
            var journal: mode_t
            /// nil when there is no `-shm`.
            var memory: mode_t?
        }

        /// nil when there is none.
        init?(of database: URL) {
            var status = stat()
            guard stat(database.path + "-wal", &status) == 0 else { return nil }
            size = status.st_size
            mtime = Date(
                timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec) + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
            )
            modes = Modes(
                database: Self.mode(ofFileAt: database.path),
                journal: status.st_mode & 0o777,
                memory: Self.mode(ofFileAt: database.path + "-shm")
            )
        }

        private static func mode(ofFileAt path: String) -> mode_t? {
            var status = stat()
            return stat(path, &status) == 0 ? status.st_mode & 0o777 : nil
        }
    }

    private static func remembered(in cursor: FileCursor) -> Remembered? {
        cursor.state.flatMap { try? JSONDecoder().decode(Remembered.self, from: $0) }
    }

    /// The `time_updated` a read left in `cursor`; nil when the cursor has none, or one this reader cannot decode.
    /// Cursors from before `Remembered` hold the bare number.
    private static func lastSeen(in cursor: FileCursor) -> Int64? {
        remembered(in: cursor)?.lastSeen ?? cursor.state.flatMap { try? JSONDecoder().decode(Int64.self, from: $0) }
    }
}

/// One walk over the rows updated since the last read.
///
/// `data` is parsed here and not selected on in SQL: `json_extract` fails the whole query on one malformed row.
///
/// Every column is read as an optional, whatever the schema says. `NOT NULL` is enforced on writes, not on reads, so a read that
/// overlaps a checkpoint can meet a NULL anywhere, and GRDB crashes on a NULL read as a plain value. Such a row is skipped.
private struct Pass {
    /// The `time_updated` the last read stopped at, in epoch milliseconds.
    private let since: Int64
    /// The newest `time_updated` of any row, in epoch milliseconds.
    private(set) var lastSeen: Int64
    private(set) var events: [UsageEvent] = []
    private(set) var skipped = 0
    private(set) var answers: AnswersWithoutUsage?

    init(since: Int64, answers: AnswersWithoutUsage?) {
        self.since = since
        self.answers = answers
        lastSeen = since
    }

    mutating func consume(_ row: Row) {
        guard let updated = row["time_updated"] as Int64? else {
            skipped += 1
            return
        }
        lastSeen = max(lastSeen, updated)
        guard let data = row["data"] as Data?, let message = JSONObject(data) else {
            skip(updated)
            return
        }
        guard message.string("role") == "assistant", let time = message.date("time", "completed") else {
            // An answer, by its role or its model, that gives no usage: still being written, or a format that moved on.
            if message.string("role") == "assistant" || message.string("modelID") != nil {
                addAnswer(created: row["time_created"], updated: updated)
            }
            return
        }
        guard let id = present(row["id"]), let tokens = message.object("tokens"), Self.holdsCounts(tokens) else {
            skip(updated)
            return
        }
        // Usage where the reader looks for it: the format still holds, whatever answers came before.
        answers = nil
        events.append(UsageEvent(
            source: .opencode,
            dedupKey: "\(Source.opencode.rawValue):\(id)",
            sessionId: row["session_id"],
            project: message.string("path", "cwd"),
            provider: message.string("providerID"),
            model: message.string("modelID"),
            time: time,
            tokens: Self.counts(tokens)
        ))
    }

    /// Counts a row that cannot be read. The row at the cursor was counted by the read that stopped there.
    private mutating func skip(_ updated: Int64) {
        if updated > since { skipped += 1 }
    }

    /// An answer that gave no usage, counted once: when it is new since the last read. An unfinished one is written again as it goes
    /// on, in older builds after every step, and each of those writes is the same answer.
    private mutating func addAnswer(created: Int64?, updated: Int64) {
        guard (created ?? updated) > since else { return }
        var run = answers ?? AnswersWithoutUsage()
        skipped += run.add()
        answers = run
    }

    /// All five are in every message OpenCode writes, so one that is missing is a format that changed, not a figure of 0.
    private static func holdsCounts(_ tokens: JSONObject) -> Bool {
        guard let cache = tokens.object("cache") else { return false }
        return tokens.holdsCounts(required: ["input", "output", "reasoning"]) && cache.holdsCounts(required: ["read", "write"])
    }

    /// OpenCode's categories do not overlap, so reasoning is added to `output`, which in Tacho includes it.
    private static func counts(_ tokens: JSONObject) -> TokenCounts {
        let reasoning = tokens.int("reasoning") ?? 0
        return TokenCounts(
            input: tokens.int("input") ?? 0,
            output: (tokens.int("output") ?? 0) + reasoning,
            reasoning: reasoning,
            cacheRead: tokens.int("cache", "read") ?? 0,
            cacheWrite5m: tokens.int("cache", "write") ?? 0
        )
    }
}
