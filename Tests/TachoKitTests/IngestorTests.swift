import Foundation
import os
import Testing
@testable import TachoKit

private extension Data {
    func append(to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}

/// A reader that counts its walks.
private struct CountingDiscoveries: SourceReader {
    let base: any SourceReader
    private let walks = OSAllocatedUnfairLock(initialState: 0)

    init(base: any SourceReader) {
        self.base = base
    }

    var source: Source { base.source }
    var looks: Int { walks.withLock { $0 } }

    func discover(root: URL) throws -> [URL] {
        walks.withLock { $0 += 1 }
        return try base.discover(root: root)
    }

    func read(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        try base.read(url, from: cursor)
    }
}

/// A reader of the `.log` files in its root, or of the root itself when that is a file. It records what it reads, in order.
/// A read returns one event keyed by the file's name, and a cursor that follows the file's size, so an unchanged file gives the cursor it got.
private struct SpyReader: SourceReader {
    struct Unreadable: Error {}

    let source: Source
    /// What each read reports as skipped.
    var skipped = 0
    /// The time of the event a read returns.
    var eventTime = date("2026-11-03T09:00:00Z")
    private let log = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let broken = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private let discoveryFails = OSAllocatedUnfairLock(initialState: false)
    private let looks = OSAllocatedUnfairLock(initialState: 0)
    private let hook = OSAllocatedUnfairLock<(@Sendable (Int) -> Void)?>(initialState: nil)

    init(source: Source, skipped: Int = 0, eventTime: Date = date("2026-11-03T09:00:00Z")) {
        self.source = source
        self.skipped = skipped
        self.eventTime = eventTime
    }

    /// Runs `action` inside every read, on the actor that reads, with the number of reads so far.
    func onRead(_ action: @escaping @Sendable (Int) -> Void) {
        hook.withLock { $0 = action }
    }

    var reads: [String] { log.withLock { $0 } }

    /// How many times `discover` ran.
    var discoveries: Int { looks.withLock { $0 } }

    func forgetReads() { log.withLock { $0 = [] } }

    /// Reads of `name` throw until it is given back.
    func breakFile(_ name: String, _ isBroken: Bool = true) {
        broken.withLock { names in
            if isBroken {
                names.insert(name)
            } else {
                names.remove(name)
            }
        }
    }

    func breakDiscovery(_ fails: Bool = true) { discoveryFails.withLock { $0 = fails } }

    func discover(root: URL) throws -> [URL] {
        looks.withLock { $0 += 1 }
        if discoveryFails.withLock({ $0 }) { throw Unreadable() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [root] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "log" }
    }

    func read(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        let name = url.lastPathComponent
        let count = log.withLock { reads -> Int in
            reads.append(name)
            return reads.count
        }
        hook.withLock { $0 }?(count)
        if broken.withLock({ $0.contains(name) }) { throw Unreadable() }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        let event = UsageEvent(source: source, dedupKey: "\(source.rawValue):\(name)", time: eventTime, tokens: TokenCounts(output: 1))
        let next = FileCursor(inode: 1, size: size, offset: size, mtime: Date(timeIntervalSince1970: 0))
        return ReadResult(events: [event], quotas: [], cursor: next, skipped: skipped)
    }
}

/// What a test does from inside a read, which runs on the actor. A call made there is on the actor's queue before the read returns, so it
/// runs at that file's yield, at a known point of the backfill. A call made from outside would race the reads.
private extension Ingestor {
    nonisolated var progressInsideARead: IngestProgress {
        assumeIsolated { $0.progress }
    }

    // The job must not rank below the read's own task, which it has to run ahead of. A task's base priority can be lower than the one it
    // runs at, so it is stated.
    nonisolated func queueRebuildInsideARead() -> Task<Void, any Error> {
        assumeIsolated { ingestor in
            Task(priority: Task.currentPriority) { try await ingestor.rebuildIndex() }
        }
    }

    nonisolated func queueUpdateInsideARead(roots: SourceRoots, enabled: Set<Source>) -> Task<Void, Never> {
        assumeIsolated { ingestor in
            Task(priority: Task.currentPriority) { await ingestor.update(roots: roots, enabled: enabled) }
        }
    }
}

/// A reader that holds on to what it read before returning it: the moment a reset from outside the actor would do its damage,
/// with the read done and its cursor not yet stored.
private struct LingeringReader: SourceReader {
    let base: any SourceReader
    let delay: Double
    private let started = OSAllocatedUnfairLock(initialState: 0)

    init(base: any SourceReader, delay: Double) {
        self.base = base
        self.delay = delay
    }

    var source: Source { base.source }

    /// How many reads have got as far as holding on.
    var reads: Int { started.withLock { $0 } }

    func discover(root: URL) throws -> [URL] { try base.discover(root: root) }

    func read(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        let result = try base.read(url, from: cursor)
        started.withLock { $0 += 1 }
        Thread.sleep(forTimeInterval: delay)
        return result
    }
}

/// A reader that counts the reads that reach it, those that go on to fail included.
private struct CountingReader: SourceReader {
    let base: any SourceReader
    private let attempts = OSAllocatedUnfairLock(initialState: 0)

    init(base: any SourceReader) {
        self.base = base
    }

    var source: Source { base.source }

    var reads: Int { attempts.withLock { $0 } }

    func discover(root: URL) throws -> [URL] { try base.discover(root: root) }

    func read(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        attempts.withLock { $0 += 1 }
        return try base.read(url, from: cursor)
    }
}

struct IngestorTests {
    // MARK: Fixtures

    private func assistantLine(request: String, at time: String = "2026-11-03T09:00:00.000Z") -> String {
        #"{"type":"assistant","timestamp":"\#(time)","requestId":"\#(request)","sessionId":"s1","cwd":"/p","message":{"id":"m-\#(request)","role":"assistant","model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":5}}}"#
    }

    /// A Claude root holding one transcript with one response.
    private func claudeRoot() throws -> (root: URL, transcript: URL) {
        let root = try makeTempDir()
        let transcript = root.appendingPathComponent("projects/p/s.jsonl")
        try write([assistantLine(request: "r1")], to: transcript)
        return (root, transcript)
    }

    private func claudeIngestor(root: URL, store: EventStore) -> Ingestor {
        Ingestor(store: store, readers: [ClaudeCodeReader()], roots: SourceRoots(roots: [.claudeCode: [root.path]]), enabled: [.claudeCode])
    }

