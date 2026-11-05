import Foundation

/// How far the backfill has got.
public struct IngestProgress: Equatable, Sendable {
    /// `live` means the newest backfill has finished, whether or not watching has started.
    public enum Phase: Equatable, Sendable { case idle, recent, history, live }

    public var phase: Phase
    public var filesDone: Int
    public var filesTotal: Int

    public init(phase: Phase, filesDone: Int, filesTotal: Int) {
        self.phase = phase
        self.filesDone = filesDone
        self.filesTotal = filesTotal
    }
}

/// What Settings shows for a source.
public struct SourceStatus: Equatable, Sendable {
    public var source: Source
    public var roots: [String]
    /// Whether any of its roots exists.
    public var detected: Bool
    public var enabled: Bool
    /// The files found at the last look; none for a source that is switched off.
    public var files: Int
    /// The events in the store.
    public var events: Int
    /// What could not be used since launch, counted per file: the records reads skipped, plus each file or root that cannot be read right now.
    public var skipped: Int
    /// The time of the source's newest event.
    public var lastUpdate: Date?

    public init(source: Source, roots: [String], detected: Bool, enabled: Bool, files: Int, events: Int, skipped: Int, lastUpdate: Date?) {
        self.source = source
        self.roots = roots
        self.detected = detected
        self.enabled = enabled
        self.files = files
        self.events = events
        self.skipped = skipped
        self.lastUpdate = lastUpdate
    }
}

