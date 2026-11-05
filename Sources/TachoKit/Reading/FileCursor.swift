import Foundation

/// Where a reader stopped in one file, so the next read continues from there.
///
/// The ingest store keeps one per file. `inode` and `size` tell a file that was appended to from one that was truncated or replaced.
public struct FileCursor: Codable, Equatable, Sendable {
    /// The file's inode when it was read. Another inode at the same path is another file.
    public var inode: UInt64
    /// The file's size in bytes when it was read.
    public var size: UInt64
    /// Bytes consumed: every complete line before this byte has been read, and a partial last line starts here.
    public var offset: UInt64
    /// The file's modification time when it was read.
    public var mtime: Date
    /// Reader-specific JSON, e.g. the running totals a reader needs to interpret the next lines; nil when it keeps none.
    public var state: Data?
    /// An immutable file (a `.zst` rollout) that has been read to its end.
    public var complete: Bool

    public init(inode: UInt64, size: UInt64, offset: UInt64, mtime: Date, state: Data? = nil, complete: Bool = false) {
        self.inode = inode
        self.size = size
        self.offset = offset
        self.mtime = mtime
        self.state = state
        self.complete = complete
    }
}
