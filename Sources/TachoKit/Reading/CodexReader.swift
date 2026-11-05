import Foundation

/// Reads Codex's rollouts: `sessions` and `archived_sessions` under `~/.codex`, as plain `.jsonl` or zstd-compressed `.jsonl.zst`.
///
/// A rollout is the log of one thread. After every response Codex writes a `token_count` record: the figures of that response
/// (`last_token_usage`) next to the thread's running total (`total_token_usage`). A record is a call only when its total differs
/// from that of the thread's previous count; the same total again is a replay, a resend after a rate-limit update, or the context
/// size after a compaction, none of which is a call. A call is counted by its own figures, never by the difference of two totals,
/// so a total that starts over after a resume cannot make one negative.
///
/// Each response also has a `token_usage_record` with the same figures, written as the response ends; its count comes once the
/// response's tool calls have run. A record with no such count is a call no total shows: Codex records a compaction's usage and leaves
/// it out of its running total. So a record is held until what comes next says which it is. Its key is the response's, as there is no
/// total to name it.
///
/// Known limit, kept by ruling (TFIX, 2026-11-05): a record still held at the end of a plain rollout counts only once the rollout is
/// archived, since no wait can tell that its count is not coming. On the Mac this was measured on, none of 228 rollouts ended so, while
/// counts came after their records by a median of 1.3 s, 24 of 2,806 after more than 5 minutes, 3 after more than an hour, and the
/// slowest after 1 h 39 min. `aLoneRecordAndMereMentionsMakeNoEvent` holds it.
///
/// A run of the model's answers with neither a count nor a record is counted as skipped, through `AnswersWithoutUsage`: the sign that
/// both moved where this reader no longer looks.
///
/// What attributes a count (the thread, its model, the history start) is written before it, so it travels in the cursor's state.
public struct CodexReader: SourceReader {
    public init() {}

    public var source: Source { .codex }

    /// Every rollout under `sessions`, and every `.jsonl` or `.jsonl.zst` file under `archived_sessions`.
    public func discover(root: URL) throws -> [URL] {
        try SourceWalk.gathering([
            { try Self.rollouts(under: root.appendingPathComponent("sessions", isDirectory: true)) { $0.hasPrefix("rollout-") } },
            { try Self.rollouts(under: root.appendingPathComponent("archived_sessions", isDirectory: true)) { _ in true } },
        ])
    }

    public func read(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        if url.pathExtension == "zst" {
            return try readArchive(url, from: cursor)
        }
        return try readRollout(url, from: cursor)
    }

    /// The `.jsonl` and `.jsonl.zst` files under `directory` whose name `accepts`.
    private static func rollouts(under directory: URL, where accepts: (String) -> Bool) throws -> [URL] {
        try SourceWalk.selecting({ try SourceWalk.files(under: directory) }) { url in
            let name = url.lastPathComponent
            return (name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst")) && accepts(name)
        }
    }

    /// A rollout Codex may still be writing: the lines after the cursor, read with the state the last read left.
    private func readRollout(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        // The thread and the model are written once, at the top of a rollout. A cursor whose state is gone has no way to tell
        // the lines after it, so the file is read again from its start; the store keeps the calls it already has.
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
        return ReadResult(events: pass.events, quotas: pass.quotas, cursor: next, skipped: pass.skipped)
    }

    /// An archive: a rollout compressed once Codex is done with it, never written again. It is decompressed and read in memory,
    /// whole and once, and its cursor says so; `LineReader` works on files, so the lines are split here.
    private func readArchive(_ url: URL, from cursor: FileCursor?) throws -> ReadResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let file = try FileSnapshot(of: handle)
        if let cursor, cursor.complete, cursor.inode == file.inode, cursor.size == file.size {
            return ReadResult(events: [], quotas: [], cursor: cursor, skipped: 0)
        }

        let content = try Zstd.decompress(try handle.readToEnd() ?? Data())
        var pass = Pass(state: State())
        Self.forEachLine(of: content) { pass.consume($0) }
        pass.settleRecord()
        // The cursor is the compressed file's. It keeps no state: nothing is read after it.
        let next = FileCursor(inode: file.inode, size: file.size, offset: file.size, mtime: file.mtime, complete: true)
        return ReadResult(events: pass.events, quotas: pass.quotas, cursor: next, skipped: pass.skipped)
    }