/// Keeps the store up with the files of every enabled source.
///
/// Reading one file is a single step of the actor, with no suspension in it: cursor, read, store, new cursor. Calls interleave only
/// between files, so two of them can never read a file from the same cursor, and whichever comes second finds nothing left to read.
/// Crashing between the steps is safe too: the cursor is written last, and reading again is harmless under the store's merge rule.
public actor Ingestor {
    /// Files modified this recently come first, so that the panel is useful before the history is in.
    private static let recentWindow: TimeInterval = 7 * 86_400

    public private(set) var progress = IngestProgress(phase: .idle, filesDone: 0, filesTotal: 0)

    private let store: EventStore
    private let readers: [any SourceReader]
    private let now: @Sendable () -> Date
    /// How often a rescan runs while watching. FSEvents can drop events, and a root that appears later is not watched: this catches both.
    private let rescanInterval: Duration
    private var roots: SourceRoots
    private var enabled: Set<Source>

    /// The files of the enabled sources at the last look, by resolved path.
    private var files: [String: SourceFile] = [:]
    /// Paths under a root that belong to no source, as of the last rescan: a change to them is no reason to look for files again.
    private var strangers: Set<String> = []
    /// What reads reported as skipped, by cursor key.
    private var skippedRecords: [String: Int] = [:]
    /// Cursor keys of the files whose last read failed.
    private var unreadable: Set<String> = []
    /// How each file stood before its last good read, by cursor key. As long as it stands so, a read would find nothing: that would
    /// be most of a rescan, every file every minute. Not kept for what `isSeenByItsStamp` says cannot be judged this way.
    private var readAt: [String: FileStamp] = [:]
    /// How the files whose bytes could not be decoded stood, by cursor key. Such a file fails the same way until it changes,
    /// and decompressing a large archive holds the actor, so it is not tried again before that.
    private var undecodable: [String: FileStamp] = [:]
    /// Keys of the roots that could not be listed at the last look.
    private var unlistable: Set<String> = []

    /// How many backfills have begun. A backfill goes on only while it is the newest, so `progress` always describes that one.
    private var backfills = 0

    private var watcher: FileWatcher?
    private var rescans: Task<Void, Never>?
    private let mayBeAFile: @Sendable (String) -> Bool

    public init(
        store: EventStore,
        readers: [any SourceReader],
        roots: SourceRoots,
        enabled: Set<Source>,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(store: store, readers: readers, roots: roots, enabled: enabled, now: now, rescanInterval: .seconds(60))
    }

    init(
        store: EventStore,
        readers: [any SourceReader],
        roots: SourceRoots,
        enabled: Set<Source>,
        now: @escaping @Sendable () -> Date = { Date() },
        rescanInterval: Duration = .seconds(60),
        mayBeAFile: @escaping @Sendable (String) -> Bool = Ingestor.mayBeSourceFile
    ) {
        self.store = store
        self.readers = readers
        self.roots = roots
        self.enabled = enabled
        self.now = now
        self.rescanInterval = rescanInterval
        self.mayBeAFile = mayBeAFile
    }

    /// Whether any reader takes a file of this name. Every `discover` looks for these and no others, besides OpenCode's database, which
    /// is known by being its root. Were one to take another, its new files would wait for the next rescan, which finds them all.
    static func mayBeSourceFile(_ path: String) -> Bool {
        path.hasSuffix(".jsonl") || path.hasSuffix(".jsonl.zst") || path.hasSuffix("/usage.json")
    }

    /// A reader for each of the seven sources.
    public static func defaultReaders() -> [any SourceReader] {
        [ClaudeCodeReader(), CodexReader(), PiFamilyReader(source: .omp), PiFamilyReader(source: .pi), CopilotReader(), OpenCodeReader(), GrokReader()]
    }

    /// Reads every file: those modified in the last seven days first, then the rest, each part newest first.
    /// A backfill that a newer one overtakes stops at its next file, and leaves `progress` to it.
    public func backfill() async {
        backfills += 1
        let run = backfills
        discoverFiles()
        let cutoff = now().addingTimeInterval(-Self.recentWindow)
        let dated = files.values.map { (file: $0, modified: Self.modified($0.url)) }.sorted { $0.modified > $1.modified }
        progress = IngestProgress(phase: .recent, filesDone: 0, filesTotal: dated.count)
        guard await read(dated.filter { $0.modified >= cutoff }.map(\.file), inBackfill: run) else { return }
        progress.phase = .history
        guard await read(dated.filter { $0.modified < cutoff }.map(\.file), inBackfill: run) else { return }
        progress.phase = .live
    }

    /// Forgets this machine's events, cursors and skip counts and reads every file again from its start. Quota snapshots stay,
    /// and so do rows from other machines: there are no logs here to reread them from.
    ///
    /// The reset has to happen here, on the actor: a read is one step of it, so the reset cannot land between a read and the cursor
    /// that read stores, which would leave a cursor past lines whose events are gone. A backfill under way gives way to this one.
    public func rebuildIndex() async throws {
        try store.resetIndex()
        skippedRecords.removeAll()
        unreadable.removeAll()
        undecodable.removeAll()
        readAt.removeAll()
        await backfill()
    }

    /// Reads what changed at `paths`, as FSEvents reports them. A path that is no file of an enabled source is ignored.
    public func ingest(paths: [String]) async {
        let (directories, databases) = rootsInUse()
        var changed: Set<String> = []
        for path in paths.map(Self.resolved) {
            if let database = databases.first(where: { path.hasPrefix($0) }) {
                // `opencode.db-wal` and `opencode.db-shm` change as the database does.
                changed.insert(database)
            } else if directories.contains(where: { path.hasPrefix($0 + "/") }) {
                changed.insert(path)
            }
        }
        // Not worth a walk of every root for a name no reader takes: a session saving through a temporary file makes a new one each time.
        let unknown = changed.subtracting(files.keys).subtracting(strangers).filter { databases.contains($0) || mayBeAFile($0) }
        if !unknown.isEmpty {
            discoverFiles()
            strangers.formUnion(unknown.subtracting(files.keys))
        }
        for file in changed.compactMap({ files[$0] }) {
            read(file)
            await Task.yield()
        }
    }

    /// Looks for files again and reads what has changed, which finds new files and anything the watcher missed. A file with nothing
    /// new costs one `stat`. A cursor whose file is gone is removed; its events stay, because history outlives the logs.
    public func rescan() async {
        strangers.removeAll()
        discoverFiles()
        // A file that went away, or whose source was switched off, cannot be read right now for a better reason.
        let known = Set(files.values.map(\.key))
        unreadable.formIntersection(known)
        undecodable = undecodable.filter { known.contains($0.key) }
        // A file that went took its cursor with it, so it must be read from its start if it comes back.
        readAt = readAt.filter { known.contains($0.key) }
        for file in files.values {
            read(file)
            await Task.yield()
        }
        removeCursorsOfDeletedFiles()
    }

    /// Watches every root that exists, and rescans every minute. OpenCode's root is a file, so its directory is what is watched.
    public func startWatching() {
        stopWatching()
        let (directories, databases) = rootsInUse()
        let paths = Set(directories + databases.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        let watcher = FileWatcher(paths: paths.sorted()) { [weak self] changed in
            Task { await self?.ingest(paths: changed) }
        }
        watcher.start()
        self.watcher = watcher
        rescans = Task { [weak self, rescanInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: rescanInterval)
                guard !Task.isCancelled, let self else { return }
                await self.rescan()
            }
        }
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
        rescans?.cancel()
        rescans = nil
    }

    /// Takes new settings and reads what they bring in. A source switched off keeps its events and its cursors.
    public func update(roots: SourceRoots, enabled: Set<Source>) async {
        self.roots = roots
        self.enabled = enabled
        if watcher != nil {
            startWatching()
        }
        await rescan()
    }

    /// One for each reader. The figures come from the store, not from what reads returned: a reader can return the same row every time.
    public func statuses() async -> [SourceStatus] {
        readers.map { reader in
            let source = reader.source
            let paths = roots.roots[source] ?? []
            return SourceStatus(
                source: source,
                roots: paths,
                detected: paths.contains { FileManager.default.fileExists(atPath: $0) },
                enabled: enabled.contains(source),
                files: files.values.filter { $0.reader.source == source }.count,
                events: (try? store.eventCount(source: source)) ?? 0,
                skipped: skipped(for: source),
                lastUpdate: (try? store.logPage(filter: EventFilter(sources: [source]), before: nil, limit: 1))?.first?.time
            )
        }
    }

    /// What could not be used since launch, counted per file so that reading a file again does not count its faults again:
    /// the records reads skipped, plus one for each file or root that cannot be read right now.
    private func skipped(for source: Source) -> Int {
        let prefix = Self.key(source, "")
        let records = skippedRecords.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
        return records + unreadable.union(unlistable).filter { $0.hasPrefix(prefix) }.count
    }

    /// Reads `backlog` in order, letting other calls in between files. False when a newer backfill took over meanwhile.
    private func read(_ backlog: [SourceFile], inBackfill run: Int) async -> Bool {
        for file in backlog {
            guard run == backfills else { return false }
            read(file)
            progress.filesDone += 1
            await Task.yield()
        }
        return run == backfills
    }

    /// One file, from its cursor into the store. When it fails the old cursor stays, so the next read starts where this one did.
    private func read(_ file: SourceFile) {
        // A file can go between a look and a read. That is no error: the next rescan removes its cursor.
        guard enabled.contains(file.reader.source), let stamp = FileStamp(ofFileAt: file.url.path) else { return }
        if undecodable[file.key] == stamp { return }
        // Taken before the read: a write during it leaves the file unlike this, so the next look reads it.
        if file.isSeenByItsStamp, readAt[file.key] == stamp { return }
        do {
            let cursor = try store.cursor(file.key)
            let result = try file.reader.read(file.url, from: cursor)
            if !result.events.isEmpty {
                try store.upsert(result.events)
            }
            if !result.quotas.isEmpty {
                try store.record(result.quotas)
            }
            // A cursor that did not move means nothing new, whatever the read returned: OpenCode returns the row at its cursor every time.
            if result.cursor != cursor {
                try store.setCursor(result.cursor, for: file.key)
                if file.isReadWhole || Self.startedOver(from: cursor, to: result.cursor) {
                    skippedRecords[file.key] = result.skipped
                } else {
                    skippedRecords[file.key, default: 0] += result.skipped
                }
            }
            unreadable.remove(file.key)
            // Kept past a good read, bad bytes back at the same size and time would be passed over with nothing to say so.
            undecodable[file.key] = nil
            if file.isSeenByItsStamp { readAt[file.key] = stamp }
        } catch {
            unreadable.insert(file.key)
            // Only a fault in the bytes is sure to come back while they stay as they are. Anything else, a full disk or a busy database,
            // can pass with the file unchanged, and OpenCode's writes land in its `-wal`, leaving the database's own size and time alone.
            if let error = error as? ZstdError, error != .outOfMemory {
                undecodable[file.key] = stamp
            }
        }
    }

    /// Finds the files of the enabled sources, by each reader's own rules. A root that cannot be listed counts as one skipped item
    /// until the next look, which also forgets it once it is no longer a root of an enabled source.
    private func discoverFiles() {
        var found: [String: SourceFile] = [:]
        var failed: Set<String> = []
        for reader in readers where enabled.contains(reader.source) {
            for root in roots.roots[reader.source] ?? [] {
                let urls: [URL]
                do {
                    urls = try reader.discover(root: URL(fileURLWithPath: root))
                } catch let partly as PartlyWalked {
                    urls = partly.found
                    failed.insert(Self.key(reader.source, root))
                } catch {
                    urls = []
                    failed.insert(Self.key(reader.source, root))
                }
                for url in urls {
                    let path = Self.resolved(url.path)
                    found[path] = SourceFile(reader: reader, url: url, key: Self.key(reader.source, path))
                }
            }
        }
        files = found
        unlistable = failed
    }

    /// A store that fails here fails again a minute later, and a cursor left behind does no harm until then.
    private func removeCursorsOfDeletedFiles() {
        for key in (try? store.cursorKeys()) ?? [] {
            guard let colon = key.firstIndex(of: ":"), !FileManager.default.fileExists(atPath: String(key[key.index(after: colon)...])) else { continue }
            try? store.removeCursor(key)
        }
    }

    /// The roots of the enabled sources that exist, resolved: the directories, and the roots that are files, such as OpenCode's database.
    private func rootsInUse() -> (directories: [String], files: [String]) {
        var directories: [String] = []
        var files: [String] = []
        for path in enabled.flatMap({ roots.roots[$0] ?? [] }).map(Self.resolved) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                directories.append(path)
            } else {
                files.append(path)
            }
        }
        return (directories, files)
    }

    /// Whether a read went through a file from its top, so that what it skipped is all the file has: there was no cursor, as after
    /// a rebuild, or the file is another one or was cut short. Reading on from `old`, a read reports only what is new.
    private static func startedOver(from old: FileCursor?, to new: FileCursor) -> Bool {
        guard let old else { return true }
        return new.inode != old.inode || new.offset < old.offset
    }

    private static func key(_ source: Source, _ path: String) -> String {
        "\(source.rawValue):\(path)"
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// `path` with every symlink resolved, as FSEvents reports it: "/private/var/…" for "/var/…". `URL.resolvingSymlinksInPath`
    /// would drop the "/private". A path that does not exist stays as it is.
    private static func resolved(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// What says that a file has changed. The time of the last change to the file itself is here because no one can set it, and the
/// inode because a file can be swapped for another that looks the same from outside.
private struct FileStamp: Equatable {
    var inode: UInt64
    var size: Int64
    var modified: Moment
    var changed: Moment

    struct Moment: Equatable {
        var seconds: Int
        var nanoseconds: Int

        init(_ time: timespec) {
            seconds = time.tv_sec
            nanoseconds = time.tv_nsec
        }
    }

    /// nil when the file cannot be inspected. `stat` follows a link to what it points at, as a reader does.
    init?(ofFileAt path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        inode = info.st_ino
        size = info.st_size
        modified = Moment(info.st_mtimespec)
        changed = Moment(info.st_ctimespec)
    }
}

/// A file of a source.
private struct SourceFile {
    let reader: any SourceReader
    /// As the reader discovered it: a reader can take meaning from the path it was given.
    let url: URL
    /// `"<source>:<resolved path>"`, which the cursor is stored under.
    let key: String

    /// Whether its stamp says all that a read would go by. Not OpenCode's database: its writes land in its `-wal`, which leaves the
    /// database's own stamp as it was. Every other reader goes by the bytes of this one file and the cursor it left.
    var isSeenByItsStamp: Bool {
        reader.source != .opencode
    }

    /// Grok's `usage.json` is read whole at every change, so a read counts all its bad turns again. Every other file goes on from its cursor.
    var isReadWhole: Bool {
        reader.source == .grok && url.lastPathComponent == "usage.json"
    }
}
