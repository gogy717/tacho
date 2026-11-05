import Foundation
import GRDB
import Testing
@testable import TachoKit

/// The comparison stays outside `#require`: with GRDB imported, Swift 6.1 reads `==` there as the SQL operator.
private func succeed(_ status: Int32) throws {
    let succeeded: Bool = status == 0
    try #require(succeeded)
}

struct OpenCodeReaderTests {
    private let reader = OpenCodeReader()

    /// OpenCode's `message` table, as `.schema message` prints it. The `session` table its foreign key names is left out:
    /// a reader that looked there would fail.
    private static let schema = """
        CREATE TABLE `message` (
                  `id` text PRIMARY KEY,
                  `session_id` text NOT NULL,
                  `time_created` integer NOT NULL,
                  `time_updated` integer NOT NULL,
                  `data` text NOT NULL,
                  CONSTRAINT `fk_message_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
                );
        CREATE INDEX `message_session_time_created_id_idx` ON `message` (`session_id`,`time_created`,`id`);
        """

    private static let finished = #"{"role":"assistant","providerID":"anthropic","modelID":"claude-haiku-5-5","path":{"cwd":"/p"},"time":{"created":1793474000000,"completed":1793474007189},"tokens":{"input":10,"output":100,"reasoning":50,"cache":{"read":1000,"write":20}}}"#
    private static let unfinished = #"{"role":"assistant","providerID":"anthropic","modelID":"claude-haiku-5-5","path":{"cwd":"/p"},"time":{"created":1793474000000},"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}"#

    /// A row of the `message` table.
    private struct MessageRow {
        var id = "m1"
        var updated = 100
        var data = OpenCodeReaderTests.finished
    }

