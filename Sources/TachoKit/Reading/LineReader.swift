import Foundation

/// What one `LineReader.read` did.
public struct LineReadOutcome: Equatable, Sendable {
    /// Where the next read of the file continues.
    public var cursor: FileCursor
    /// True when the file no longer matched the given cursor, so it was read again from its first byte.
    public var restarted: Bool
    /// How many lines were passed to the closure. Empty lines are not counted.
    public var lines: Int
}

/// Reads the lines a growing JSONL file gained since the last read, one chunk at a time: a file is never held whole.
public enum LineReader {
    public static let defaultChunkSize = 4 * 1024 * 1024

    /// Calls `line` for every complete, non-empty line after the cursor; a trailing line without "\n" is left for the next read.
    /// Restarts from 0 (restarted = true, state = nil) when the inode changed or the file is shorter than the offset.
    ///
    /// The line is a fresh `Data` whose indices start at 0 and does not include the "\n".
    ///
    /// The read stops at the size the file had when it was opened, so the returned cursor never claims bytes the read did not see;
    /// what was appended meanwhile is left for the next read. `state` and `complete` pass from `cursor` to the returned cursor
    /// unchanged, except that a restart clears them.
    ///
    /// An error thrown by `line` ends the read and is rethrown. No cursor comes back then, so the caller's old one stays in force.
    public static func read(
        _ url: URL,
        from cursor: FileCursor?,
        chunkSize: Int = defaultChunkSize,
        line: (Data) throws -> Void
    ) throws -> LineReadOutcome {
        precondition(chunkSize > 0, "LineReader.read: chunkSize must be positive")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let file = try FileSnapshot(of: handle)

        var restarted = false
        var start: UInt64 = 0
        if let cursor {
            if cursor.inode == file.inode && cursor.offset <= file.size {
                start = cursor.offset
            } else {
                restarted = true
            }
        }
        let continued = restarted ? nil : cursor

        try handle.seek(toOffset: start)
        var position = start // the file offset of the next byte to read
        var carried = Data() // the unfinished line so far: the bytes after the last newline
        var lines = 0
        while position < file.size {
            let count = Int(min(UInt64(chunkSize), file.size - position))
            // Nothing comes back when the file got shorter since it was opened: stop where it ends.
            // In a pool of its own: `read` autoreleases, and a read of a whole file is one job, so without it every chunk stays to the end.
            guard let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: count) }), !chunk.isEmpty else { break }
            position += UInt64(chunk.count)
            try chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let base = bytes.baseAddress else { return }
                let first = base.assumingMemoryBound(to: UInt8.self)
                var lineStart = 0
                while lineStart < bytes.count, let newline = memchr(first + lineStart, 0x0A, bytes.count - lineStart) {
                    let lineEnd = base.distance(to: UnsafeRawPointer(newline))
                    if carried.isEmpty {
                        if lineEnd > lineStart {
                            try line(Data(bytes: first + lineStart, count: lineEnd - lineStart))
                            lines += 1
                        }
                    } else {
                        carried.append(first + lineStart, count: lineEnd - lineStart)
                        let whole = carried
                        carried = Data()
                        try line(whole)
                        lines += 1
                    }
                    lineStart = lineEnd + 1
                }
                carried.append(first + lineStart, count: bytes.count - lineStart)
            }
        }

        return LineReadOutcome(
            cursor: FileCursor(
                inode: file.inode,
                size: file.size,
                offset: position - UInt64(carried.count),
                mtime: file.mtime,
                state: continued?.state,
                complete: continued?.complete ?? false
            ),
            restarted: restarted,
            lines: lines
        )
    }
}

/// The inode, size and modification time of an open file.
///
/// They come from the descriptor, not from the path, so they describe the very file that is read even when the path is replaced meanwhile.
/// A reader that takes a whole file apart from `LineReader` (a compressed rollout) describes it with the same figures.
struct FileSnapshot {
    var inode: UInt64
    var size: UInt64
    var mtime: Date

    init(of handle: FileHandle) throws {
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        inode = UInt64(status.st_ino)
        size = UInt64(max(0, status.st_size))
        mtime = Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec) + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}