    /// Calls `line` for every non-empty line of `content`. A last line without "\n" is one too: an archive gets no later read to finish it.
    private static func forEachLine(of content: Data, _ line: (Data) -> Void) {
        content.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            let first = base.assumingMemoryBound(to: UInt8.self)
            var lineStart = 0
            while lineStart < bytes.count {
                let lineEnd = memchr(first + lineStart, 0x0A, bytes.count - lineStart).map { base.distance(to: UnsafeRawPointer($0)) } ?? bytes.count
                if lineEnd > lineStart {
                    line(Data(bytes: first + lineStart, count: lineEnd - lineStart))
                }
                lineStart = lineEnd + 1
            }
        }
    }

    /// The state a read left in `cursor`; nil when the cursor has none, or one this reader cannot decode.
    private static func state(of cursor: FileCursor) -> State? {
        cursor.state.flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }
}

/// A `token_usage_record` waiting for what comes after it. `model` is the one it was written under: what settles it can be a later turn.
private struct HeldRecord: Codable {
    var response: String
    var usage: Usage
    var time: Date
    var model: String?
}

/// What a read passes on to the next read of the same rollout.
private struct State: Codable {
    /// The thread, `id` of the session meta: nil until one has been read.
    var thread: String?
    var cwd: String?
    /// The session meta's `originator`.
    var client: String?
    var provider: String?
    var isSubagent = false
    /// The model of the latest turn context.
    var model: String?
    /// In a subagent's rollout, the ordinal from which the records are its own: below it they copy the parent's history.
    var historyStart: Int?
    /// The total of the thread's latest counted call.
    var previousTotal: Usage?
    /// It can wait across reads.
    var heldRecord: HeldRecord?
    /// The model's answers since the last count or record. nil with none, and in a cursor from before it.
    var answers: AnswersWithoutUsage?
    /// How many lines have been read, which is the position of the next one: the stand-in for an `ordinal` a record lacks.
    var lines = 0
}

/// The figures of one usage object, `last_token_usage` or `total_token_usage`. A figure the object lacks is 0.
private struct Usage: Codable, Equatable {
    var input: Int
    var cached: Int
    var cacheWrite: Int
    var output: Int
    var reasoning: Int
    var total: Int

    /// nil when `object` is missing or does not hold counts: a shape this reader does not know.
    init?(_ object: JSONObject?) {
        guard let object, object.holdsCounts(
            required: ["input_tokens", "output_tokens"],
            optional: ["cached_input_tokens", "cache_write_input_tokens", "reasoning_output_tokens", "total_tokens"]
        ) else { return nil }
        input = object.int("input_tokens") ?? 0
        cached = object.int("cached_input_tokens") ?? 0
        cacheWrite = object.int("cache_write_input_tokens") ?? 0
        output = object.int("output_tokens") ?? 0
        reasoning = object.int("reasoning_output_tokens") ?? 0
        total = object.int("total_tokens") ?? 0
    }

    /// `input_tokens` is the whole prompt: the cached part and the cache write are in it, so they come out of it.
    var tokens: TokenCounts {
        TokenCounts(input: max(0, input - cached - cacheWrite), output: output, reasoning: reasoning, cacheRead: cached, cacheWrite5m: cacheWrite)
    }

    /// Names a total: input, cached, cache write, output, reasoning, total.
    var key: String {
        "\(input),\(cached),\(cacheWrite),\(output),\(reasoning),\(total)"
    }
}

/// One walk over the lines of a rollout, from a given state.
private struct Pass {
    var state: State
    /// In the order of the rollout.
    private(set) var events: [UsageEvent] = []
    private(set) var quotas: [QuotaSnapshot] = []
    private(set) var skipped = 0

    init(state: State) {
        self.state = state
    }