    /// A connection that writes as OpenCode does. Foreign keys stay off: these databases have no `session` table.
    private func writer(at file: URL, wal: Bool = false) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        if wal { configuration.journalMode = .wal }
        return try DatabaseQueue(path: file.path, configuration: configuration)
    }

    /// Inserts `rows`, or rewrites them in place: OpenCode upserts a message by its id.
    private func upsert(_ rows: [MessageRow], with writer: DatabaseQueue) throws {
        try writer.write { db in
            for row in rows {
                try db.execute(
                    sql: """
                        INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, 's1', ?, ?, ?)
                        ON CONFLICT (id) DO UPDATE SET time_updated = excluded.time_updated, data = excluded.data
                        """,
                    arguments: [row.id, row.updated, row.updated, row.data]
                )
            }
        }
    }

    /// A database holding `rows`, with no connection left open.
    private func database(_ rows: [MessageRow], wal: Bool = false, name: String = "opencode.db") throws -> URL {
        let file = try makeTempDir().appendingPathComponent(name)
        let connection = try writer(at: file, wal: wal)
        try connection.write { try $0.execute(sql: Self.schema) }
        try upsert(rows, with: connection)
        try connection.close()
        return file
    }

    /// Rewrites `rows` of the database at `file`.
    private func rewrite(_ rows: [MessageRow], in file: URL) throws {
        let connection = try writer(at: file)
        try upsert(rows, with: connection)
        try connection.close()
    }

    /// A database whose journal holds pages and no process holds it, as OpenCode leaves one: `m1` is in the database file and
    /// `m2` only in the `-wal`.
    ///
    /// The three files are a copy taken while the writer was open. Reading next to a live writer of this process would prove
    /// nothing: connections of one process share a single `-shm` mapping, which `readonly_shm` does not apply to.
    private func journalledDatabase() throws -> URL {
        let live = try makeTempDir().appendingPathComponent("live.db")
        let connection = try writer(at: live, wal: true)
        try connection.write { try $0.execute(sql: Self.schema) }
        try upsert([MessageRow(id: "m1")], with: connection)
        _ = try connection.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        try upsert([MessageRow(id: "m2", updated: 200)], with: connection)

        let file = try makeTempDir().appendingPathComponent("opencode.db")
        for suffix in ["", "-wal", "-shm"] {
            try FileManager.default.copyItem(atPath: live.path + suffix, toPath: file.path + suffix)
        }
        try connection.close()
        return file
    }

    /// A cursor of `file` that has seen rows up to `updated`.
    private func cursor(after updated: Int, of file: URL) throws -> FileCursor {
        var status = stat()
        try succeed(stat(file.path, &status))
        return FileCursor(inode: UInt64(status.st_ino), size: 0, offset: 0, mtime: Date(timeIntervalSince1970: 0), state: Data(String(updated).utf8))
    }

    private func keys(_ result: ReadResult) -> [String] {
        result.events.map(\.dedupKey).sorted()
    }

    /// The stamp a read stopped at.
    private func lastSeen(_ result: ReadResult) -> Int64? {
        struct Remembered: Decodable { var lastSeen: Int64 }
        return result.cursor.state.flatMap { try? JSONDecoder().decode(Remembered.self, from: $0).lastSeen }
    }

    /// Replaces the file's bytes with rubbish of the same length and puts its modification time back to the nanosecond. It is
    /// the same file to a `stat`, and no database to SQLite: any query on it fails, which is how these tests see that none ran.
    private func spoil(_ file: URL) throws {
        var before = stat()
        try succeed(stat(file.path, &before))
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(repeating: 0x5A, count: Int(before.st_size)))
        try handle.close()
        var times = [before.st_atimespec, before.st_mtimespec]
        try succeed(utimensat(AT_FDCWD, file.path, &times, 0))
    }

    /// What a read must leave as it found it.
    private struct FileState: Equatable {
        var size: UInt64
        var mtime: Date?
        var mode: Int
        var content: Data

        init(of file: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path) as NSDictionary
            size = attributes.fileSize()
            mtime = attributes.fileModificationDate()
            mode = attributes.filePosixPermissions()
            content = try Data(contentsOf: file)
        }
    }

    /// Every file beside `file`, and itself: a new `-wal` or `-shm` shows up as a new name.
    private func directoryState(of file: URL) throws -> [String: FileState] {
        let directory = file.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return try Dictionary(uniqueKeysWithValues: names.map { ($0, try FileState(of: directory.appendingPathComponent($0))) })
    }

    private func chmod(_ mode: Int, _ path: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    @Test func outputIncludesReasoning() throws {
        let result = try reader.read(try database([MessageRow()]), from: nil)
        #expect(result.events.count == 1)
        let event = try #require(result.events.first)
        #expect(event.tokens == TokenCounts(input: 10, output: 150, reasoning: 50, cacheRead: 1_000, cacheWrite5m: 20))
        #expect(event.time == ms(1793474007189))
        #expect(event.generationMs == nil)
        #expect(event.startTime == nil)
    }

    @Test func attributesTheEventToItsRow() throws {
        let event = try #require(try reader.read(try database([MessageRow(id: "msg_1")]), from: nil).events.first)
        #expect(event.source == .opencode)
        #expect(event.dedupKey == "opencode:msg_1")
        #expect(event.sessionId == "s1")
        #expect(event.project == "/p")
        #expect(event.provider == "anthropic")
        #expect(event.model == "claude-haiku-5-5")
    }

    @Test func readsOnlyRowsUpdatedSinceTheCursor() throws {
        let file = try database([MessageRow(id: "m1", updated: 100), MessageRow(id: "m2", updated: 200)])
        let result = try reader.read(file, from: try cursor(after: 150, of: file))
        #expect(keys(result) == ["opencode:m2"])
        #expect(lastSeen(result) == 200)
    }

    /// An upsert keeps a row's place in the table, so the newest stamp is often not on the last row read.
    @Test func theCursorIsTheNewestStampOfAnyRow() throws {
        let file = try database([MessageRow(id: "m1", updated: 200), MessageRow(id: "m2", updated: 100)])
        #expect(lastSeen(try reader.read(file, from: nil)) == 200)
    }

    @Test func aReadWithNothingNewKeepsTheCursor() throws {
        let file = try database([MessageRow(id: "m1", updated: 100)])
        let result = try reader.read(file, from: try cursor(after: 300, of: file))
        #expect(result.events.isEmpty)
        #expect(lastSeen(result) == 300)
    }

    /// A row can be committed after the read that moved the cursor to its millisecond, so that millisecond is read again.
    @Test func aRowUpdatedAtTheCursorIsReadAgain() throws {
        let file = try database([MessageRow(id: "m1", updated: 100)])
        #expect(keys(try reader.read(file, from: try cursor(after: 100, of: file))) == ["opencode:m1"])
    }

    @Test func aSecondRowStampedLikeTheCursorIsRead() throws {
        let file = try database([MessageRow(id: "m1", updated: 100)])
        let first = try reader.read(file, from: nil)
        try rewrite([MessageRow(id: "m2", updated: 100)], in: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(keys(second) == ["opencode:m1", "opencode:m2"])
        #expect(lastSeen(second) == 100)
    }

    @Test func ignoresUserAndUnfinishedMessages() throws {
        let user = Self.finished.replacingOccurrences(of: "assistant", with: "user")
        let file = try database([MessageRow(id: "m1", data: user), MessageRow(id: "m2", data: Self.unfinished)])
        let result = try reader.read(file, from: nil)
        #expect(result.events.isEmpty)
        #expect(result.skipped == 0)
    }

    @Test func aRewrittenRowIsReadAgainUnderItsKey() throws {
        let file = try database([MessageRow(id: "m1", updated: 100)])
        let first = try reader.read(file, from: nil)
        try rewrite([MessageRow(id: "m1", updated: 300, data: Self.finished.replacingOccurrences(of: #""input":10"#, with: #""input":11"#))], in: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(keys(second) == ["opencode:m1"])
        #expect(second.events.first?.tokens.input == 11)
    }

    /// The write that finishes a message can land in the same millisecond as the one before it.
    @Test func aMessageFinishedInTheCursorsMillisecondIsRead() throws {
        let file = try database([MessageRow(id: "m1", updated: 200, data: Self.unfinished)])
        let first = try reader.read(file, from: nil)
        #expect(first.events.isEmpty)
        #expect(lastSeen(first) == 200)
        try rewrite([MessageRow(id: "m1", updated: 200)], in: file)
        #expect(keys(try reader.read(file, from: first.cursor)) == ["opencode:m1"])
    }

    @Test func aRowThatIsNotJSONIsSkippedOnce() throws {
        let file = try database([MessageRow(id: "m1", updated: 100), MessageRow(id: "m2", updated: 200, data: "{")])
        let first = try reader.read(file, from: nil)
        #expect(keys(first) == ["opencode:m1"])
        #expect(first.skipped == 1)
        #expect(try reader.read(file, from: first.cursor).skipped == 0)
    }

    /// `message` as a half-written page can read: `NOT NULL` is enforced on writes, not on reads, so these columns can be NULL
    /// in a read while only a table without it lets a test write that. `good` is a usable row placed after the bad one.
    private func databaseWithBadRow(id: String?, session: String?, updated: Int?, data: String?) throws -> URL {
        let file = try makeTempDir().appendingPathComponent("opencode.db")
        let connection = try writer(at: file)
        try connection.write { db in
            try db.execute(sql: "CREATE TABLE message (id text, session_id text, time_created integer, time_updated integer, data text)")
            try db.execute(sql: "INSERT INTO message VALUES (?, ?, 1, ?, ?)", arguments: [id, session, updated, data])
            try db.execute(sql: "INSERT INTO message VALUES ('good', 's1', 1, 100, ?)", arguments: [Self.finished])
        }
        try connection.close()
        return file
    }

    @Test func aRowWithNoDataIsSkippedOnce() throws {
        let file = try databaseWithBadRow(id: "bad", session: "s1", updated: 200, data: nil)
        let first = try reader.read(file, from: nil)
        #expect(keys(first) == ["opencode:good"])
        #expect(first.skipped == 1)
        #expect(try reader.read(file, from: first.cursor).skipped == 0)
    }

    @Test func aRowWithNoIdIsSkippedOnce() throws {
        let file = try databaseWithBadRow(id: nil, session: "s1", updated: 200, data: Self.finished)
        let first = try reader.read(file, from: nil)
        #expect(keys(first) == ["opencode:good"])
        #expect(first.skipped == 1)
        #expect(try reader.read(file, from: first.cursor).skipped == 0)
    }

    @Test func aRowWithNoSessionIsStillACall() throws {
        let file = try databaseWithBadRow(id: "m1", session: nil, updated: 200, data: Self.finished)
        let result = try reader.read(file, from: nil)
        #expect(keys(result) == ["opencode:good", "opencode:m1"])
        #expect(result.events.first { $0.dedupKey == "opencode:m1" }?.sessionId == nil)
    }

    /// A row with no stamp is not one the cursor can reach, so it is never selected.
    @Test func aRowWithNoStampIsLeftOut() throws {
        let file = try databaseWithBadRow(id: "m1", session: "s1", updated: nil, data: Self.finished)
        #expect(keys(try reader.read(file, from: nil)) == ["opencode:good"])
    }

    @Test func aFinishedMessageWithoutTokensIsSkippedOnce() throws {
        let data = #"{"role":"assistant","time":{"completed":1793474007189}}"#
        let file = try database([MessageRow(data: data)])
        let first = try reader.read(file, from: nil)
        #expect(first.events.isEmpty)
        #expect(first.skipped == 1)
        #expect(try reader.read(file, from: first.cursor).skipped == 0)
    }

    // MARK: Answers with no usage

    /// A finished call whose role went under another name, as a format that changed would bring it.
    private static let renamed = finished.replacingOccurrences(of: #""role":"assistant""#, with: #""author":"assistant""#)

    private func renamedRows(_ count: Int, from first: Int) -> [MessageRow] {
        (first..<first + count).map { MessageRow(id: "m\($0)", updated: 100 + $0, data: Self.renamed) }
    }

    /// A row that looks like an answer owes usage. A run of them longer than a healthy database has means the reader no longer finds
    /// it, and every row of the run is then skipped: the one sign of a renamed format (spec 3, 5.4, 7).
    @Test func aLongRunOfAnswersWithNoUsageIsSkipped() throws {
        #expect(try reader.read(try database(renamedRows(19, from: 0)), from: nil).skipped == 0)
        #expect(try reader.read(try database(renamedRows(20, from: 0)), from: nil).skipped == 20)
    }

    @Test func aRunGoesOnAcrossReads() throws {
        let file = try database(renamedRows(19, from: 0))
        let first = try reader.read(file, from: nil)
        #expect(first.skipped == 0)
        try rewrite(renamedRows(1, from: 600), in: file)
        #expect(try reader.read(file, from: first.cursor).skipped == 20)
    }

    @Test func aRowThatGivesUsageEndsTheRun() throws {
        let file = try database(renamedRows(19, from: 0))
        let first = try reader.read(file, from: nil)
        try rewrite([MessageRow(id: "done", updated: 500)], in: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(keys(second) == ["opencode:done"])
        try rewrite(renamedRows(19, from: 600), in: file)
        #expect(try reader.read(file, from: second.cursor).skipped == 0)
    }

    /// While a call streams, OpenCode can write its parts and leave its message as it is: the unfinished row then stays at the cursor
    /// and comes back with every read. It is one answer, however many reads see it.
    @Test func theRowAtTheCursorCountsOnce() throws {
        let file = try database([MessageRow(id: "m1", updated: 200, data: Self.unfinished)])
        var cursor = try reader.read(file, from: nil).cursor
        for part in 0..<25 {
            let connection = try writer(at: file)
            try connection.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS part (id integer)")
                try db.execute(sql: "INSERT INTO part VALUES (?)", arguments: [part])
            }
            try connection.close()
            let result = try reader.read(file, from: cursor)
            #expect(result.skipped == 0)
            cursor = result.cursor
        }
    }

    /// Older builds keep a turn's steps in one message and write it again after each step, with a new stamp each time. It is still
    /// one answer, however often it is written before it finishes.
    @Test func anAnswerWrittenStepByStepCountsOnce() throws {
        let file = try database([MessageRow(id: "m1", updated: 100, data: Self.unfinished)])
        var cursor = try reader.read(file, from: nil).cursor
        for step in 1...25 {
            try rewrite([MessageRow(id: "m1", updated: 100 + step, data: Self.unfinished)], in: file)
            let result = try reader.read(file, from: cursor)
            #expect(result.skipped == 0, "step \(step)")
            cursor = result.cursor
        }
    }

    // MARK: Figures that cannot be trusted

    /// A finished message whose `tokens` are `tokens`.
    private static func message(tokens: String) -> String {
        #"{"role":"assistant","providerID":"anthropic","modelID":"claude-haiku-5-5","path":{"cwd":"/p"},"time":{"created":1793474000000,"completed":1793474007189},"tokens":\#(tokens)}"#
    }

    /// Every one of these would read as a figure of 0, or trap once added up, with nothing to say so.
    @Test(arguments: [
        #"{"input":"10","output":100,"reasoning":50,"cache":{"read":1000,"write":20}}"#,
        #"{"input":10,"output":"100","reasoning":50,"cache":{"read":1000,"write":20}}"#,
        #"{"input":10,"output":100,"reasoning":"50","cache":{"read":1000,"write":20}}"#,
        #"{"input":10,"output":100.5,"reasoning":50,"cache":{"read":1000,"write":20}}"#,
        #"{"input":-1,"output":100,"reasoning":50,"cache":{"read":1000,"write":20}}"#,
        #"{"input":null,"output":100,"reasoning":50,"cache":{"read":1000,"write":20}}"#,
        #"{"input":10,"output":100,"reasoning":50,"cache":"x"}"#,
        #"{"input":10,"output":100,"reasoning":50,"cache":{"read":"1000","write":20}}"#,
        #"{"input":10,"output":100,"reasoning":50,"cache":{"read":1000,"write":null}}"#,
        #"{"inputTokens":10,"output":100,"reasoning":50,"cache":{"read":1000,"write":20}}"#,
        #"{"input":10,"output":100,"cache":{"read":1000,"write":20}}"#,
        #"{"input":10,"output":100,"reasoning":50}"#,
        #"{"input":10,"output":100,"reasoning":50,"cache":{"hit":1000,"write":20}}"#,
        #"{"input":1099511627777,"output":100,"reasoning":50,"cache":{"read":1000,"write":20}}"#,
        #"{"input":10,"output":100,"reasoning":50,"cache":{"read":9223372036854775807,"write":20}}"#,
    ])
    func aTokenFigureThatCannotBeTrustedIsSkippedOnce(tokens: String) throws {
        let file = try database([MessageRow(data: Self.message(tokens: tokens))])

        let first = try reader.read(file, from: nil)

        #expect(first.events.isEmpty)
        #expect(first.skipped == 1)
        #expect(try reader.read(file, from: first.cursor).skipped == 0)
    }

    /// The limit itself is still a count, and so is a call that used nothing.
    @Test(arguments: [
        #"{"input":1099511627776,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}"#,
        #"{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}"#,
    ])
    func aFigureInsideTheLimitIsRead(tokens: String) throws {
        let result = try reader.read(try database([MessageRow(data: Self.message(tokens: tokens))]), from: nil)

        #expect(result.events.count == 1)
        #expect(result.skipped == 0)
    }

    /// As a key it would merge every call that has it.
    @Test(arguments: ["", "   ", "\n"])
    func aBlankIdIsSkipped(id: String) throws {
        let file = try databaseWithBadRow(id: id, session: "s1", updated: 200, data: Self.finished)

        let result = try reader.read(file, from: nil)

        #expect(keys(result) == ["opencode:good"])
        #expect(result.skipped == 1)
    }

    // MARK: Nothing changed

    /// The column has no index, so a query reads the whole file, and something touches `-shm` every few seconds with nothing to read.
    @Test func anUnchangedDatabaseIsNotQueried() throws {
        let file = try database([MessageRow()])
        let first = try reader.read(file, from: nil)
        try spoil(file)

        let second = try reader.read(file, from: first.cursor)

        #expect(second.events.isEmpty)
        #expect(second.skipped == 0)
        #expect(second.cursor == first.cursor)
    }

    @Test func anUnchangedDatabaseWithAJournalIsNotQueried() throws {
        let file = try journalledDatabase()
        let first = try reader.read(file, from: nil)
        try spoil(file)

        let second = try reader.read(file, from: first.cursor)

        #expect(second.cursor == first.cursor)
    }

    /// In WAL mode a commit leaves the database file alone.
    @Test func aCommitThatLandsOnlyInTheJournalIsRead() throws {
        let file = try database([MessageRow(id: "m1", updated: 100)], wal: true)
        let open = try writer(at: file, wal: true)
        defer { try? open.close() }
        try upsert([MessageRow(id: "m2", updated: 150)], with: open)
        let first = try reader.read(file, from: nil)
        let databaseBefore = try FileState(of: file)

        try upsert([MessageRow(id: "m3", updated: 200)], with: open)
        try #require(try FileState(of: file) == databaseBefore)

        #expect(keys(try reader.read(file, from: first.cursor)).contains("opencode:m3"))
    }

    /// Without its `-shm` a journal is left out of a read. Its return moves no file's size or time, and only then can those rows be read.
    @Test func aJournalThatBecomesReadableIsRead() throws {
        let file = try journalledDatabase()
        let memory = URL(fileURLWithPath: file.path + "-shm")
        let kept = try Data(contentsOf: memory)
        try FileManager.default.removeItem(at: memory)
        let first = try reader.read(file, from: nil)
        try #require(keys(first) == ["opencode:m1"])

        try kept.write(to: memory)

        #expect(keys(try reader.read(file, from: first.cursor)).contains("opencode:m2"))
    }

    /// A journal whose mode differs from the database's is left out of a read too, and a change of mode moves no size or time.
    @Test(arguments: ["", "-wal", "-shm"])
    func aJournalLeftOutForItsModeIsReadWhenThatComesRight(suffix: String) throws {
        let file = try journalledDatabase()
        var status = stat()
        try succeed(stat(file.path + suffix, &status))
        let mode = Int(status.st_mode & 0o777)
        try chmod(mode ^ 0o040, file.path + suffix)
        let first = try reader.read(file, from: nil)
        try #require(keys(first) == ["opencode:m1"])

        try chmod(mode, file.path + suffix)

        #expect(keys(try reader.read(file, from: first.cursor)).contains("opencode:m2"))
    }

    /// Something touches `-shm` every few seconds with no new data, which is what the skip is there for.
    @Test func aTouchedMemoryFileIsNotAChange() throws {
        let file = try journalledDatabase()
        let first = try reader.read(file, from: nil)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
            ofItemAtPath: file.path + "-shm"
        )
        try spoil(file)

        #expect(try reader.read(file, from: first.cursor).events.isEmpty)
    }

    /// A cursor written before the stamp held modes reads once more, and keeps its place.
    @Test func aCursorWithoutModesQueriesAgainAndKeepsItsPlace() throws {
        let file = try journalledDatabase()
        let first = try reader.read(file, from: nil)
        let written = try #require(first.cursor.state)
        var state = try #require(JSONSerialization.jsonObject(with: written) as? [String: Any])
        var journal = try #require(state["journal"] as? [String: Any])
        try #require(journal.removeValue(forKey: "modes") != nil)
        state["journal"] = journal
        var older = first.cursor
        older.state = try JSONSerialization.data(withJSONObject: state)

        let second = try reader.read(file, from: older)

        #expect(keys(second) == ["opencode:m2"])
        #expect(lastSeen(second) == lastSeen(first))
    }

    /// A checkpoint moves pages into the database and empties the journal, so what was read may look smaller and is all still there.
    @Test func aCheckpointIsNoticed() throws {
        let file = try database([MessageRow(id: "m1", updated: 100)], wal: true)
        let open = try writer(at: file, wal: true)
        defer { try? open.close() }
        try upsert([MessageRow(id: "m2", updated: 150)], with: open)
        let first = try reader.read(file, from: nil)

        _ = try open.writeWithoutTransaction { try $0.checkpoint(.truncate) }

        let second = try reader.read(file, from: first.cursor)

        #expect(second.cursor != first.cursor)
    }

    /// The journal appearing, or going, is a change even if the database's own size and time stand still.
    @Test(arguments: [true, false])
    func aJournalComingOrGoingIsAChange(appears: Bool) throws {
        let file = try journalledDatabase()
        let journal = URL(fileURLWithPath: file.path + "-wal")
        let saved = try Data(contentsOf: journal)
        if appears { try FileManager.default.removeItem(at: journal) }
        let first = try reader.read(file, from: nil)

        if appears {
            try saved.write(to: journal)
        } else {
            try FileManager.default.removeItem(at: journal)
        }

        #expect(try reader.read(file, from: first.cursor).cursor != first.cursor)
    }

    @Test func aDatabaseOfAnotherSizeIsRead() throws {
        let file = try database([MessageRow()])
        let first = try reader.read(file, from: nil)
        var before = stat()
        try succeed(stat(file.path, &before))
        try append("\0", to: file)
        var times = [before.st_atimespec, before.st_mtimespec]
        try succeed(utimensat(AT_FDCWD, file.path, &times, 0))

        #expect(try reader.read(file, from: first.cursor).cursor != first.cursor)
    }

    /// One brought from another Mac: every row is older than where the last database stopped, and a read from there finds none.
    @Test func aReplacedDatabaseIsReadFromTheStart() throws {
        let file = try database([MessageRow(id: "m1", updated: 500)])
        let first = try reader.read(file, from: nil)
        let older = try database([MessageRow(id: "old1", updated: 100), MessageRow(id: "old2", updated: 200)])
        try succeed(rename(older.path, file.path))

        let second = try reader.read(file, from: first.cursor)

        #expect(keys(second) == ["opencode:old1", "opencode:old2"])
        // Not 500: a row this database gets at 300 would stay hidden behind where the last one stopped.
        #expect(lastSeen(second) == 200)
    }

    /// Another file at the same path is another database, however much it looks like the last one.
    @Test func aReplacedDatabaseIsRead() throws {
        let file = try database([MessageRow(id: "m1", updated: 100)])
        let first = try reader.read(file, from: nil)
        var before = stat()
        try succeed(stat(file.path, &before))
        let copy = file.appendingPathExtension("new")
        try FileManager.default.copyItem(at: file, to: copy)
        var times = [before.st_atimespec, before.st_mtimespec]
        try succeed(utimensat(AT_FDCWD, copy.path, &times, 0))
        try succeed(rename(copy.path, file.path))

        #expect(try reader.read(file, from: first.cursor).cursor != first.cursor)
    }

    @Test func aFirstReadAlwaysQueries() throws {
        let file = try database([MessageRow()])
        try spoil(file)
        #expect(throws: (any Error).self) { try reader.read(file, from: nil) }
    }

    /// A cursor from before this was remembered knows nothing of the journal, so it proves nothing.
    @Test func aCursorInTheOldFormatStillQueriesAndKeepsItsPlace() throws {
        let file = try database([MessageRow(id: "m1", updated: 100), MessageRow(id: "m2", updated: 200)])
        let first = try reader.read(file, from: nil)
        var old = first.cursor
        old.state = Data("150".utf8)

        let second = try reader.read(file, from: old)

        #expect(keys(second) == ["opencode:m2"])
        #expect(lastSeen(second) == 200)
    }

    @Test func aCursorWithUnreadableStateReadsEverything() throws {
        let file = try database([MessageRow()])
        var unreadable = try cursor(after: 0, of: file)
        unreadable.state = Data("{".utf8)
        #expect(keys(try reader.read(file, from: unreadable)) == ["opencode:m1"])
    }

    @Test func discoversTheDatabaseFile() throws {
        let file = try database([])
        #expect(try reader.discover(root: file) == [file])
    }

    @Test func discoversNothingWithoutTheFile() throws {
        let file = try makeTempDir().appendingPathComponent("opencode.db")
        #expect(try reader.discover(root: file).isEmpty)
    }

    @Test func readsAWalDatabaseReadOnly() throws {
        let file = try database([MessageRow()], wal: true)
        try chmod(0o444, file.path)
        let before = try directoryState(of: file)

        let result = try reader.read(file, from: nil)

        #expect(keys(result) == ["opencode:m1"])
        #expect(try directoryState(of: file) == before)
    }

    /// As after OpenCode has quit: an ordinary read-only connection would create both journal files.
    @Test func aMissingJournalIsNotCreated() throws {
        let file = try database([MessageRow()], wal: true)
        for suffix in ["-wal", "-shm"] {
            try FileManager.default.removeItem(atPath: file.path + suffix)
        }
        try chmod(0o444, file.path)
        let before = try directoryState(of: file)
        #expect(before.keys.sorted() == ["opencode.db"])

        let result = try reader.read(file, from: nil)

        #expect(keys(result) == ["opencode:m1"])
        #expect(try directoryState(of: file) == before)
    }

    @Test func readsPagesStillInTheJournalAndChangesNoFile() throws {
        let file = try journalledDatabase()
        let before = try directoryState(of: file)
        #expect(before.keys.sorted() == ["opencode.db", "opencode.db-shm", "opencode.db-wal"])

        let result = try reader.read(file, from: nil)

        #expect(keys(result) == ["opencode:m1", "opencode:m2"])
        #expect(try directoryState(of: file) == before)
    }

    /// With no `-shm` to read, a journal could only be read by creating one.
    @Test func aJournalWithoutItsShmIsLeftOut() throws {
        let file = try journalledDatabase()
        try FileManager.default.removeItem(atPath: file.path + "-shm")
        let before = try directoryState(of: file)

        let result = try reader.read(file, from: nil)

        #expect(keys(result) == ["opencode:m1"])
        #expect(try directoryState(of: file) == before)
    }

    /// OpenCode can empty its journal between the check and the open, and SQLite gives an empty file it opens the database's mode.
    @Test(arguments: ["-wal", "-shm"])
    func aJournalFileOfAnotherModeIsLeftOut(suffix: String) throws {
        let file = try journalledDatabase()
        try chmod(0o600, file.path + suffix)
        let before = try directoryState(of: file)

        let result = try reader.read(file, from: nil)

        #expect(keys(result) == ["opencode:m1"])
        #expect(try directoryState(of: file) == before)
    }

    @Test func anEmptyJournalChangesNoFile() throws {
        let file = try journalledDatabase()
        try Data().write(to: URL(fileURLWithPath: file.path + "-wal"))
        let before = try directoryState(of: file)

        let result = try reader.read(file, from: nil)

        #expect(keys(result) == ["opencode:m1"])
        #expect(try directoryState(of: file) == before)
    }

    @Test(arguments: ["with space.db", "hash#mark.db", "question?mark.db", "per%20cent.db"])
    func opensAPathThatAURINeedsEscaped(name: String) throws {
        let file = try database([MessageRow()], name: name)
        #expect(keys(try reader.read(file, from: nil)) == ["opencode:m1"])
    }

    @Test func waitsOneHundredMillisecondsOnALock() throws {
        let timeout = try ReadOnlySQLite.open(try journalledDatabase()).read { try Int.fetchOne($0, sql: "PRAGMA busy_timeout") }
        #expect(timeout == 100)
    }

    @Test(arguments: [false, true])
    func refusesToWrite(withJournal: Bool) throws {
        let file = withJournal ? try journalledDatabase() : try database([MessageRow()])
        let connection = try ReadOnlySQLite.open(file)
        #expect(throws: DatabaseError.self) {
            try connection.writeWithoutTransaction { try $0.execute(sql: "DELETE FROM message") }
        }
    }

    @Test func refusesAFileThatIsNotThere() throws {
        let file = try makeTempDir().appendingPathComponent("opencode.db")
        #expect(throws: (any Error).self) { try ReadOnlySQLite.open(file) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// SQLite gives an empty file it opens a mode of its own choosing, and there is no table to read in one anyway.
    @Test func refusesAnEmptyFile() throws {
        let file = try makeTempDir().appendingPathComponent("opencode.db")
        try Data().write(to: file)
        try chmod(0o600, file.path)
        let before = try directoryState(of: file)

        #expect(throws: (any Error).self) { try ReadOnlySQLite.open(file) }

        #expect(try directoryState(of: file) == before)
    }
}
