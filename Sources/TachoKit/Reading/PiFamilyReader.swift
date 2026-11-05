import Foundation

/// Reads the sessions of oh-my-pi and pi, which write the same records: `agent/sessions/**/*.jsonl` under `~/.omp` or `~/.pi`,
/// the sessions of sub-agents included.
///
/// A session starts with a header, below a title slot in omp's case, that names the session. After it, every assistant `message` record
/// is one model call with its own usage. omp also writes `model_usage` records, side calls outside the transcript such as a cache
/// warm-up or a task-completion probe: they are billed like the others. A fork replays its parent's messages, `responseId` included,
/// so a call has one key in every file it appears in.
///
/// What attributes a call is written once, in the header, so it travels in the cursor's state.
public struct PiFamilyReader: SourceReader {
    public let source: Source

    /// `source` is `.omp` or `.pi`.
    public init(source: Source) {
        self.source = source
    }

    public func discover(root: URL) throws -> [URL] {
        try SourceWalk.selecting({
            try SourceWalk.files(under: root.appendingPathComponent("agent/sessions", isDirectory: true))
        }, where: { $0.pathExtension == "jsonl" })
    }

    public func read(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        // The header is at the top of the file. A cursor whose state is gone has no way to tell the lines after it,
        // so the file is read again from its start; the store keeps the calls it already has.
        let state = cursor.flatMap(Self.state(of:))
        var pass = Pass(source: source, state: state ?? State())
        var outcome = try LineReader.read(url, from: state == nil ? nil : cursor) { pass.consume($0) }
        if outcome.restarted {
            // The file is another one now. What the pass made came from the old file's state, so it is thrown away whole.
            pass = Pass(source: source, state: State())
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

/// What a read passes on to the next read of the same file: what the header said.
private struct State: Codable {
    /// `id` of the header: nil until one has been read.
    var session: String?
    /// `cwd` of the header.
    var project: String?
    /// Whether the header names a parent session.
    var isSubagent = false
}

/// One walk over the lines of a file, from a given state.
private struct Pass {
    let source: Source
    var state: State
    /// In the order of the file.
    private(set) var events: [UsageEvent] = []
    private(set) var skipped = 0

    init(source: Source, state: State) {
        self.source = source
        self.state = state
    }

    mutating func consume(_ line: Data) {
        // Only these lines matter; tool results and user messages, the bulk of a session, are never parsed.
        // The quotes keep the words of a text out: inside a JSON string they are escaped.
        guard dataContains(line, #""usage""#) || dataContains(line, #""session""#) || dataContains(line, #""assistant""#)
            || dataContains(line, #""model_usage""#) else { return }
        guard let object = JSONObject(line) else {
            skipped += 1
            return
        }
        switch object.string("type") {
        case "session":
            addHeader(object)
        case "message":
            guard let message = object.object("message"), message.string("role") == "assistant" else { return }
            addCall(
                message,
                key: present(message.string("responseId")) ?? present(message.string("respId")) ?? present(object.string("id")),
                time: message.date("completedAt") ?? object.date("timestamp"),
                generationMs: Self.generationMs(message)
            )
        case "model_usage":
            addCall(object, key: present(object.string("id")).map { "mu:\($0)" }, time: object.date("timestamp"))
        default:
            break
        }
    }

    private mutating func addHeader(_ object: JSONObject) {
        guard let session = object.string("id") else {
            skipped += 1
            return
        }
        state.session = session
        state.project = object.string("cwd")
        state.isSubagent = object.string("parentSession") != nil
    }

    /// One model call. `call` is what holds its usage, provider and model: the message of an assistant record, a side call's record itself.
    private mutating func addCall(_ call: JSONObject, key: String?, time: Date?, generationMs: Double? = nil) {
        guard let usage = call.object("usage"), Self.holdsCounts(usage) else {
            skipped += 1
            return
        }
        let tokens = Self.tokens(usage)
        // A call that failed or was aborted before the provider counted anything.
        guard tokens != .zero else { return }
        guard let key, let time else {
            skipped += 1
            return
        }
        events.append(UsageEvent(
            source: source,
            dedupKey: "\(source.rawValue):\(key)",
            sessionId: state.session,
            project: state.project,
            isSubagent: state.isSubagent,
            provider: call.string("provider"),
            model: call.string("model"),
            time: time,
            generationMs: generationMs,
            tokens: tokens
        ))
    }

    /// The time the model spent writing. omp gives the whole call and the wait for the first token, pi only the whole call.
    /// omp's `duration` alone would count the wait as writing, so it gives no time.
    private static func generationMs(_ message: JSONObject) -> Double? {
        if let duration = message.double("duration"), let firstToken = message.double("ttft") {
            return duration - firstToken
        }
        return message.double("durationMs")
    }

    private static func holdsCounts(_ usage: JSONObject) -> Bool {
        usage.holdsCounts(required: ["input", "output"], optional: ["reasoning", "cacheRead", "cacheWrite", "cacheWrite1h"])
            && usage.object("cttl")?.holdsCounts(required: [], optional: ["ephemeral1h"]) != false
    }

    /// `input` is already the uncached part: unlike Codex's, the usage adds up to the call's total as it stands.
    /// Cache writes are the total less the one-hour part, which omp reports under `cttl` and pi as a figure of its own.
    private static func tokens(_ usage: JSONObject) -> TokenCounts {
        let oneHour = usage.int("cttl", "ephemeral1h") ?? usage.int("cacheWrite1h") ?? 0
        return TokenCounts(
            input: usage.int("input") ?? 0,
            output: usage.int("output") ?? 0,
            reasoning: usage.int("reasoning") ?? 0,
            cacheRead: usage.int("cacheRead") ?? 0,
            cacheWrite5m: max(0, (usage.int("cacheWrite") ?? 0) - oneHour),
            cacheWrite1h: oneHour
        )
    }
}
