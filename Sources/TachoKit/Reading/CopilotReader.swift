import Foundation

/// Reads Copilot CLI's session logs: `session-state/<id>/events.jsonl` under `~/.copilot`.
///
/// A log is a stream of events, the whole conversation among them. Every `session.usage_record` is one model call with its own figures,
/// and names the session itself. What it does not name is the working directory: that comes from the events that open the session,
/// so it travels in the cursor's state. Copilot counts premium requests, not a five-hour or weekly window, so there are no quota snapshots.
///
/// A record also carries the call's `apiCallId` and the log holds `content` and `arguments`. None of them is ever looked up.
public struct CopilotReader: SourceReader {
    public init() {}

    public var source: Source { .copilot }

    public func discover(root: URL) throws -> [URL] {
        let sessions = root.appendingPathComponent("session-state", isDirectory: true)
        var found: [URL] = []
        var failure: (any Error)?
        for directory in try SourceWalk.children(of: sessions) {
            let events = directory.appendingPathComponent("events.jsonl")
            if FileManager.default.fileExists(atPath: events.path) {
                found.append(events)
                continue
            }
            // No log file. A session directory that cannot be listed is not an empty session: the file may be in there.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            do {
                _ = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            } catch {
                if failure == nil { failure = error }
            }
        }
        if let failure { throw PartlyWalked(found: found, cause: failure) }
        return found
    }

    public func read(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        // The working directory is near the top of the file. A cursor whose state is gone has no way to tell the lines after it,
        // so the file is read again from its start; the store keeps the calls it already has.
        let state = cursor.flatMap(Self.state(of:))
        var pass = Pass(state: state ?? State())
        var outcome = try LineReader.read(url, from: state == nil ? nil : cursor) { pass.consume($0) }
        if outcome.restarted {
            // The file is another one now. What the pass made came from the old file's state, so it is thrown away whole.
            pass = Pass(state: State())
            outcome = try LineReader.read(url, from: nil) { pass.consume($0) }
        }
        var next = outcome.cursor
        next.state = try JSONEncoder().encode(pass.state)
        return ReadResult(events: pass.events, quotas: [], cursor: next, skipped: pass.skipped)
    }

    /// The state a read left in `cursor`; nil when the cursor has none, or one this reader cannot decode.
    private static func state(of cursor: FileCursor) -> State? {
        cursor.state.flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }
}

/// What a read passes on to the next read of the same file.
private struct State: Codable {
    /// The first `cwd` of the file: nil until one has been read.
    var project: String?
}

/// One walk over the lines of a file, from a given state.
private struct Pass {
    var state: State
    /// In the order of the file.
    private(set) var events: [UsageEvent] = []
    private(set) var skipped = 0

    init(state: State) {
        self.state = state
    }

    mutating func consume(_ line: Data) {
        // Only these lines matter, and a `cwd` only until the first one is known; the conversation is never parsed.
        // The quotes keep the words of a text out: inside a JSON string they are escaped.
        guard dataContains(line, #""session.usage_record""#) || (state.project == nil && dataContains(line, #""cwd""#)) else { return }
        guard let object = JSONObject(line) else {
            skipped += 1
            return
        }
        switch object.string("type") {
        case "session.usage_record":
            addCall(object)
        case "session.start":
            state.project = state.project ?? object.string("data", "context", "cwd")
        case "hook.start":
            state.project = state.project ?? object.string("data", "input", "cwd")
        default:
            break
        }
    }

    private mutating func addCall(_ object: JSONObject) {
        guard let usage = object.object("data", "usage"), Self.holdsCounts(usage), let key = present(usage.string("accounting", "usageId")), let time = object.date("timestamp") else {
            skipped += 1
            return
        }
        events.append(UsageEvent(
            source: .copilot,
            dedupKey: "\(Source.copilot.rawValue):\(key)",
            sessionId: usage.string("accounting", "sourceSessionId"),
            project: state.project,
            provider: "copilot",
            model: usage.string("model"),
            time: time,
            generationMs: Self.generationMs(usage),
            tokens: Self.tokens(usage)
        ))
    }

    private static func holdsCounts(_ usage: JSONObject) -> Bool {
        usage.holdsCounts(required: ["inputTokens", "outputTokens"], optional: ["cacheReadTokens", "cacheWriteTokens", "reasoningTokens"])
    }

    /// The time the model spent writing: the whole call less the wait for the first token.
    private static func generationMs(_ usage: JSONObject) -> Double? {
        guard let duration = usage.double("duration"), let firstToken = usage.double("timeToFirstTokenMs") else { return nil }
        return duration - firstToken
    }

    /// `inputTokens` is the whole prompt: the cache reads and writes are in it, so they come out of it.
    private static func tokens(_ usage: JSONObject) -> TokenCounts {
        let cacheRead = usage.int("cacheReadTokens") ?? 0
        let cacheWrite = usage.int("cacheWriteTokens") ?? 0
        return TokenCounts(
            input: max(0, (usage.int("inputTokens") ?? 0) - cacheRead - cacheWrite),
            output: usage.int("outputTokens") ?? 0,
            reasoning: usage.int("reasoningTokens") ?? 0,
            cacheRead: cacheRead,
            cacheWrite5m: cacheWrite
        )
    }
}