    private func logFile(_ name: String, in directory: URL, modified: Date? = nil) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try write(["x"], to: file)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }
        return file
    }

    private func spyIngestor(_ spy: SpyReader, root: URL, store: EventStore) -> Ingestor {
        Ingestor(store: store, readers: [spy], roots: SourceRoots(roots: [spy.source: [root.path]]), enabled: [spy.source], mayBeAFile: { _ in true })
    }

    private func status(_ source: Source, of ingestor: Ingestor) async throws -> SourceStatus {
        try #require(await ingestor.statuses().first { $0.source == source })
    }

    /// `path` as FSEvents reports it: the temporary directory's symlink resolved.
    private func asReported(_ path: String) -> String {
        path.hasPrefix("/var/") ? "/private" + path : path
    }

    /// Waits until `condition` holds, polling every 100 ms; false after `seconds`.
    private func eventually(within seconds: Double = 5, _ condition: () throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try condition()
    }

    // MARK: Backfill

    @Test func backfillReadsRecentFilesFirst() async throws {
        let now = date("2026-11-03T12:00:00Z")
        let root = try makeTempDir()
        _ = try logFile("one-day.log", in: root, modified: now.addingTimeInterval(-1 * 86_400))
        _ = try logFile("ten-days.log", in: root, modified: now.addingTimeInterval(-10 * 86_400))
        _ = try logFile("two-days.log", in: root, modified: now.addingTimeInterval(-2 * 86_400))
        let spy = SpyReader(source: .claudeCode)
        let ingestor = Ingestor(
            store: try .inMemory(), readers: [spy], roots: SourceRoots(roots: [.claudeCode: [root.path]]), enabled: [.claudeCode], now: { now }
        )

        #expect(await ingestor.progress == IngestProgress(phase: .idle, filesDone: 0, filesTotal: 0))
        await ingestor.backfill()
        #expect(spy.reads == ["one-day.log", "two-days.log", "ten-days.log"])
        #expect(await ingestor.progress == IngestProgress(phase: .live, filesDone: 3, filesTotal: 3))
    }

    @Test func historyIsReadNewestFirstToo() async throws {
        let now = date("2026-11-03T12:00:00Z")
        let root = try makeTempDir()
        _ = try logFile("old.log", in: root, modified: now.addingTimeInterval(-30 * 86_400))
        _ = try logFile("older.log", in: root, modified: now.addingTimeInterval(-40 * 86_400))
        _ = try logFile("recent.log", in: root, modified: now.addingTimeInterval(-6 * 86_400))
        _ = try logFile("just-past.log", in: root, modified: now.addingTimeInterval(-8 * 86_400))
        let spy = SpyReader(source: .claudeCode)
        let ingestor = Ingestor(
            store: try .inMemory(), readers: [spy], roots: SourceRoots(roots: [.claudeCode: [root.path]]), enabled: [.claudeCode], now: { now }
        )
        await ingestor.backfill()
        #expect(spy.reads == ["recent.log", "just-past.log", "old.log", "older.log"])
    }

    @Test func aBackfillWithNothingToReadIsLive() async throws {
        let ingestor = Ingestor(store: try .inMemory(), readers: Ingestor.defaultReaders(), roots: SourceRoots(roots: [:]), enabled: Set(Source.allCases))
        await ingestor.backfill()
        #expect(await ingestor.progress == IngestProgress(phase: .live, filesDone: 0, filesTotal: 0))
    }

    @Test func thePhaseChangesAtTheSevenDayLine() async throws {
        // Both phases read newest first, so the order of the reads does not show the line: only the phase does.
        let now = date("2026-11-03T12:00:00Z")
        let root = try makeTempDir()
        _ = try logFile("recent.log", in: root, modified: now.addingTimeInterval(-6 * 86_400))
        _ = try logFile("past-the-line.log", in: root, modified: now.addingTimeInterval(-8 * 86_400))
        _ = try logFile("old.log", in: root, modified: now.addingTimeInterval(-30 * 86_400))
        let spy = SpyReader(source: .claudeCode)
        let ingestor = Ingestor(
            store: try .inMemory(), readers: [spy], roots: SourceRoots(roots: [.claudeCode: [root.path]]), enabled: [.claudeCode], now: { now }
        )
        let seen = OSAllocatedUnfairLock<[IngestProgress]>(initialState: [])
        spy.onRead { _ in
            let progress = ingestor.progressInsideARead
            seen.withLock { $0.append(progress) }
        }
        await ingestor.backfill()
        #expect(seen.withLock { $0 } == [
            IngestProgress(phase: .recent, filesDone: 0, filesTotal: 3),
            IngestProgress(phase: .history, filesDone: 1, filesTotal: 3),
            IngestProgress(phase: .history, filesDone: 2, filesTotal: 3),
        ])
    }

    @Test func aSourceSwitchedOffDuringABackfillIsNotReadFurther() async throws {
        let root = try makeTempDir()
        for index in 0..<10 {
            _ = try logFile("\(index).log", in: root)
        }
        let spy = SpyReader(source: .claudeCode)
        let roots = SourceRoots(roots: [.claudeCode: [root.path]])
        let ingestor = Ingestor(store: try .inMemory(), readers: [spy], roots: roots, enabled: [.claudeCode])
        let update = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
        spy.onRead { count in
            guard count == 3 else { return }
            let queued = ingestor.queueUpdateInsideARead(roots: roots, enabled: [])
            update.withLock { $0 = queued }
        }
        await ingestor.backfill()
        await update.withLock { $0 }?.value
        #expect(spy.reads.count == 3)
    }

    // MARK: Rebuilding

    @Test func aRebuildForgetsEverythingAndReadsWhatIsThere() async throws {
        let (root, transcript) = try claudeRoot()
        let other = root.appendingPathComponent("projects/p/gone.jsonl")
        try write([assistantLine(request: "r2")], to: other)
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)
        await ingestor.backfill()
        #expect(try store.eventCount(source: .claudeCode) == 2)

        try FileManager.default.removeItem(at: other)
        try await ingestor.rebuildIndex()
        #expect(try store.eventCount(source: .claudeCode) == 1)
        #expect(try store.cursorKeys().count == 1)
        #expect(try store.cursorKeys().first?.hasSuffix(transcript.lastPathComponent) == true)
        #expect(await ingestor.progress == IngestProgress(phase: .live, filesDone: 1, filesTotal: 1))
    }

    @Test func aRebuildKeepsTheQuotaSnapshots() async throws {
        let root = try makeTempDir()
        let log = root.appendingPathComponent("logs/unified.jsonl")
        let line = #"{"ts":"2026-10-30T10:00:00.000Z","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":16.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-11-01T07:31:55.424Z"}}}}"#
        try write([line], to: log)
        let store = try EventStore.inMemory()
        let ingestor = Ingestor(store: store, readers: [GrokReader()], roots: SourceRoots(roots: [.grok: [root.path]]), enabled: [.grok])
        await ingestor.backfill()

        try FileManager.default.removeItem(at: log)
        try await ingestor.rebuildIndex()
        #expect(try store.latestSnapshots().map(\.usedPercent) == [16])
    }

    @Test func aRebuildStartsTheSkipCountsOver() async throws {
        let (root, transcript) = try claudeRoot()
        let ingestor = claudeIngestor(root: root, store: try .inMemory())
        try append(#"{"usage":"# + "\n", to: transcript)
        await ingestor.backfill()
        #expect(try await status(.claudeCode, of: ingestor).skipped == 1)

        // A file that is gone by the time of the rebuild is not read again, so only the reset can forget its count.
        try FileManager.default.removeItem(at: transcript)
        try await ingestor.rebuildIndex()
        #expect(try await status(.claudeCode, of: ingestor).skipped == 0)
    }

    @Test func aRebuildForgetsAFileThatCouldNotBeReadAndCountsItAgainIfItStillCannot() async throws {
        let root = try makeTempDir()
        _ = try logFile("bad.log", in: root)
        let spy = SpyReader(source: .codex)
        spy.breakFile("bad.log")
        let ingestor = spyIngestor(spy, root: root, store: try .inMemory())
        await ingestor.backfill()
        try await ingestor.rebuildIndex()
        #expect(try await status(.codex, of: ingestor).skipped == 1)

        spy.breakFile("bad.log", false)
        try await ingestor.rebuildIndex()
        #expect(try await status(.codex, of: ingestor).skipped == 0)
    }

    @Test func aRebuildForgetsAFileThatCouldNotBeReadAndIsGone() async throws {
        let root = try makeTempDir()
        let file = try logFile("bad.log", in: root)
        let spy = SpyReader(source: .codex)
        spy.breakFile("bad.log")
        let ingestor = spyIngestor(spy, root: root, store: try .inMemory())
        await ingestor.backfill()
        #expect(try await status(.codex, of: ingestor).skipped == 1)

        try FileManager.default.removeItem(at: file)
        try await ingestor.rebuildIndex()
        #expect(try await status(.codex, of: ingestor).skipped == 0)
    }

    @Test func aReadInFlightDuringARebuildLeavesNoStaleCursor() async throws {
        let (root, transcript) = try claudeRoot()
        let store = try EventStore.inMemory()
        let reader = LingeringReader(base: ClaudeCodeReader(), delay: 0.3)
        let ingestor = Ingestor(store: store, readers: [reader], roots: SourceRoots(roots: [.claudeCode: [root.path]]), enabled: [.claudeCode])
        await ingestor.backfill()

        // The read goes on from the first line. A reset while it holds its result would leave a cursor past a line nobody has any more.
        try append(assistantLine(request: "r2") + "\n", to: transcript)
        let before = reader.reads
        let inFlight = Task { await ingestor.ingest(paths: [transcript.path]) }
        #expect(try await eventually { reader.reads > before })
        try await ingestor.rebuildIndex()
        await inFlight.value

        #expect(try store.eventCount(source: .claudeCode) == 2)
    }

    /// A backfill of `files` files with a rebuild queued inside read number `at`, and the phase every read saw.
    private func backfill(files: Int, rebuildingAtRead at: Int) async throws -> (spy: SpyReader, ingestor: Ingestor, store: EventStore, phases: [IngestProgress.Phase]) {
        let root = try makeTempDir()
        for index in 0..<files {
            _ = try logFile("\(index).log", in: root)
        }
        let spy = SpyReader(source: .claudeCode)
        let store = try EventStore.inMemory()
        let ingestor = spyIngestor(spy, root: root, store: store)
        let rebuild = OSAllocatedUnfairLock<Task<Void, any Error>?>(initialState: nil)
        let phases = OSAllocatedUnfairLock<[IngestProgress.Phase]>(initialState: [])
        spy.onRead { count in
            let phase = ingestor.progressInsideARead.phase
            phases.withLock { $0.append(phase) }
            guard count == at else { return }
            let queued = ingestor.queueRebuildInsideARead()
            rebuild.withLock { $0 = queued }
        }
        await ingestor.backfill()
        try await rebuild.withLock { $0 }?.value
        return (spy, ingestor, store, phases.withLock { $0 })
    }

    @Test func aRebuildDuringABackfillIsLiveOnlyWhenItIsDone() async throws {
        let run = try await backfill(files: 30, rebuildingAtRead: 3)
        #expect(!run.phases.contains(.live))
        #expect(await run.ingestor.progress == IngestProgress(phase: .live, filesDone: 30, filesTotal: 30))
    }

    @Test func aBackfillOvertakenDuringItsLastFileSetsNoPhase() async throws {
        // The old run has no file left to stop at, so it can only tell from the count that it was overtaken.
        let run = try await backfill(files: 3, rebuildingAtRead: 3)
        #expect(run.spy.reads.count == 6)
        #expect(!run.phases.contains(.live))
        #expect(await run.ingestor.progress == IngestProgress(phase: .live, filesDone: 3, filesTotal: 3))
    }

    @Test func aBackfillOvertakenByANewerOneStops() async throws {
        // All of the newest run, and only the three files of the old one.
        let run = try await backfill(files: 30, rebuildingAtRead: 3)
        #expect(run.spy.reads.count == 33)
        #expect(try run.store.eventCount(source: .claudeCode) == 30)
    }

    // MARK: Reading on

    @Test func appendedLinesAreIngestedOnce() async throws {
        let (root, transcript) = try claudeRoot()
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)

        await ingestor.backfill()
        #expect(try store.eventCount(source: .claudeCode) == 1)

        try append(assistantLine(request: "r2") + "\n", to: transcript)
        await ingestor.ingest(paths: [transcript.path])
        #expect(try store.eventCount(source: .claudeCode) == 2)

        await ingestor.ingest(paths: [transcript.path])
        #expect(try store.eventCount(source: .claudeCode) == 2)
    }

    @Test func aCursorIsKeyedBySourceAndPath() async throws {
        let (root, _) = try claudeRoot()
        let store = try EventStore.inMemory()
        await claudeIngestor(root: root, store: store).backfill()
        let key = try #require(try store.cursorKeys().first)
        #expect(try store.cursorKeys().count == 1)
        #expect(key.hasPrefix("claudeCode:/"))
        #expect(key.hasSuffix("/projects/p/s.jsonl"))
    }

    @Test func quotasReachTheStore() async throws {
        let root = try makeTempDir()
        let line = #"{"ts":"2026-10-30T10:00:00.000Z","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":16.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-11-01T07:31:55.424Z"}}}}"#
        try write([line], to: root.appendingPathComponent("logs/unified.jsonl"))
        let store = try EventStore.inMemory()
        let ingestor = Ingestor(store: store, readers: [GrokReader()], roots: SourceRoots(roots: [.grok: [root.path]]), enabled: [.grok])
        await ingestor.backfill()
        #expect(try store.latestSnapshots().map(\.usedPercent) == [16])
    }

    @Test func ingestFindsAFileThroughTheSymlinkFSEventsResolves() async throws {
        let (root, transcript) = try claudeRoot()
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)
        await ingestor.backfill()

        try append(assistantLine(request: "r2") + "\n", to: transcript)
        await ingestor.ingest(paths: [asReported(transcript.path)])
        #expect(try store.eventCount(source: .claudeCode) == 2)
        #expect(try store.cursorKeys().count == 1)
    }

    @Test func ingestFindsAFileUnderARootGivenThroughASymlink() async throws {
        let (root, transcript) = try claudeRoot()
        let alias = try makeTempDir().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: alias, store: store)
        await ingestor.backfill()
        #expect(try store.eventCount(source: .claudeCode) == 1)

        try append(assistantLine(request: "r2") + "\n", to: transcript)
        await ingestor.ingest(paths: [asReported(transcript.path)])
        #expect(try store.eventCount(source: .claudeCode) == 2)
    }

    @Test func ingestPicksUpAFileItHasNotSeen() async throws {
        let (root, _) = try claudeRoot()
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)
        await ingestor.backfill()

        let newcomer = root.appendingPathComponent("projects/p/new.jsonl")
        try write([assistantLine(request: "r2")], to: newcomer)
        await ingestor.ingest(paths: [newcomer.path])
        #expect(try store.eventCount(source: .claudeCode) == 2)
    }

    @Test func ingestLeavesAloneWhatIsNotAFileOfASource() async throws {
        let root = try makeTempDir()
        let file = try logFile("a.log", in: root)
        let notALog = try logFile("a.txt", in: root)
        let spy = SpyReader(source: .claudeCode)
        let ingestor = spyIngestor(spy, root: root, store: try .inMemory())
        await ingestor.backfill()
        spy.forgetReads()

        await ingestor.ingest(paths: [notALog.path, "/somewhere/else/a.log", root.path])
        #expect(spy.reads.isEmpty)
        #expect(try await status(.claudeCode, of: ingestor).skipped == 0)

        try append("more\n", to: file)
        await ingestor.ingest(paths: [file.path, file.path])
        #expect(spy.reads == ["a.log"])
    }

    /// A session saving through a temporary file makes a new name each time, and each new name cost a walk of every root: about 50 a
    /// minute on the real machine, over half of all the app's CPU, for files no reader could want.
    @Test(arguments: ["usage.json.tmp", "s.jsonl.tmp", "state.json", "worktrees.db-wal", "history.lock", "no-extension"])
    func aNameNoReaderTakesCostsNoLook(name: String) async throws {
        let (root, _) = try claudeRoot()
        let reader = CountingDiscoveries(base: ClaudeCodeReader())
        let ingestor = Ingestor(store: try .inMemory(), readers: [reader], roots: SourceRoots(roots: [.claudeCode: [root.path]]), enabled: [.claudeCode])
        await ingestor.backfill()
        let before = reader.looks
        let file = root.appendingPathComponent("projects/p/\(name)")
        try Data("x".utf8).write(to: file)
        await ingestor.ingest(paths: [file.path])
        #expect(reader.looks == before)
    }

    /// The other side of it: a new transcript is found as it appears, not at the next rescan.
    @Test func aNewTranscriptStillCostsItsLook() async throws {
        let (root, _) = try claudeRoot()
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)
        await ingestor.backfill()
        let fresh = root.appendingPathComponent("projects/p/new.jsonl")
        try write([assistantLine(request: "r2")], to: fresh)
        await ingestor.ingest(paths: [fresh.path])
        #expect(try store.eventCount(source: .claudeCode) == 2)
    }

    /// What makes it safe: every reader's own rule, on a tree with the names it does take and the ones it does not.
    @Test func noReaderTakesANameTheRuleLeavesOut() throws {
        let root = try makeTempDir()
        let taken = [
            "projects/p/s.jsonl", "sessions/2026/11/05/rollout-1.jsonl", "sessions/2026/11/05/rollout-2.jsonl.zst", "archived_sessions/a.jsonl",
            "agent/sessions/p/s.jsonl", "session-state/s/events.jsonl", "sessions/a/b/usage.json", "logs/unified.jsonl",
        ]
        let left = taken.map { $0 + ".tmp" } + ["projects/p/s.json", "sessions/a/b/state.json", "agent/sessions/p/s.txt", "logs/other.log"]
        for place in taken + left {
            let file = root.appendingPathComponent(place)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }
        var found: [String] = []
        for reader in Ingestor.defaultReaders() where reader.source != .opencode {
            found += try reader.discover(root: root).map(\.path)
        }
        #expect(!found.isEmpty)
        #expect(found.allSatisfy(Ingestor.mayBeSourceFile), "\(found.filter { !Ingestor.mayBeSourceFile($0) })")
    }

    /// OpenCode's root is any file the person names, and it is known by being the root.
    @Test func aDatabaseThatAppearsCostsItsLook() async throws {
        let directory = try makeTempDir()
        let database = directory.appendingPathComponent("opencode.db")
        let spy = SpyReader(source: .opencode)
        let ingestor = spyIngestor(spy, root: database, store: try .inMemory())
        await ingestor.backfill()
        try Data("x".utf8).write(to: database)
        await ingestor.ingest(paths: [asReported(database.path)])
        #expect(spy.reads == ["opencode.db"])
    }

    @Test func aPathOfNoSourceCostsOneLookUntilTheNextRescan() async throws {
        let root = try makeTempDir()
        let elsewhere = try makeTempDir()
        _ = try logFile("a.log", in: root)
        let stranger = try logFile("a.txt", in: root)
        let disabled = try logFile("b.log", in: elsewhere)
        let spy = SpyReader(source: .claudeCode)
        let ingestor = Ingestor(
            store: try .inMemory(), readers: [spy], roots: SourceRoots(roots: [.claudeCode: [root.path], .codex: [elsewhere.path]]), enabled: [.claudeCode],
            mayBeAFile: { _ in true }
        )
        await ingestor.backfill()
        let afterBackfill = spy.discoveries

        await ingestor.ingest(paths: [stranger.path])
        #expect(spy.discoveries == afterBackfill + 1)
        await ingestor.ingest(paths: [stranger.path])
        #expect(spy.discoveries == afterBackfill + 1)

        // Outside every root of an enabled source there is nothing to look for.
        await ingestor.ingest(paths: ["/somewhere/else/x.log", disabled.path])
        #expect(spy.discoveries == afterBackfill + 1)

        await ingestor.rescan()
        await ingestor.ingest(paths: [stranger.path])
        #expect(spy.discoveries == afterBackfill + 3)
    }

    @Test func aFileDeletedBeforeItsEventArrivesIsNoError() async throws {
        let (root, transcript) = try claudeRoot()
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)
        await ingestor.backfill()

        // As FSEvents reports it: a path that is gone can no longer be resolved, so this is the form that reaches the file.
        try FileManager.default.removeItem(at: transcript)
        await ingestor.ingest(paths: [asReported(transcript.path)])
        #expect(try await status(.claudeCode, of: ingestor).skipped == 0)
    }

    // MARK: A database root

    @Test func aDatabaseIsReadForItsSidecarsAndNothingElseBesideIt() async throws {
        let directory = try makeTempDir()
        let database = try logFile("opencode.db", in: directory)
        let wal = try logFile("opencode.db-wal", in: directory)
        let shm = try logFile("opencode.db-shm", in: directory)
        let neighbour = try logFile("other.log", in: directory)
        let spy = SpyReader(source: .opencode)
        let ingestor = spyIngestor(spy, root: database, store: try .inMemory())
        await ingestor.backfill()
        #expect(spy.reads == ["opencode.db"])
        spy.forgetReads()

        await ingestor.ingest(paths: [wal.path, shm.path])
        #expect(spy.reads == ["opencode.db"])
        spy.forgetReads()

        await ingestor.ingest(paths: [neighbour.path])
        #expect(spy.reads.isEmpty)
    }

    // MARK: Rescans

    @Test func deletedFilesKeepTheirEvents() async throws {
        let (root, transcript) = try claudeRoot()
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)
        await ingestor.backfill()
        #expect(try store.cursorKeys().count == 1)

        try FileManager.default.removeItem(at: transcript)
        await ingestor.rescan()
        #expect(try store.eventCount(source: nil) == 1)
        #expect(try store.cursorKeys().isEmpty)
    }

    @Test func rescanReadsNewFiles() async throws {
        let (root, _) = try claudeRoot()
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)
        await ingestor.backfill()

        try write([assistantLine(request: "r2")], to: root.appendingPathComponent("projects/q/new.jsonl"))
        await ingestor.rescan()
        #expect(try store.eventCount(source: .claudeCode) == 2)
        #expect(try await status(.claudeCode, of: ingestor).files == 2)
    }

    @Test func rescanCatchesAnAppendTheWatcherMissed() async throws {
        let (root, transcript) = try claudeRoot()
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)
        await ingestor.backfill()

        try append(assistantLine(request: "r2") + "\n", to: transcript)
        await ingestor.rescan()
        #expect(try store.eventCount(source: .claudeCode) == 2)
    }

    // MARK: A file with nothing new

    private func unchanged() throws -> (spy: SpyReader, file: URL, ingestor: Ingestor, directory: URL) {
        let directory = try makeTempDir()
        let file = try logFile("a.log", in: directory)
        let spy = SpyReader(source: .claudeCode)
        return (spy, file, spyIngestor(spy, root: directory, store: try .inMemory()), directory)
    }

    /// Most of a rescan: every file, each minute, for a look in the store and an `open` that find nothing.
    @Test func aFileThatHasNotChangedIsNotReadAgain() async throws {
        let (spy, _, ingestor, _) = try unchanged()
        await ingestor.backfill()
        spy.forgetReads()
        await ingestor.rescan()
        await ingestor.rescan()
        #expect(spy.reads.isEmpty)
    }

    @Test func aFileThatHasNotChangedIsNotReadForAnEvent() async throws {
        let (spy, file, ingestor, _) = try unchanged()
        await ingestor.backfill()
        spy.forgetReads()
        await ingestor.ingest(paths: [asReported(file.path)])
        #expect(spy.reads.isEmpty)
    }

    @Test func aFileThatGrewIsRead() async throws {
        let (spy, file, ingestor, _) = try unchanged()
        await ingestor.backfill()
        spy.forgetReads()
        try append("more\n", to: file)
        await ingestor.rescan()
        #expect(spy.reads == ["a.log"])
    }

    /// Its inode, its size and its time all say nothing has happened, as after a tool that keeps a file's time to the nanosecond. The
    /// time of the last change to the file itself, which no one can set, is what says otherwise. Written in place, as a new file would
    /// have another inode.
    @Test func newBytesAtTheSameSizeAndTimeAreRead() async throws {
        let (spy, file, ingestor, _) = try unchanged()
        await ingestor.backfill()
        var before = stat()
        #expect(stat(file.path, &before) == 0)
        spy.forgetReads()
        try await Task.sleep(for: .milliseconds(20))
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("y".utf8))
        try handle.close()
        let times = [before.st_atimespec, before.st_mtimespec]
        #expect(utimensat(AT_FDCWD, file.path, times, 0) == 0)
        await ingestor.rescan()
        #expect(spy.reads == ["a.log"])
    }

    /// Another file now, though it looks the same from outside.
    @Test func aFileSwappedForAnotherAtTheSameSizeAndTimeIsRead() async throws {
        let (spy, file, ingestor, directory) = try unchanged()
        await ingestor.backfill()
        let modified = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        let other = directory.appendingPathComponent("a.tmp")
        try write(["y"], to: other)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: other.path)
        spy.forgetReads()
        _ = rename(other.path, file.path)
        await ingestor.rescan()
        #expect(spy.reads == ["a.log"])
    }

    /// A reader goes by what the link points at, so this must too.
    @Test func aLinkPointedAtAnotherFileIsRead() async throws {
        let targets = try makeTempDir()
        let first = try logFile("first", in: targets)
        let second = try logFile("second", in: targets)
        let directory = try makeTempDir()
        let link = directory.appendingPathComponent("a.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let spy = SpyReader(source: .claudeCode)
        let ingestor = spyIngestor(spy, root: directory, store: try .inMemory())
        await ingestor.backfill()
        spy.forgetReads()
        await ingestor.rescan()
        // Resolved, the path is the target's: a file of its own, new to the store.
        #expect(spy.reads.isEmpty)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        await ingestor.rescan()
        #expect(spy.reads.count == 1)
    }

    /// The one race: what is known of a file must be from before its read, or a write during it would be passed over for good.
    @Test func aWriteDuringAReadIsReadNextTime() async throws {
        let (spy, file, ingestor, _) = try unchanged()
        spy.onRead { count in
            if count == 1 { try? "more\n".data(using: .utf8)?.append(to: file) }
        }
        await ingestor.backfill()
        spy.forgetReads()
        await ingestor.rescan()
        #expect(spy.reads == ["a.log"])
    }

    /// What goes wrong at a read is what a read may put right.
    @Test func aFileThatCouldNotBeReadIsTriedAgainThoughItHasNotChanged() async throws {
        let (spy, _, ingestor, _) = try unchanged()
        spy.breakFile("a.log")
        await ingestor.backfill()
        spy.breakFile("a.log", false)
        spy.forgetReads()
        await ingestor.rescan()
        #expect(spy.reads == ["a.log"])
        spy.forgetReads()
        await ingestor.rescan()
        #expect(spy.reads.isEmpty)
    }

    /// The bad read came on a file already read, so what was known of it must not stand.
    @Test func aFailureForgetsTheLastGoodRead() async throws {
        let (spy, file, ingestor, _) = try unchanged()
        await ingestor.backfill()
        try append("more\n", to: file)
        spy.breakFile("a.log")
        await ingestor.rescan()
        spy.breakFile("a.log", false)
        spy.forgetReads()
        await ingestor.rescan()
        #expect(spy.reads == ["a.log"])
    }

    /// Its cursor went with it, so what comes back is read from its start, though it is the same file.
    @Test func aFileThatGoesAndComesBackIsRead() async throws {
        let (spy, file, ingestor, directory) = try unchanged()
        await ingestor.backfill()
        let away = try makeTempDir().appendingPathComponent("a.log")
        try FileManager.default.moveItem(at: file, to: away)
        await ingestor.rescan()
        try FileManager.default.moveItem(at: away, to: file)
        spy.forgetReads()
        await ingestor.rescan()
        #expect(spy.reads == ["a.log"])
        _ = directory
    }

    /// Moving what holds a file leaves the file's own stamp as it was, so only having seen it go can say that its cursor went.
    @Test func aFileWhoseDirectoryGoesAndComesBackIsRead() async throws {
        let parent = try makeTempDir()
        let directory = parent.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try logFile("a.log", in: directory)
        let spy = SpyReader(source: .claudeCode)
        let ingestor = spyIngestor(spy, root: directory, store: try .inMemory())
        await ingestor.backfill()
        let away = parent.appendingPathComponent("away")
        try FileManager.default.moveItem(at: directory, to: away)
        await ingestor.rescan()
        try FileManager.default.moveItem(at: away, to: directory)
        spy.forgetReads()
        await ingestor.rescan()
        #expect(spy.reads == ["a.log"])
    }

    @Test func aRebuildReadsWhatHasNotChanged() async throws {
        let (spy, _, ingestor, _) = try unchanged()
        await ingestor.backfill()
        spy.forgetReads()
        try await ingestor.rebuildIndex()
        #expect(spy.reads == ["a.log"])
    }

    /// OpenCode's writes land in its `-wal`, which leaves the database as it was. Its reader has its own way of telling.
    @Test func aDatabaseIsReadThoughItHasNotChanged() async throws {
        let directory = try makeTempDir()
        let database = try logFile("opencode.db", in: directory)
        let spy = SpyReader(source: .opencode)
        let ingestor = spyIngestor(spy, root: database, store: try .inMemory())
        await ingestor.backfill()
        spy.forgetReads()
        await ingestor.rescan()
        #expect(spy.reads == ["opencode.db"])
    }

    @Test func aSourceSwitchedOffAndOnAgainReadsWhatChangedMeanwhile() async throws {
        let (spy, file, ingestor, directory) = try unchanged()
        let roots = SourceRoots(roots: [spy.source: [directory.path]])
        await ingestor.backfill()
        await ingestor.update(roots: roots, enabled: [])
        try append("more\n", to: file)
        spy.forgetReads()
        await ingestor.update(roots: roots, enabled: [spy.source])
        #expect(spy.reads == ["a.log"])
    }

    @Test func rescanForgetsNoCursorOfAFileThatStillExists() async throws {
        let (root, _) = try claudeRoot()
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)
        await ingestor.backfill()

        // The source is switched off: its files are not read, and their place in them is kept for when it is back.
        await ingestor.update(roots: SourceRoots(roots: [.claudeCode: [root.path]]), enabled: [])
        await ingestor.rescan()
        #expect(try store.cursorKeys().count == 1)
    }

    // MARK: Sources

    @Test func missingRootIsNotDetected() async throws {
        let (root, _) = try claudeRoot()
        let missing = try makeTempDir().appendingPathComponent("not-here").path
        let store = try EventStore.inMemory()
        let ingestor = Ingestor(
            store: store, readers: Ingestor.defaultReaders(),
            roots: SourceRoots(roots: [.claudeCode: [root.path], .codex: [missing]]), enabled: Set(Source.allCases)
        )
        await ingestor.backfill()

        let codex = try await status(.codex, of: ingestor)
        #expect(codex.detected == false)
        #expect(codex.roots == [missing])
        #expect(codex.files == 0)
        #expect(codex.skipped == 0)

        let claude = try await status(.claudeCode, of: ingestor)
        #expect(claude.detected)
        #expect(claude.events == 1)
        #expect(claude.files == 1)
    }

    @Test func disabledSourcesAreNotRead() async throws {
        let on = try makeTempDir()
        let off = try makeTempDir()
        let reported = try logFile("a.log", in: on)
        let silent = try logFile("b.log", in: off)
        let wanted = SpyReader(source: .claudeCode)
        let unwanted = SpyReader(source: .codex)
        let ingestor = Ingestor(
            store: try .inMemory(), readers: [wanted, unwanted],
            roots: SourceRoots(roots: [.claudeCode: [on.path], .codex: [off.path]]), enabled: [.claudeCode]
        )
        await ingestor.backfill()
        await ingestor.ingest(paths: [reported.path, silent.path])
        await ingestor.rescan()

        #expect(unwanted.reads.isEmpty)
        #expect(wanted.reads.isEmpty == false)
        #expect(try await status(.codex, of: ingestor).enabled == false)
        #expect(try await status(.codex, of: ingestor).detected)
        #expect(try await status(.claudeCode, of: ingestor).enabled)
    }

    @Test func updateReadsWhatWasSwitchedOnAndLeavesWhatWasSwitchedOff() async throws {
        let first = try makeTempDir()
        let second = try makeTempDir()
        _ = try logFile("a.log", in: first)
        _ = try logFile("b.log", in: second)
        let one = SpyReader(source: .claudeCode)
        let other = SpyReader(source: .codex)
        let roots = SourceRoots(roots: [.claudeCode: [first.path], .codex: [second.path]])
        let ingestor = Ingestor(store: try .inMemory(), readers: [one, other], roots: roots, enabled: [.claudeCode])
        await ingestor.backfill()
        one.forgetReads()

        await ingestor.update(roots: roots, enabled: [.codex])
        #expect(other.reads == ["b.log"])
        #expect(one.reads.isEmpty)
    }

    @Test func updateReadsANewRoot() async throws {
        let first = try makeTempDir()
        let second = try makeTempDir()
        _ = try logFile("a.log", in: first)
        _ = try logFile("b.log", in: second)
        let spy = SpyReader(source: .claudeCode)
        let ingestor = spyIngestor(spy, root: first, store: try .inMemory())
        await ingestor.backfill()
        spy.forgetReads()

        await ingestor.update(roots: SourceRoots(roots: [.claudeCode: [first.path, second.path]]), enabled: [.claudeCode])
        #expect(spy.reads == ["b.log"])
        #expect(try await status(.claudeCode, of: ingestor).roots == [first.path, second.path])
    }

    @Test func twoRootsOverOneFileReadItOnce() async throws {
        let root = try makeTempDir()
        _ = try logFile("a.log", in: root)
        let spy = SpyReader(source: .claudeCode)
        let ingestor = Ingestor(
            store: try .inMemory(), readers: [spy], roots: SourceRoots(roots: [.claudeCode: [root.path, asReported(root.path)]]), enabled: [.claudeCode]
        )
        await ingestor.backfill()
        #expect(spy.reads == ["a.log"])
    }

    // MARK: Counts

    @Test func eventsAreTheStoresNotTheSumOfWhatReadsReturned() async throws {
        // A reader can return the same row on every read, as OpenCode does with the row at its cursor.
        let root = try makeTempDir()
        let file = try logFile("a.log", in: root)
        let spy = SpyReader(source: .opencode)
        let ingestor = spyIngestor(spy, root: root, store: try .inMemory())
        await ingestor.backfill()
        await ingestor.ingest(paths: [file.path])
        await ingestor.rescan()
        #expect(spy.reads.count == 3)
        #expect(try await status(.opencode, of: ingestor).events == 1)
    }

    /// Settings is where a person finds out: a source that cannot be walked must not look like one with nothing in it.
    @Test func aRootThatCannotBeListedCountsAsSkipped() async throws {
        let root = try makeTempDir()
        let projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: projects.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projects.path) }
        let ingestor = Ingestor(store: try .inMemory(), readers: [ClaudeCodeReader()], roots: SourceRoots(roots: [.claudeCode: [root.path]]), enabled: [.claudeCode])
        await ingestor.backfill()

        let claude = try await status(.claudeCode, of: ingestor)
        #expect((claude.detected, claude.files, claude.skipped) == (true, 0, 1))
    }

    @Test func oneTreeThatCannotBeListedLeavesTheOtherBeingRead() async throws {
        let root = try makeTempDir()
        try write([], to: root.appendingPathComponent("sessions/rollout-x.jsonl"))
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: archived.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: archived.path) }
        let ingestor = Ingestor(store: try .inMemory(), readers: [CodexReader()], roots: SourceRoots(roots: [.codex: [root.path]]), enabled: [.codex])
        await ingestor.backfill()

        let codex = try await status(.codex, of: ingestor)
        #expect((codex.files, codex.skipped) == (1, 1))
    }

    @Test func aTreeBehindALinkIsRead() async throws {
        let root = try makeTempDir()
        let elsewhere = try makeTempDir()
        try write([], to: elsewhere.appendingPathComponent("p/s.jsonl"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("projects"), withDestinationURL: elsewhere)
        let ingestor = Ingestor(store: try .inMemory(), readers: [ClaudeCodeReader()], roots: SourceRoots(roots: [.claudeCode: [root.path]]), enabled: [.claudeCode])
        await ingestor.backfill()

        let claude = try await status(.claudeCode, of: ingestor)
        #expect((claude.files, claude.skipped) == (1, 0))
    }

    @Test func statusesKeepTheSourcesApart() async throws {
        let first = try makeTempDir()
        let second = try makeTempDir()
        _ = try logFile("a.log", in: first)
        _ = try logFile("b.log", in: first)
        _ = try logFile("c.log", in: second)
        let one = SpyReader(source: .claudeCode, skipped: 1, eventTime: date("2026-11-03T09:00:00Z"))
        let other = SpyReader(source: .codex, eventTime: date("2026-11-03T10:00:00Z"))
        let ingestor = Ingestor(
            store: try .inMemory(), readers: [one, other], roots: SourceRoots(roots: [.claudeCode: [first.path], .codex: [second.path]]),
            enabled: [.claudeCode, .codex]
        )
        await ingestor.backfill()

        let claude = try await status(.claudeCode, of: ingestor)
        #expect((claude.files, claude.events, claude.skipped) == (2, 2, 2))
        #expect(claude.lastUpdate == date("2026-11-03T09:00:00Z"))
        let codex = try await status(.codex, of: ingestor)
        #expect((codex.files, codex.events, codex.skipped) == (1, 1, 0))
        #expect(codex.lastUpdate == date("2026-11-03T10:00:00Z"))
    }

    @Test func lastUpdateIsTheNewestEventsTime() async throws {
        let (root, transcript) = try claudeRoot()
        let ingestor = claudeIngestor(root: root, store: try .inMemory())
        #expect(try await status(.claudeCode, of: ingestor).lastUpdate == nil)

        await ingestor.backfill()
        try append(assistantLine(request: "r2", at: "2026-11-03T10:00:00.000Z") + "\n", to: transcript)
        await ingestor.ingest(paths: [transcript.path])
        #expect(try await status(.claudeCode, of: ingestor).lastUpdate == date("2026-11-03T10:00:00.000Z"))
    }

    @Test func skippedLinesAddUpAsAFileGrows() async throws {
        let (root, transcript) = try claudeRoot()
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)
        try append(#"{"usage":"# + "\n", to: transcript)
        await ingestor.backfill()
        #expect(try await status(.claudeCode, of: ingestor).skipped == 1)

        try append(#"{"usage":"# + "\n", to: transcript)
        await ingestor.ingest(paths: [transcript.path])
        #expect(try await status(.claudeCode, of: ingestor).skipped == 2)
    }

    @Test func readingAllOfAFileAgainCountsItsSkipsOnce() async throws {
        // A file that goes loses its cursor, so it comes back from its start.
        let (root, transcript) = try claudeRoot()
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)
        try append(#"{"usage":"# + "\n", to: transcript)
        await ingestor.backfill()
        #expect(try await status(.claudeCode, of: ingestor).skipped == 1)

        let away = try makeTempDir().appendingPathComponent("s.jsonl")
        try FileManager.default.moveItem(at: transcript, to: away)
        await ingestor.rescan()
        try FileManager.default.moveItem(at: away, to: transcript)
        await ingestor.rescan()
        #expect(try store.eventCount(source: .claudeCode) == 1)
        #expect(try await status(.claudeCode, of: ingestor).skipped == 1)
    }

    @Test func aFileCutShortCountsWhatIsLeft() async throws {
        let (root, transcript) = try claudeRoot()
        let ingestor = claudeIngestor(root: root, store: try .inMemory())
        try append(#"{"usage":"# + "\n" + #"{"usage":"# + "\n", to: transcript)
        await ingestor.backfill()
        #expect(try await status(.claudeCode, of: ingestor).skipped == 2)

        try write([#"{"usage":"#], to: transcript)
        await ingestor.ingest(paths: [transcript.path])
        #expect(try await status(.claudeCode, of: ingestor).skipped == 1)
    }

    @Test func aFileReplacedByALongerOneCountsTheNewOnesSkips() async throws {
        let (root, transcript) = try claudeRoot()
        let ingestor = claudeIngestor(root: root, store: try .inMemory())
        try append(#"{"usage":"# + "\n", to: transcript)
        await ingestor.backfill()
        #expect(try await status(.claudeCode, of: ingestor).skipped == 1)

        // A rename over the file: another inode, and more bytes than the old cursor's offset.
        let replacement = transcript.deletingLastPathComponent().appendingPathComponent("s.jsonl.new")
        try write([assistantLine(request: "r1"), assistantLine(request: "r2"), assistantLine(request: "r3"), #"{"usage":"#], to: replacement)
        _ = try FileManager.default.replaceItemAt(transcript, withItemAt: replacement)
        await ingestor.ingest(paths: [transcript.path])
        #expect(try await status(.claudeCode, of: ingestor).skipped == 1)
    }

    @Test func aReadThatFoundNothingNewAddsNoSkips() async throws {
        let root = try makeTempDir()
        let file = try logFile("a.log", in: root)
        let spy = SpyReader(source: .opencode, skipped: 1)
        let ingestor = spyIngestor(spy, root: root, store: try .inMemory())
        await ingestor.backfill()
        await ingestor.ingest(paths: [file.path])
        await ingestor.rescan()
        #expect(spy.reads.count == 3)
        #expect(try await status(.opencode, of: ingestor).skipped == 1)
    }

    @Test func aUsageFileCountsItsBadTurnsOnceHoweverOftenItIsRewritten() async throws {
        let root = try makeTempDir()
        let file = root.appendingPathComponent("sessions/%2Fp/g1/usage.json")
        let good: [String: Any] = ["turnNumber": 1, "endedAt": "2026-11-03T09:00:00.000+00:00", "primaryModelId": "grok-a", "inputTokens": 100, "outputTokens": 10]
        let bad: [String: Any] = ["endedAt": "2026-11-03T09:00:00.000+00:00"]
        try write([jsonLine(["turns": [good, bad]])], to: file)
        let ingestor = Ingestor(store: try .inMemory(), readers: [GrokReader()], roots: SourceRoots(roots: [.grok: [root.path]]), enabled: [.grok])
        await ingestor.backfill()
        #expect(try await status(.grok, of: ingestor).skipped == 1)

        var later = good
        later["turnNumber"] = 2
        try write([jsonLine(["turns": [good, bad, later]])], to: file)
        await ingestor.ingest(paths: [file.path])
        #expect(try await status(.grok, of: ingestor).skipped == 1)
        #expect(try await status(.grok, of: ingestor).events == 2)
    }

    @Test func aFileThatCannotBeReadIsOneSkippedItemAndTheOthersGoOn() async throws {
        let root = try makeTempDir()
        let bad = try logFile("bad.log", in: root)
        _ = try logFile("good.log", in: root)
        let spy = SpyReader(source: .codex)
        spy.breakFile("bad.log")
        let store = try EventStore.inMemory()
        let ingestor = spyIngestor(spy, root: root, store: store)

        await ingestor.backfill()
        #expect(Set(spy.reads) == ["bad.log", "good.log"])
        #expect(try store.eventCount(source: .codex) == 1)
        #expect(await ingestor.progress == IngestProgress(phase: .live, filesDone: 2, filesTotal: 2))
        #expect(try await status(.codex, of: ingestor).skipped == 1)

        // Trying again is not another skipped item.
        await ingestor.ingest(paths: [bad.path])
        await ingestor.rescan()
        #expect(try await status(.codex, of: ingestor).skipped == 1)

        spy.breakFile("bad.log", false)
        await ingestor.ingest(paths: [bad.path])
        #expect(try await status(.codex, of: ingestor).skipped == 0)
        #expect(try store.eventCount(source: .codex) == 2)
    }

    @Test func aFileThatNeverCouldBeReadStopsCountingOnceItIsGone() async throws {
        let root = try makeTempDir()
        let file = try logFile("a.log", in: root)
        let spy = SpyReader(source: .codex)
        spy.breakFile("a.log")
        let ingestor = spyIngestor(spy, root: root, store: try .inMemory())
        await ingestor.backfill()
        #expect(try await status(.codex, of: ingestor).skipped == 1)

        try FileManager.default.removeItem(at: file)
        await ingestor.rescan()
        #expect(try await status(.codex, of: ingestor).skipped == 0)
    }

    // MARK: Archives

    /// A rollout with one call, as the bytes of a compressed archive.
    private func archiveBytes() -> Data {
        let usage: [String: Any] = ["input_tokens": 100, "cached_input_tokens": 0, "output_tokens": 10, "reasoning_output_tokens": 0, "total_tokens": 110]
        let lines = [
            jsonLine(["type": "session_meta", "ordinal": 0, "timestamp": "2026-11-01T00:00:00.000Z", "payload": ["id": "t1", "cwd": "/p"]]),
            jsonLine(["type": "event_msg", "ordinal": 1, "timestamp": "2026-11-01T00:00:01.000Z", "payload": ["type": "token_count", "info": ["last_token_usage": usage, "total_token_usage": usage]]]),
        ]
        return ZstdFixture.compress(Data(lines.map { $0 + "\n" }.joined().utf8))
    }

    /// A Codex root with `bytes` as its one archive, an ingestor on it, and the reader that counts its reads.
    private func codexRoot(_ bytes: Data, store: EventStore) throws -> (archive: URL, ingestor: Ingestor, reader: CountingReader) {
        let root = try makeTempDir()
        let archive = root.appendingPathComponent("sessions/rollout-x.jsonl.zst")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: archive)
        let reader = CountingReader(base: CodexReader())
        let ingestor = Ingestor(store: store, readers: [reader], roots: SourceRoots(roots: [.codex: [root.path]]), enabled: [.codex])
        return (archive, ingestor, reader)
    }

    @Test func aHalfCopiedArchiveCountsOnceIsNotDecompressedAgainAndIsReadWhenWhole() async throws {
        let whole = archiveBytes()
        let store = try EventStore.inMemory()
        let (archive, ingestor, reader) = try codexRoot(whole.prefix(whole.count / 2), store: store)

        await ingestor.backfill()
        #expect(reader.reads == 1)
        #expect(try await status(.codex, of: ingestor).skipped == 1)

        // Every rescan and every event, for as long as the file stays as it is.
        await ingestor.rescan()
        await ingestor.ingest(paths: [archive.path])
        await ingestor.rescan()
        #expect(reader.reads == 1)
        #expect(try await status(.codex, of: ingestor).skipped == 1)

        try whole.write(to: archive)
        await ingestor.ingest(paths: [archive.path])
        #expect(reader.reads == 2)
        #expect(try store.eventCount(source: .codex) == 1)
        #expect(try await status(.codex, of: ingestor).skipped == 0)
    }

    @Test func aCorruptArchiveIsTriedAgainOnceItsTimeChangesThoughItsSizeDoesNot() async throws {
        let (archive, ingestor, reader) = try codexRoot(Data(repeating: 0x41, count: 64), store: try .inMemory())
        await ingestor.backfill()
        await ingestor.rescan()
        #expect(reader.reads == 1)

        try FileManager.default.setAttributes([.modificationDate: date("2026-11-01T00:00:00.000Z")], ofItemAtPath: archive.path)
        await ingestor.rescan()
        #expect(reader.reads == 2)
        #expect(try await status(.codex, of: ingestor).skipped == 1)
    }

    @Test func aCorruptArchiveIsTriedAgainOnceItsSizeChangesThoughItsTimeDoesNot() async throws {
        let (archive, ingestor, reader) = try codexRoot(Data(repeating: 0x41, count: 64), store: try .inMemory())
        let modified = date("2026-11-01T00:00:00.000Z")
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: archive.path)
        await ingestor.backfill()
        await ingestor.rescan()
        #expect(reader.reads == 1)

        try Data(repeating: 0x41, count: 65).write(to: archive)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: archive.path)
        await ingestor.rescan()
        #expect(reader.reads == 2)
    }

    @Test func aCorruptArchiveThatComesBackCountsAgain() async throws {
        // Remembered past its absence, the same bytes at the same time would be passed over with nothing to say so.
        let bytes = Data(repeating: 0x41, count: 64)
        let modified = date("2026-11-01T00:00:00.000Z")
        let (archive, ingestor, reader) = try codexRoot(bytes, store: try .inMemory())
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: archive.path)
        await ingestor.backfill()

        try FileManager.default.removeItem(at: archive)
        await ingestor.rescan()
        #expect(try await status(.codex, of: ingestor).skipped == 0)

        try bytes.write(to: archive)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: archive.path)
        await ingestor.rescan()
        #expect(reader.reads == 2)
        #expect(try await status(.codex, of: ingestor).skipped == 1)
    }

    @Test func aGoodReadForgetsTheFailureSoTheSameBadBytesCountAgain() async throws {
        // Remembered past a good read, bad bytes back at the same size and time would be passed over with nothing to say so.
        let bad = Data(repeating: 0x41, count: 64)
        let modified = date("2026-11-01T00:00:00.000Z")
        let store = try EventStore.inMemory()
        let (archive, ingestor, reader) = try codexRoot(bad, store: store)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: archive.path)
        await ingestor.backfill()

        try archiveBytes().write(to: archive)
        await ingestor.rescan()
        #expect(try store.eventCount(source: .codex) == 1)
        #expect(try await status(.codex, of: ingestor).skipped == 0)

        try bad.write(to: archive)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: archive.path)
        await ingestor.rescan()
        #expect(reader.reads == 3)
        #expect(try await status(.codex, of: ingestor).skipped == 1)
    }

    @Test func anArchiveBehindALinkIsTriedAgainWhenItsTargetChanges() async throws {
        // The reader follows the link, so what says the file changed has to as well: the link's own size and time stay put.
        let target = try makeTempDir().appendingPathComponent("target.zst")
        try Data(repeating: 0x41, count: 64).write(to: target)
        let store = try EventStore.inMemory()
        let (archive, ingestor, reader) = try codexRoot(Data(), store: store)
        try FileManager.default.removeItem(at: archive)
        try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: target)
        await ingestor.backfill()
        await ingestor.rescan()
        #expect(reader.reads == 1)

        try archiveBytes().write(to: target)
        await ingestor.rescan()
        #expect(reader.reads == 2)
        #expect(try store.eventCount(source: .codex) == 1)
        #expect(try await status(.codex, of: ingestor).skipped == 0)
    }

    @Test func aFailureThatIsNotInTheBytesIsTriedEveryTime() async throws {
        // A busy database or a full disk can pass with the file unchanged: OpenCode's writes land in its `-wal`, so the database's own size
        // and time stay put, and remembering such a failure would leave a working source unread.
        let root = try makeTempDir()
        let file = try logFile("a.log", in: root)
        let spy = SpyReader(source: .opencode)
        spy.breakFile("a.log")
        let ingestor = spyIngestor(spy, root: root, store: try .inMemory())

        await ingestor.backfill()
        await ingestor.ingest(paths: [file.path])
        await ingestor.rescan()
        #expect(spy.reads.count == 3)
        #expect(try await status(.opencode, of: ingestor).skipped == 1)

        spy.breakFile("a.log", false)
        await ingestor.rescan()
        #expect(try await status(.opencode, of: ingestor).skipped == 0)
    }

    @Test func aRebuildTriesACorruptArchiveAgain() async throws {
        let (_, ingestor, reader) = try codexRoot(Data(repeating: 0x41, count: 64), store: try .inMemory())
        await ingestor.backfill()
        try await ingestor.rebuildIndex()
        #expect(reader.reads == 2)
        #expect(try await status(.codex, of: ingestor).skipped == 1)
    }

    @Test func aCorruptArchiveThatIsGoneStopsCounting() async throws {
        let (archive, ingestor, _) = try codexRoot(Data(repeating: 0x41, count: 64), store: try .inMemory())
        await ingestor.backfill()
        #expect(try await status(.codex, of: ingestor).skipped == 1)

        try FileManager.default.removeItem(at: archive)
        await ingestor.rescan()
        #expect(try await status(.codex, of: ingestor).skipped == 0)
    }

    @Test func aFailedReadKeepsTheOldCursor() async throws {
        let root = try makeTempDir()
        let file = try logFile("a.log", in: root)
        let spy = SpyReader(source: .codex)
        let store = try EventStore.inMemory()
        let ingestor = spyIngestor(spy, root: root, store: store)
        await ingestor.backfill()
        let key = try #require(try store.cursorKeys().first)
        let cursor = try store.cursor(key)

        try append("more\n", to: file)
        spy.breakFile("a.log")
        await ingestor.ingest(paths: [file.path])
        #expect(try store.cursor(key) == cursor)
    }

    @Test func aRootThatCannotBeListedIsOneSkippedItemAndTheOthersGoOn() async throws {
        let broken = try makeTempDir()
        let fine = try makeTempDir()
        _ = try logFile("a.log", in: fine)
        let failing = SpyReader(source: .codex)
        failing.breakDiscovery()
        let working = SpyReader(source: .claudeCode)
        let store = try EventStore.inMemory()
        let ingestor = Ingestor(
            store: store, readers: [failing, working],
            roots: SourceRoots(roots: [.codex: [broken.path], .claudeCode: [fine.path]]), enabled: [.codex, .claudeCode]
        )
        await ingestor.backfill()
        await ingestor.rescan()
        #expect(try await status(.codex, of: ingestor).skipped == 1)
        #expect(try store.eventCount(source: .claudeCode) == 1)

        failing.breakDiscovery(false)
        await ingestor.rescan()
        #expect(try await status(.codex, of: ingestor).skipped == 0)
    }

    @Test func aRootThatCouldNotBeListedStopsCountingOnceItIsGone() async throws {
        let broken = try makeTempDir()
        let fine = try makeTempDir()
        let failing = SpyReader(source: .codex)
        failing.breakDiscovery()
        let ingestor = spyIngestor(failing, root: broken, store: try .inMemory())
        await ingestor.backfill()
        #expect(try await status(.codex, of: ingestor).skipped == 1)

        // Still failing, but no root of this source is listed any more.
        await ingestor.update(roots: SourceRoots(roots: [.codex: []]), enabled: [.codex])
        #expect(try await status(.codex, of: ingestor).skipped == 0)

        await ingestor.update(roots: SourceRoots(roots: [.codex: [fine.path]]), enabled: [.codex])
        #expect(try await status(.codex, of: ingestor).skipped == 1)
        await ingestor.update(roots: SourceRoots(roots: [.codex: [fine.path]]), enabled: [])
        #expect(try await status(.codex, of: ingestor).skipped == 0)
    }

    // MARK: Watching

    @Test func watcherDeliversAppends() async throws {
        let (root, transcript) = try claudeRoot()
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)
        await ingestor.backfill()
        #expect(try store.eventCount(source: .claudeCode) == 1)

        await ingestor.startWatching()
        try append(assistantLine(request: "r2") + "\n", to: transcript)
        let delivered = try await eventually { try store.eventCount(source: .claudeCode) == 2 }
        await ingestor.stopWatching()
        #expect(delivered)
    }

    @Test func watcherDeliversANewFile() async throws {
        let (root, _) = try claudeRoot()
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)
        await ingestor.backfill()

        await ingestor.startWatching()
        try write([assistantLine(request: "r2")], to: root.appendingPathComponent("projects/q/new.jsonl"))
        let delivered = try await eventually { try store.eventCount(source: .claudeCode) == 2 }
        await ingestor.stopWatching()
        #expect(delivered)
    }

    @Test func watcherSeesADatabaseThroughItsDirectory() async throws {
        let directory = try makeTempDir()
        let database = try logFile("opencode.db", in: directory)
        let wal = try logFile("opencode.db-wal", in: directory)
        let spy = SpyReader(source: .opencode)
        let ingestor = spyIngestor(spy, root: database, store: try .inMemory())
        await ingestor.backfill()
        spy.forgetReads()

        await ingestor.startWatching()
        try append("more\n", to: wal)
        let delivered = try await eventually { spy.reads.contains("opencode.db") }
        await ingestor.stopWatching()
        #expect(delivered)
    }

    @Test func stoppingEndsTheWatching() async throws {
        let (root, transcript) = try claudeRoot()
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)
        await ingestor.backfill()
        await ingestor.startWatching()
        await ingestor.startWatching()
        await ingestor.stopWatching()

        try append(assistantLine(request: "r2") + "\n", to: transcript)
        try await Task.sleep(for: .seconds(1.5))
        #expect(try store.eventCount(source: .claudeCode) == 1)
    }

    @Test func watchingRescansOnItsOwnUntilItStops() async throws {
        let root = try makeTempDir()
        _ = try logFile("a.log", in: root)
        let spy = SpyReader(source: .claudeCode)
        let ingestor = Ingestor(
            store: try .inMemory(), readers: [spy], roots: SourceRoots(roots: [.claudeCode: [root.path]]), enabled: [.claudeCode],
            now: { Date() }, rescanInterval: .milliseconds(20)
        )
        // Started twice: the second start replaces the first, it does not add a second loop.
        await ingestor.startWatching()
        await ingestor.startWatching()
        let looks = spy.discoveries
        // A long deadline for a loaded CI runner: on a free machine this takes a fraction of a second.
        #expect(try await eventually(within: 30) { spy.discoveries >= looks + 3 })

        await ingestor.stopWatching()
        // A rescan already on its way when the loop was cancelled can still finish.
        try await Task.sleep(for: .milliseconds(100))
        let stopped = spy.discoveries
        try await Task.sleep(for: .milliseconds(200))
        #expect(spy.discoveries == stopped)
    }

    @Test func aMissingRootDoesNotStopTheWatching() async throws {
        let (root, transcript) = try claudeRoot()
        let missing = try makeTempDir().appendingPathComponent("not-here").path
        let store = try EventStore.inMemory()
        let ingestor = Ingestor(
            store: store, readers: Ingestor.defaultReaders(),
            roots: SourceRoots(roots: [.claudeCode: [root.path], .codex: [missing]]), enabled: Set(Source.allCases)
        )
        await ingestor.backfill()

        await ingestor.startWatching()
        try append(assistantLine(request: "r2") + "\n", to: transcript)
        let delivered = try await eventually { try store.eventCount(source: .claudeCode) == 2 }
        await ingestor.stopWatching()
        #expect(delivered)
    }

    @Test func updateWatchesTheNewRoots() async throws {
        let (root, _) = try claudeRoot()
        let added = try makeTempDir()
        let transcript = added.appendingPathComponent("projects/q/s.jsonl")
        try write([assistantLine(request: "r2")], to: transcript)
        let store = try EventStore.inMemory()
        let ingestor = claudeIngestor(root: root, store: store)
        await ingestor.backfill()
        await ingestor.startWatching()
        await ingestor.update(roots: SourceRoots(roots: [.claudeCode: [root.path, added.path]]), enabled: [.claudeCode])
        #expect(try store.eventCount(source: .claudeCode) == 2)

        try append(assistantLine(request: "r3") + "\n", to: transcript)
        let delivered = try await eventually { try store.eventCount(source: .claudeCode) == 3 }
        await ingestor.stopWatching()
        #expect(delivered)
    }

    @Test func aWatcherStartedTwiceStopsAtOnceAndCanStartAgain() async throws {
        let directory = try makeTempDir()
        let deliveries = OSAllocatedUnfairLock(initialState: 0)
        let watcher = FileWatcher(paths: [asReported(directory.path)], latency: 0.05) { _ in
            deliveries.withLock { $0 += 1 }
        }
        watcher.start()
        watcher.start()
        watcher.stop()
        watcher.stop()
        try write(["x"], to: directory.appendingPathComponent("a"))
        try await Task.sleep(for: .seconds(1))
        #expect(deliveries.withLock { $0 } == 0)

        watcher.start()
        try write(["y"], to: directory.appendingPathComponent("b"))
        #expect(try await eventually { deliveries.withLock { $0 } > 0 })
        watcher.stop()
    }

    @Test func aWatcherWithNothingToWatchDoesNothing() {
        let watcher = FileWatcher(paths: []) { _ in }
        watcher.start()
        watcher.stop()
    }

    @Test func aWatcherStopsWhenItGoesAway() async throws {
        let directory = try makeTempDir()
        let deliveries = OSAllocatedUnfairLock(initialState: 0)
        var watcher: FileWatcher? = FileWatcher(paths: [asReported(directory.path)], latency: 0.05) { _ in
            deliveries.withLock { $0 += 1 }
        }
        watcher?.start()
        watcher = nil
        try write(["x"], to: directory.appendingPathComponent("a"))
        try await Task.sleep(for: .seconds(1))
        #expect(deliveries.withLock { $0 } == 0)
    }

    // MARK: Roots

    @Test func defaultRootsAreEachCLIsStandardLocation() {
        let home = URL(fileURLWithPath: "/Users/x")
        #expect(SourceRoots.defaults(home: home).roots == [
            .claudeCode: ["/Users/x/.claude"],
            .codex: ["/Users/x/.codex"],
            .omp: ["/Users/x/.omp"],
            .pi: ["/Users/x/.pi"],
            .copilot: ["/Users/x/.copilot"],
            .opencode: ["/Users/x/.local/share/opencode/opencode.db"],
            .grok: ["/Users/x/.grok"],
        ])
    }

    @Test func rootsSurviveEncoding() throws {
        let roots = SourceRoots.defaults(home: URL(fileURLWithPath: "/Users/x"))
        let decoded = try JSONDecoder().decode(SourceRoots.self, from: try JSONEncoder().encode(roots))
        #expect(decoded == roots)
    }

    @Test func unsupportedDetectedListsExistingDirectories() throws {
        let home = try makeTempDir()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
        #expect(SourceRoots.unsupportedDetected(home: home) == ["Gemini CLI"])
    }

    @Test func unsupportedDetectedNamesAllThreeInOrderAndOnlyDirectories() throws {
        let home = try makeTempDir()
        for name in [".cursor", ".qwen", ".gemini"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        #expect(SourceRoots.unsupportedDetected(home: home) == ["Gemini CLI", "Qwen Code", "Cursor"])

        let plain = try makeTempDir()
        try write([], to: plain.appendingPathComponent(".gemini"))
        #expect(SourceRoots.unsupportedDetected(home: plain).isEmpty)
    }

    @Test func theDefaultReadersCoverEverySourceOnce() {
        #expect(Ingestor.defaultReaders().map(\.source).sorted { $0.rawValue < $1.rawValue } == Source.allCases.sorted { $0.rawValue < $1.rawValue })
    }

    @Test func statusesListEveryReader() async throws {
        let ingestor = Ingestor(store: try .inMemory(), readers: Ingestor.defaultReaders(), roots: SourceRoots(roots: [:]), enabled: [])
        #expect(await ingestor.statuses().count == Source.allCases.count)
    }
}
