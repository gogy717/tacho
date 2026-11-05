import Foundation

/// Reads Grok Build's usage files and its log, under `~/.grok`: `sessions/<project>/<session>/usage.json` and `logs/unified.jsonl`.
///
/// Grok counts by turn, not by model call. A `usage.json` holds the turns of a session and is rewritten whole, so it is read whole
/// whenever it changed: the turns it had before come back under the same keys, and the store keeps one of each.
/// The credit use of the week is only in the log, on the line Grok writes when it fetches its billing config.
public struct GrokReader: SourceReader {
    public init() {}

    public var source: Source { .grok }

    /// Every `usage.json` of a session directory under `root/sessions`, and the log.
    public func discover(root: URL) throws -> [URL] {
        try SourceWalk.selecting({
            try SourceWalk.gathering([
                { try Self.usageFiles(under: root.appendingPathComponent("sessions", isDirectory: true)) },
                { [root.appendingPathComponent("logs/unified.jsonl")] },
            ])
        }, where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    public func read(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        if url.lastPathComponent == "usage.json" {
            return try readUsage(url, from: cursor)
        }
        return try readLog(url, from: cursor)
    }

    /// Every `usage.json` under `sessions`. A project that is there and cannot be listed is reported, and the ones beside it still count.
    private static func usageFiles(under sessions: URL) throws -> [URL] {
        var found: [URL] = []
        var failure: (any Error)?
        for project in try SourceWalk.children(of: sessions) {
            do {
                for session in try listedDirectory(project) {
                    let usage = session.appendingPathComponent("usage.json")
                    if FileManager.default.fileExists(atPath: usage.path) {
                        found.append(usage)
                        continue
                    }
                    // No usage file. A session directory that cannot be listed is not an empty session.
                    // The failure stays with this session, so the ones after it in the same project still count.
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: session.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                    do {
                        _ = try FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)
                    } catch {
                        if failure == nil { failure = error }
                    }
                }
            } catch {
                if failure == nil { failure = error }
            }
        }
        if let failure { throw PartlyWalked(found: found, cause: failure) }
        return found
    }

    /// The contents of `directory` when it is one. A missing path or a file is nothing. A directory that cannot be listed throws.
    private static func listedDirectory(_ directory: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    /// A `usage.json`, whole, unless it is as the last read left it. There is no place in it to go on from, so the cursor's offset means nothing.
    /// One caught half-written counts as skipped; the write that finishes it changes the file, which reads it again.
    private func readUsage(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let file = try FileSnapshot(of: handle)
        if let cursor, cursor.size == file.size, cursor.mtime == file.mtime {
            return ReadResult(events: [], quotas: [], cursor: cursor, skipped: 0)
        }

        var turns = SessionTurns(of: url)
        turns.consume(try handle.readToEnd() ?? Data())
        let next = FileCursor(inode: file.inode, size: file.size, offset: file.size, mtime: file.mtime)
        return ReadResult(events: turns.events, quotas: [], cursor: next, skipped: turns.skipped)
    }

    /// The lines the log gained after the cursor. A billing line stands on its own, so the log keeps no state.
    private func readLog(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        var pass = LogPass()
        var outcome = try LineReader.read(url, from: cursor) { pass.consume($0) }
        if outcome.restarted {
            // The file is another one now: what the pass made is thrown away whole, as in every reader.
            pass = LogPass()
            outcome = try LineReader.read(url, from: nil) { pass.consume($0) }
        }
        return ReadResult(events: [], quotas: pass.quotas, cursor: outcome.cursor, skipped: pass.skipped)
    }
}

/// The turns of one `usage.json`. The file does not say what it belongs to: its path does.
private struct SessionTurns {
    /// The session directory's name.
    private let session: String
    /// The project directory's name, the percent-encoded working directory.
    private let project: String
    /// In the order of the file, and by model within a turn.
    private(set) var events: [UsageEvent] = []
    private(set) var skipped = 0

    init(of url: URL) {
        let directory = url.deletingLastPathComponent()
        let name = directory.deletingLastPathComponent().lastPathComponent
        session = directory.lastPathComponent
        project = name.removingPercentEncoding ?? name
    }

    mutating func consume(_ content: Data) {
        guard let file = JSONObject(content), let turns = file.array("turns") else {
            skipped += 1
            return
        }
        for turn in turns {
            guard let turn = turn as? [String: Any] else {
                skipped += 1
                continue
            }
            addTurn(turn)
        }
    }

    private mutating func addTurn(_ raw: [String: Any]) {
        let turn = JSONObject(raw)
        guard let number = turn.int("turnNumber"), let time = turn.date("endedAt") else {
            skipped += 1
            return
        }
        let models = raw["modelUsage"] as? [String: Any] ?? [:]
        if models.isEmpty {
            guard let model = turn.string("primaryModelId") else {
                skipped += 1
                return
            }
            addEvent(model: model, figures: raw, turn: number, time: time)
        }
        for (model, figures) in models.sorted(by: { $0.key < $1.key }) {
            guard let figures = figures as? [String: Any] else {
                skipped += 1
                continue
            }
            addEvent(model: model, figures: figures, turn: number, time: time)
        }
    }

    private mutating func addEvent(model: String, figures: [String: Any], turn: Int, time: Date) {
        guard Self.areCounts(figures) else {
            skipped += 1
            return
        }
        events.append(UsageEvent(
            source: .grok,
            dedupKey: "\(Source.grok.rawValue):\(session):\(turn):\(model)",
            sessionId: session,
            project: project,
            provider: "xai",
            model: model,
            time: time,
            tokens: Self.tokens(JSONObject(figures))
        ))
    }

    /// Whether the token figures can be taken as counts. A figure that is anything else would pass as 0, or take from the input, with
    /// nothing to say so. A figure may be missing, and a side figure may be null, since not every call has reasoning or a cache. A null
    /// input or output is a figure lost, and figures with no count at all say nothing about the call.
    private static func areCounts(_ figures: [String: Any]) -> Bool {
        let object = JSONObject(figures)
        var counts = 0
        for key in ["inputTokens", "outputTokens", "cachedReadTokens", "cacheCreationTokens", "reasoningTokens"] {
            guard let value = figures[key] else { continue }
            if value is NSNull {
                if key == "inputTokens" || key == "outputTokens" { return false }
                continue
            }
            guard object.isCount(key) else { return false }
            counts += 1
        }
        return counts > 0
    }

    /// `inputTokens` is the whole prompt: the cached part and the cache write are in it, so they come out of it.
    private static func tokens(_ figures: JSONObject) -> TokenCounts {
        let cached = figures.int("cachedReadTokens") ?? 0
        let created = figures.int("cacheCreationTokens") ?? 0
        return TokenCounts(
            input: max(0, (figures.int("inputTokens") ?? 0) - cached - created),
            output: figures.int("outputTokens") ?? 0,
            reasoning: figures.int("reasoningTokens") ?? 0,
            cacheRead: cached,
            cacheWrite5m: created
        )
    }
}

/// One walk over lines of the log.
private struct LogPass {
    /// In the order of the log.
    private(set) var quotas: [QuotaSnapshot] = []
    private(set) var skipped = 0

    mutating func consume(_ line: Data) {
        // Only this line matters; the rest of the log is never parsed. The quotes keep the words of a text out: inside a JSON string they are escaped.
        guard dataContains(line, #""billing: fetched credits config""#) else { return }
        guard let object = JSONObject(line) else {
            skipped += 1
            return
        }
        guard object.string("msg") == "billing: fetched credits config" else { return }
        // An account billed by the month has a percent of its month: calling it weekly would break the projection.
        guard let period = object.string("ctx", "config", "currentPeriod", "type"), period.uppercased().contains("WEEK") else { return }
        guard let usedPercent = object.double("ctx", "config", "creditUsagePercent"), usedPercent >= 0,
              let resetsAt = object.date("ctx", "config", "currentPeriod", "end"),
              let observedAt = object.date("ts")
        else {
            skipped += 1
            return
        }
        // A plan used up shows as full, whatever Grok's credits add up to beyond it.
        quotas.append(QuotaSnapshot(
            provider: .xai, window: .weekly, usedPercent: min(100, usedPercent), resetsAt: resetsAt, observedAt: observedAt, origin: .grokLog
        ))
    }
}
