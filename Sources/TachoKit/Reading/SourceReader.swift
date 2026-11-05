import Foundation

/// What one read of a file produced.
public struct ReadResult: Sendable {
    public var events: [UsageEvent]
    public var quotas: [QuotaSnapshot]
    /// Where the next read of the file continues.
    public var cursor: FileCursor
    /// Records the reader recognised as its own but could not decode.
    public var skipped: Int

    public init(events: [UsageEvent], quotas: [QuotaSnapshot], cursor: FileCursor, skipped: Int) {
        self.events = events
        self.quotas = quotas
        self.cursor = cursor
        self.skipped = skipped
    }
}

/// Turns one CLI's local files into events and quota snapshots.
public protocol SourceReader: Sendable {
    var source: Source { get }

    /// The files of this source under `root`, its configured location (e.g. `~/.claude`).
    func discover(root: URL) throws -> [URL]

    /// What is new in `url` after `cursor`; everything when `cursor` is nil.
    func read(_ url: URL, from cursor: FileCursor?) throws -> ReadResult
}
