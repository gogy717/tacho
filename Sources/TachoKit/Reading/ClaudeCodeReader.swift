import Foundation

/// Reads Claude Code's session transcripts: `projects/**/*.jsonl` under `~/.claude`, the files of subagents and workflows included.
///
/// A response is written as one line per content block, all with the same `requestId` (or, without one, the same `message.id`).
/// The lines of a response collapse into one event, timed by the last of them. The transcript has no start time for a response:
/// `startTime` is the best guess it allows, the request that was sent for it or else the line that prompted it,
/// so a duration taken from it includes the wait for the first token.
public struct ClaudeCodeReader: SourceReader {
    public init() {}

    public var source: Source { .claudeCode }

    public func discover(root: URL) throws -> [URL] {
        try SourceWalk.selecting({
            try SourceWalk.files(under: root.appendingPathComponent("projects", isDirectory: true))
        }, where: { $0.pathExtension == "jsonl" })
    }

    public func read(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        var pass = Pass(state: Self.state(of: cursor))
        var outcome = try LineReader.read(url, from: cursor) { pass.consume($0) }
        if outcome.restarted {
            // The file is another one now. What the pass made came from the old file's state, so it is thrown away whole.
            pass = Pass(state: State())
            outcome = try LineReader.read(url, from: nil) { pass.consume($0) }
        }
        var next = outcome.cursor
        next.state = try JSONEncoder().encode(pass.state)
        return ReadResult(events: pass.events, quotas: [], cursor: next, skipped: pass.skipped)
    }

    /// The state a read left in `cursor`; a cursor without one, or with one this reader cannot decode, starts afresh.
    private static func state(of cursor: FileCursor?) -> State {
        cursor?.state.flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }
}

/// What a read passes on to the next read of the same file: the lines that date a response can lie before the cursor
/// while the response itself is only written after it.
private struct State: Codable {
    /// The time of the latest `api-request` line: when the request of the response to come was sent.
    /// It stays until the next `api-request` line, so every line of a response is dated alike, whichever read they fall in.
    var pendingStart: Date?
    /// The time of the latest `user` line, a prompt or a tool result: the best start when a transcript has no `api-request` lines.
    var lastUserTime: Date?
}

/// One walk over the lines of a file, from a given state.
private struct Pass {
    var state: State
    /// In the order the responses first appeared.
    private(set) var events: [UsageEvent] = []
    private(set) var skipped = 0
    /// The place in `events` of each response of this pass, by dedup key.
    private var indexByKey: [String: Int] = [:]

    init(state: State) {
        self.state = state
    }

    mutating func consume(_ line: Data) {
        // Only these lines matter; the rest (snapshots, titles, hook output, …) is never parsed.
        guard dataContains(line, #""usage""#) || dataContains(line, #""type":"assistant""#) || dataContains(line, #""type":"api-request""#) || dataContains(line, #""type":"user""#) else { return }
        guard let object = JSONObject(line) else {
            skipped += 1
            return
        }
        switch object.string("type") {
        case "api-request":
            state.pendingStart = object.date("timestamp") ?? state.pendingStart
        case "user":
            state.lastUserTime = object.date("timestamp") ?? state.lastUserTime
        default:
            addResponse(object)
        }
    }

    private mutating func addResponse(_ object: JSONObject) {
        guard let message = object.object("message"), message.string("role") == "assistant" else {
            // A line that says it is a response owes usage. With no assistant's message where it should be, the format moved on, and
            // the skipped count is all that can say so (spec 3, 5.4, 7). Healthy transcripts have no such line.
            if object.string("type") == "assistant" { skipped += 1 }
            return
        }
        // The placeholder Claude Code writes for an API error such as a 429: its usage is all zeros.
        guard message.string("model") != "<synthetic>" else { return }
        // Other lines embed an assistant message, such as Claude Code's own copy of a request: only a response owes usage.
        guard object.string("type") == "assistant" || message.object("usage") != nil else { return }
        guard let usage = message.object("usage"), Self.holdsCounts(usage),
              let key = present(object.string("requestId")) ?? present(message.string("id")), let time = object.date("timestamp")
        else {
            skipped += 1
            return
        }

        var event = UsageEvent(
            source: .claudeCode,
            client: object.string("entrypoint"),
            dedupKey: "\(Source.claudeCode.rawValue):\(key)",
            sessionId: object.string("sessionId"),
            project: object.string("cwd"),
            isSubagent: object.bool("isSidechain") ?? false,
            provider: "anthropic",
            model: message.string("model"),
            time: time,
            speed: usage.string("speed"),
            geo: usage.string("inference_geo"),
            tokens: Self.tokens(usage)
        )
        guard let index = indexByKey[event.dedupKey] else {
            event.startTime = state.pendingStart ?? state.lastUserTime
            indexByKey[event.dedupKey] = events.count
            events.append(event)
            return
        }
        // Another content block of a response already seen: keep the line the store keeps when it merges reads,
        // the larger output with a tie going to the later line. The response started with its first block.
        if event.tokens.output >= events[index].tokens.output {
            event.startTime = events[index].startTime
            events[index] = event
        }
    }

    private static func holdsCounts(_ usage: JSONObject) -> Bool {
        usage.holdsCounts(required: ["input_tokens", "output_tokens"], optional: ["cache_read_input_tokens", "cache_creation_input_tokens"])
            && usage.object("cache_creation")?.holdsCounts(required: [], optional: ["ephemeral_1h_input_tokens"]) != false
            && usage.object("output_tokens_details")?.holdsCounts(required: [], optional: ["thinking_tokens"]) != false
    }

    /// Cache writes are the total less the one-hour part; transcripts without the split count them all as five-minute writes.
    private static func tokens(_ usage: JSONObject) -> TokenCounts {
        let oneHour = usage.int("cache_creation", "ephemeral_1h_input_tokens") ?? 0
        return TokenCounts(
            input: usage.int("input_tokens") ?? 0,
            output: usage.int("output_tokens") ?? 0,
            reasoning: usage.int("output_tokens_details", "thinking_tokens") ?? 0,
            cacheRead: usage.int("cache_read_input_tokens") ?? 0,
            cacheWrite5m: max(0, (usage.int("cache_creation_input_tokens") ?? 0) - oneHour),
            cacheWrite1h: oneHour
        )
    }
}