    mutating func consume(_ line: Data) {
        defer { state.lines += 1 }
        if let answer = Self.answer(in: line) {
            // A copy of the parent's history: the parent's own rollout has its usage.
            if let start = state.historyStart, (answer.ordinal ?? state.lines) < start { return }
            addAnswer()
            return
        }
        // Only these records matter; the rest, which is most of a rollout and the largest part of it, is never parsed.
        guard dataContains(line, "token_count") || dataContains(line, "session_meta") || dataContains(line, "turn_context")
            || dataContains(line, "token_usage_record") || dataContains(line, #""compacted""#) else { return }
        guard let object = JSONObject(line) else {
            skipped += 1
            return
        }
        // A copy of the parent's history: the parent's own rollout has these records, whatever they are.
        if let start = state.historyStart, (object.int("ordinal") ?? state.lines) < start { return }

        switch object.string("type") {
        case "session_meta":
            addSessionMeta(object)
        case "turn_context":
            state.model = object.string("payload", "model") ?? state.model
        case "event_msg" where object.string("payload", "type") == "token_count":
            addTokenCount(object)
        case "token_usage_record":
            state.answers = nil
            addUsageRecord(object)
        case "compacted":
            settleRecord()
        default:
            break
        }
    }

    /// Something the model wrote: a message of its own, or a call of a tool. `ordinal` is the line's own, nil when it has none.
    private struct Answer {
        var ordinal: Int?
    }

    /// `line` as an answer, or nil when it is none. Told from the bytes and never parsed: what the model wrote is conversation, and
    /// tool output and reasoning are most of a rollout. Codex writes the timestamp, the ordinal, `"type":"response_item"`, and then the
    /// payload with the item's kind first.
    private static func answer(in line: Data) -> Answer? {
        line.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Answer? in
            guard let base = bytes.baseAddress, bytes.count >= itemPrefix.count,
                  let found = memmem(base, bytes.count, itemPrefix, itemPrefix.count)
            else { return nil }
            let head = base.distance(to: UnsafeRawPointer(found))
            let kind = bytes[(head + itemPrefix.count)...]
            guard answerKinds.contains(where: { kind.starts(with: $0) })
                || kind.starts(with: messageKind) && dataContains(line, #""role":"assistant""#)
            else { return nil }
            return Answer(ordinal: ordinal(in: UnsafeRawBufferPointer(rebasing: bytes[..<head])))
        }
    }

    /// The whole number after `"ordinal":` in `bytes`, the part of a line before its payload; nil when there is none, or it is too long
    /// to be one.
    private static func ordinal(in bytes: UnsafeRawBufferPointer) -> Int? {
        guard let base = bytes.baseAddress, let found = memmem(base, bytes.count, ordinalKey, ordinalKey.count) else { return nil }
        let digits = bytes[(base.distance(to: UnsafeRawPointer(found)) + ordinalKey.count)...].prefix { (0x30...0x39).contains($0) }
        guard (1...18).contains(digits.count) else { return nil }
        return digits.reduce(0) { $0 * 10 + Int($1 - 0x30) }
    }

    private static let itemPrefix = Array(#""type":"response_item","payload":{"type":""#.utf8)
    private static let answerKinds = [#"function_call""#, #"custom_tool_call""#, #"local_shell_call""#, #"web_search_call""#].map { Array($0.utf8) }
    private static let messageKind = Array(#"message""#.utf8)
    private static let ordinalKey = Array(#""ordinal":"#.utf8)

    /// Its usage comes in a count or a record after it. A long run with neither is a format the reader no longer follows.
    private mutating func addAnswer() {
        var answers = state.answers ?? AnswersWithoutUsage()
        skipped += answers.add()
        state.answers = answers
    }

    private mutating func addSessionMeta(_ object: JSONObject) {
        guard let meta = object.object("payload"), let thread = present(meta.string("id")) else {
            skipped += 1
            return
        }
        state.thread = thread
        state.cwd = meta.string("cwd")
        state.client = meta.string("originator")
        state.provider = meta.string("model_provider")
        state.isSubagent = Self.isSubagent(meta)
        state.historyStart = meta.int("subagent_history_start_ordinal").flatMap { $0 >= 0 ? $0 : nil }
    }

    /// Whether the thread belongs to a subagent, a spawned one or a guardian review, as against a thread the user opened.
    private static func isSubagent(_ meta: JSONObject) -> Bool {
        switch meta.string("thread_source") {
        case "subagent", "guardian_review":
            return true
        default:
            // Older rollouts have no thread source. Their `source` is a plain name ("cli", "vscode") for the user's threads,
            // and an object with a `subagent` key for the others; the key holds an object (`thread_spawn`) or a name ("review").
            guard let source = meta.object("source") else { return false }
            return source.object("subagent") != nil || source.string("subagent") != nil
        }
    }

    /// What came before settles first: a record its count has not followed by now never had one.
    private mutating func addUsageRecord(_ object: JSONObject) {
        settleRecord()
        guard let response = present(object.string("payload", "response_id")),
              let usage = Usage(object.object("payload", "usage")),
              let time = object.date("timestamp")
        else {
            skipped += 1
            return
        }
        state.heldRecord = HeldRecord(response: response, usage: usage, time: time, model: state.model)
    }

    /// The held record, if any, turned out to be a call no count covers.
    mutating func settleRecord() {
        guard let record = state.heldRecord else { return }
        state.heldRecord = nil
        guard let thread = state.thread else {
            skipped += 1
            return
        }
        events.append(UsageEvent(
            source: .codex,
            client: state.client,
            dedupKey: "\(Source.codex.rawValue):\(thread):usage:\(record.response)",
            sessionId: thread,
            project: state.cwd,
            isSubagent: state.isSubagent,
            provider: state.provider ?? "openai",
            model: record.model ?? state.model,
            time: record.time,
            tokens: record.usage.tokens
        ))
    }

    private mutating func addTokenCount(_ object: JSONObject) {
        let time = object.date("timestamp")
        // Rate limits come with every count, repeats included: an update of them is what makes Codex resend a count.
        if let time, let limits = object.object("payload", "rate_limits") {
            addQuotas(limits, observedAt: time)
        }

        // The first count of a thread has no `info`: it carries rate limits only.
        guard let info = object.object("payload", "info") else { return }
        state.answers = nil
        // Without a total there is no telling a call from a repeat, and no key.
        guard let total = Usage(info.object("total_token_usage")) else {
            skipped += 1
            return
        }
        guard total != state.previousTotal else { return }
        guard let thread = state.thread, let time, let last = Usage(info.object("last_token_usage")) else {
            skipped += 1
            return
        }

        if state.heldRecord?.usage == last {
            state.heldRecord = nil
        } else {
            settleRecord()
        }
        state.previousTotal = total
        events.append(UsageEvent(
            source: .codex,
            client: state.client,
            dedupKey: "\(Source.codex.rawValue):\(thread):\(total.key)",
            sessionId: thread,
            project: state.cwd,
            isSubagent: state.isSubagent,
            provider: state.provider ?? "openai",
            model: state.model,
            time: time,
            tokens: last.tokens
        ))
    }

    /// A snapshot for each of the primary and secondary windows of the plan's limits that has a use, a length of five hours or a week,
    /// and a reset time.
    private mutating func addQuotas(_ limits: JSONObject, observedAt: Date) {
        // Limits belong to one bucket. "codex", or none, is the plan; any other is a model's allowance (`codex_bengalfox`) whose five-hour
        // and weekly windows are its own. Codex records only the bucket it heard of last, so they would interleave with the plan's,
        // and the newest snapshot could be another bucket's.
        if let bucket = limits.string("limit_id"), bucket.lowercased() != "codex" { return }
        let plan = limits.string("plan_type")
        for name in ["primary", "secondary"] {
            guard let window = limits.object(name),
                  let usedPercent = window.double("used_percent"),
                  let length = Self.window(ofMinutes: window.double("window_minutes")),
                  let resetsAt = window.date("resets_at") ?? window.double("resets_in_seconds").map({ observedAt.addingTimeInterval($0) })
            else { continue }
            quotas.append(QuotaSnapshot(
                provider: .openai, window: length, usedPercent: min(100, max(0, usedPercent)), resetsAt: resetsAt, observedAt: observedAt,
                origin: .codexLog, plan: plan
            ))
        }
    }

    /// Codex's five-hour limit is 300 minutes long and its weekly one 10080. Another length, such as the monthly limit of a free plan,
    /// is neither of the two windows the forecast models, and calling it weekly would break the projection.
    private static func window(ofMinutes minutes: Double?) -> QuotaWindow? {
        switch minutes {
        case 300?: .fiveHour
        case 10_080?: .weekly
        default: nil
        }
    }
}
