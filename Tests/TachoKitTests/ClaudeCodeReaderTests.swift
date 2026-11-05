import Foundation
import Testing
@testable import TachoKit

struct ClaudeCodeReaderTests {
    private let reader = ClaudeCodeReader()

    private static let defaultUsage = #"{"input_tokens":2,"output_tokens":500,"cache_read_input_tokens":28102,"cache_creation_input_tokens":27045,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":27045},"output_tokens_details":{"thinking_tokens":281},"speed":"standard","inference_geo":"global"}"#

    /// A transcript line of one content block of an assistant response. `usage` is JSON text.
    private func assistant(
        id: String = "m1",
        req: String? = "r1",
        ts: String,
        model: String = "claude-opus-4-5",
        entrypoint: String = "cli",
        sidechain: Bool = false,
        usage: String = ClaudeCodeReaderTests.defaultUsage
    ) -> String {
        let requestId = req.map { #""requestId":"\#($0)","# } ?? ""
        return #"{"type":"assistant","timestamp":"\#(ts)",\#(requestId)"sessionId":"s1","cwd":"/p","gitBranch":"main","entrypoint":"\#(entrypoint)","isSidechain":\#(sidechain),"message":{"id":"\#(id)","role":"assistant","model":"\#(model)","usage":\#(usage)}}"#
    }

    /// The line Claude Code writes when it sends a request.
    private func apiRequest(ts: String) -> String {
        #"{"type":"api-request","timestamp":"\#(ts)","id":"q1","sessionId":"s1"}"#
    }

    /// A user line: a prompt or a tool result.
    private func user(ts: String) -> String {
        #"{"type":"user","timestamp":"\#(ts)","sessionId":"s1","message":{"role":"user","content":"hi"}}"#
    }

    private func newFile() throws -> URL {
        try makeTempDir().appendingPathComponent("s.jsonl")
    }

    /// Writes `lines` to a fresh file and reads it from its start.
    private func read(_ lines: [String]) throws -> ReadResult {
        let file = try newFile()
        try write(lines, to: file)
        return try reader.read(file, from: nil)
    }

    @Test func mapsUsageIntoFourDisjointCategories() throws {
        let result = try read([assistant(ts: "2026-10-31T18:22:35.360Z")])
        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(event.tokens == TokenCounts(input: 2, output: 500, reasoning: 281, cacheRead: 28_102, cacheWrite5m: 0, cacheWrite1h: 27_045))
        #expect(event.source == .claudeCode)
        #expect(event.model == "claude-opus-4-5")
    }

    @Test func splitsCacheWritesByLifetime() throws {
        let mixed = #"{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":60,"ephemeral_1h_input_tokens":40}}"#
        // Older transcripts have the total only: every write is a 5-minute write.
        let totalOnly = #"{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":100}"#
        let result = try read([
            assistant(id: "m1", req: "r1", ts: "2026-10-31T18:22:35.360Z", usage: mixed),
            assistant(id: "m2", req: "r2", ts: "2026-10-31T18:22:36.360Z", usage: totalOnly),
        ])
        #expect(result.events.map(\.tokens.cacheWrite5m) == [60, 100])
        #expect(result.events.map(\.tokens.cacheWrite1h) == [40, 0])
    }

    @Test func collapsesContentBlockLinesOfOneResponse() throws {
        let result = try read([
            assistant(ts: "2026-10-31T18:22:33.235Z"),
            assistant(ts: "2026-10-31T18:22:33.910Z"),
            assistant(ts: "2026-10-31T18:22:35.360Z"),
        ])
        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(event.time == date("2026-10-31T18:22:35.360Z"))
        #expect(event.dedupKey == "claudeCode:r1")

        // Without a requestId the message id is the key.
        let byMessage = try read([assistant(req: nil, ts: "2026-10-31T18:22:35.360Z")])
        #expect(byMessage.events.map(\.dedupKey) == ["claudeCode:m1"])
    }

    @Test func keepsTheFiguresOfTheLargerOutputWithinOneResponse() throws {
        let partial = #"{"input_tokens":2,"output_tokens":8,"output_tokens_details":{"thinking_tokens":0}}"#
        let final = #"{"input_tokens":2,"output_tokens":354,"output_tokens_details":{"thinking_tokens":300}}"#
        // Streaming: the first block carries the figures of the start of the response, the last block the final ones.
        let growing = try read([
            assistant(ts: "2026-10-31T18:22:33.235Z", usage: partial),
            assistant(ts: "2026-10-31T18:22:35.360Z", usage: final),
        ])
        #expect(growing.events.map(\.tokens.output) == [354])
        #expect(growing.events.map(\.tokens.reasoning) == [300])
        #expect(growing.events.map(\.time) == [date("2026-10-31T18:22:35.360Z")])

        // The rule the store applies across reads, applied within one: a later line with a smaller output does not replace the larger one.
        let shrinking = try read([
            assistant(ts: "2026-10-31T18:22:33.235Z", usage: final),
            assistant(ts: "2026-10-31T18:22:35.360Z", usage: partial),
        ])
        #expect(shrinking.events.map(\.tokens.output) == [354])
        #expect(shrinking.events.map(\.time) == [date("2026-10-31T18:22:33.235Z")])
    }

    @Test func skipsSyntheticErrorMessages() throws {
        let zero = #"{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}"#
        let result = try read([
            assistant(ts: "2026-10-31T18:22:35.360Z", model: "<synthetic>", usage: zero),
            // An error placeholder without ids or a timestamp is no lost record either.
            #"{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","model":"<synthetic>","usage":{}}}"#,
        ])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 0)
    }

    @Test func takesRequestStartFromApiRequestLine() throws {
        let result = try read([
            user(ts: "2026-10-31T18:22:30.000Z"),
            apiRequest(ts: "2026-10-31T18:22:36.080Z"),
            assistant(ts: "2026-10-31T18:22:38.655Z"),
        ])
        let event = try #require(result.events.first)
        #expect(event.startTime == date("2026-10-31T18:22:36.080Z"))
        #expect(event.generationMs == nil)
    }

    @Test func fallsBackToThePreviousUserLine() throws {
        let result = try read([
            user(ts: "2026-10-31T18:22:30.000Z"),
            assistant(ts: "2026-10-31T18:22:38.655Z"),
        ])
        let event = try #require(result.events.first)
        #expect(event.startTime == date("2026-10-31T18:22:30.000Z"))
    }

    @Test func hasNoStartWhenNothingCameBeforeTheResponse() throws {
        let result = try read([assistant(ts: "2026-10-31T18:22:38.655Z")])
        let event = try #require(result.events.first)
        #expect(event.startTime == nil)
    }

    @Test func eachResponseTakesTheLatestRequestBeforeIt() throws {
        let result = try read([
            user(ts: "2026-10-31T18:22:30.000Z"),
            apiRequest(ts: "2026-10-31T18:22:31.000Z"),
            assistant(id: "m1", req: "r1", ts: "2026-10-31T18:22:35.000Z"),
            user(ts: "2026-10-31T18:22:36.000Z"),
            apiRequest(ts: "2026-10-31T18:22:37.000Z"),
            assistant(id: "m2", req: "r2", ts: "2026-10-31T18:22:41.000Z"),
        ])
        #expect(result.events.map(\.startTime) == [date("2026-10-31T18:22:31.000Z"), date("2026-10-31T18:22:37.000Z")])
    }

    @Test func aPromptWrittenAfterItsRequestLineKeepsTheRequestStart() throws {
        // Claude Code can write the user line after the api-request line it triggered, with a slightly earlier timestamp.
        let result = try read([
            apiRequest(ts: "2026-10-31T18:22:36.460Z"),
            user(ts: "2026-10-31T18:22:36.445Z"),
            assistant(ts: "2026-10-31T18:22:41.000Z"),
        ])
        let event = try #require(result.events.first)
        #expect(event.startTime == date("2026-10-31T18:22:36.460Z"))
    }

    @Test func startTimeSurvivesChunkBoundary() throws {
        let file = try newFile()
        try write([apiRequest(ts: "2026-10-31T18:22:36.080Z")], to: file)
        let first = try reader.read(file, from: nil)
        #expect(first.events.isEmpty)

        try append(assistant(ts: "2026-10-31T18:22:38.655Z") + "\n", to: file)
        let second = try reader.read(file, from: first.cursor)
        let event = try #require(second.events.first)
        #expect(second.events.count == 1)
        #expect(event.startTime == date("2026-10-31T18:22:36.080Z"))
    }

    @Test func aHalfWrittenResponseLineCountsOnceWhenItsEndArrives() throws {
        let file = try newFile()
        let line = assistant(ts: "2026-10-31T18:22:38.655Z")
        let cut = line.index(line.startIndex, offsetBy: line.count / 2)
        try write([apiRequest(ts: "2026-10-31T18:22:36.080Z")], to: file)
        try append(String(line[..<cut]), to: file)
        let first = try reader.read(file, from: nil)
        // Caught mid-write: neither an event nor an unreadable line.
        #expect(first.events.isEmpty)
        #expect(first.skipped == 0)

        try append(String(line[cut...]) + "\n", to: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.map(\.dedupKey) == ["claudeCode:r1"])
        #expect(second.events.map(\.startTime) == [date("2026-10-31T18:22:36.080Z")])
        #expect(second.skipped == 0)
    }

    @Test func theUserLineFallbackSurvivesChunkBoundaryToo() throws {
        let file = try newFile()
        try write([user(ts: "2026-10-31T18:22:30.000Z")], to: file)
        let first = try reader.read(file, from: nil)

        try append(assistant(ts: "2026-10-31T18:22:38.655Z") + "\n", to: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.map(\.startTime) == [date("2026-10-31T18:22:30.000Z")])
    }

    @Test func theLinesOfOneResponseAreDatedAlikeAcrossReads() throws {
        let file = try newFile()
        try write([apiRequest(ts: "2026-10-31T18:22:36.080Z"), assistant(ts: "2026-10-31T18:22:38.000Z")], to: file)
        let first = try reader.read(file, from: nil)

        // The last block of the response is written later and read apart; the store merges the two events.
        try append(assistant(ts: "2026-10-31T18:22:45.000Z") + "\n", to: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(first.events.map(\.startTime) == [date("2026-10-31T18:22:36.080Z")])
        #expect(second.events.map(\.startTime) == [date("2026-10-31T18:22:36.080Z")])
        #expect(second.events.map(\.dedupKey) == first.events.map(\.dedupKey))
        #expect(second.events.map(\.time) == [date("2026-10-31T18:22:45.000Z")])
    }

    @Test func anUnreadableStateStartsAfresh() throws {
        let file = try newFile()
        try write([user(ts: "2026-10-31T18:22:30.000Z")], to: file)
        var cursor = try reader.read(file, from: nil).cursor
        cursor.state = Data("not json".utf8)

        try append(assistant(ts: "2026-10-31T18:22:38.655Z") + "\n", to: file)
        let result = try reader.read(file, from: cursor)
        #expect(result.events.map(\.dedupKey) == ["claudeCode:r1"])
        #expect(result.events.map(\.startTime) == [nil])
    }

    @Test func aRewrittenFileIsReadAgainFromNothing() throws {
        let file = try newFile()
        try write([apiRequest(ts: "2026-10-31T18:22:30.000Z"), assistant(id: "old", req: "old", ts: "2026-10-31T18:22:31.000Z")], to: file)
        let before = try reader.read(file, from: nil)
        #expect(before.events.map(\.dedupKey) == ["claudeCode:old"])

        // Shorter than what was read, so the reader starts over. The new file has no request or user line before its response,
        // so nothing of the old file may leak into its events (the request start) or its counts (the skipped line).
        try write([#"{"type":"assistant","message":{"usage":"#, assistant(id: "new", req: "new", ts: "2026-10-31T18:25:00.000Z")], to: file)
        let after = try reader.read(file, from: before.cursor)
        #expect(after.events.map(\.dedupKey) == ["claudeCode:new"])
        #expect(after.events.map(\.startTime) == [nil])
        #expect(after.skipped == 1)
    }

    @Test func mapsEntrypointAndSidechain() throws {
        let result = try read([assistant(ts: "2026-10-31T18:22:35.360Z", entrypoint: "claude-desktop", sidechain: true)])
        let event = try #require(result.events.first)
        #expect(event.client == "claude-desktop")
        #expect(event.isSubagent)
        #expect(event.sessionId == "s1")
        #expect(event.project == "/p")
        #expect(event.provider == "anthropic")

        let main = try read([assistant(ts: "2026-10-31T18:22:35.360Z")])
        #expect(main.events.map(\.client) == ["cli"])
        #expect(main.events.map(\.isSubagent) == [false])
    }

    @Test func carriesSpeedAndGeo() throws {
        let fast = #"{"input_tokens":0,"output_tokens":10,"speed":"fast","inference_geo":"us"}"#
        let result = try read([assistant(ts: "2026-10-31T18:22:35.360Z", usage: fast)])
        let event = try #require(result.events.first)
        #expect(event.speed == "fast")
        #expect(event.geo == "us")

        // Older transcripts have neither.
        let plain = try read([assistant(ts: "2026-10-31T18:22:35.360Z", usage: #"{"input_tokens":0,"output_tokens":10}"#)])
        #expect(plain.events.map(\.speed) == [nil])
        #expect(plain.events.map(\.geo) == [nil])
    }

    @Test func countsUnparseableLinesAsSkipped() throws {
        let result = try read([
            #"{"type":"assistant","message":{"usage":"#,
            #"{"type":"file-history-snapshot","messageId":"x","snapshot":{},"isSnapshotUpdate":false}"#,
        ])
        #expect(result.skipped == 1)
        #expect(result.events.isEmpty)
    }

    @Test func countsResponsesWithoutTimestampOrIdAsSkipped() throws {
        let noTimestamp = #"{"type":"assistant","requestId":"r1","message":{"id":"m1","role":"assistant","model":"claude-opus-4-5","usage":{"output_tokens":5}}}"#
        let noIds = #"{"type":"assistant","timestamp":"2026-10-31T18:22:35.360Z","message":{"role":"assistant","model":"claude-opus-4-5","usage":{"output_tokens":5}}}"#
        let result = try read([noTimestamp, noIds, assistant(ts: "2026-10-31T18:22:36.000Z")])
        #expect(result.skipped == 2)
        #expect(result.events.count == 1)
    }

    @Test func ignoresLinesThatAreNotResponses() throws {
        // Lines that carry a usage field, or a user message, without being the response of the model.
        let attachment = #"{"type":"attachment","timestamp":"2026-10-31T18:22:35.360Z","attachment":{"usage":{"output_tokens":9}}}"#
        let userMessageWithUsage = #"{"type":"user","timestamp":"2026-10-31T18:22:35.360Z","message":{"role":"user","content":"x","usage":{"output_tokens":9}}}"#
        let otherRole = #"{"type":"queue-operation","timestamp":"2026-10-31T18:22:35.360Z","requestId":"r9","message":{"id":"m9","role":"user","usage":{"output_tokens":9}}}"#
        let result = try read([attachment, userMessageWithUsage, otherRole])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 0)
    }

    @Test func theCursorAdvancesPastEveryLineRead() throws {
        let file = try newFile()
        try write([user(ts: "2026-10-31T18:22:30.000Z"), assistant(ts: "2026-10-31T18:22:35.360Z")], to: file)
        let first = try reader.read(file, from: nil)
        #expect(first.cursor.offset == first.cursor.size)
        #expect(first.quotas.isEmpty)

        // Nothing was appended: nothing is read, and the response is not reported twice.
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.isEmpty)
        #expect(second.cursor.offset == first.cursor.offset)
    }

    // MARK: Figures that are not counts

    /// A figure that passes as 0 says the format moved on, and nothing else would say so.
    @Test(arguments: [
        #"{"input_tokens":10,"output_tokens":"500"}"#,
        #"{"input_tokens":-7,"output_tokens":5}"#,
        #"{"input_tokens":10,"output_tokens":5.5}"#,
        #"{"input_tokens":10}"#,
        #"{"output_tokens":5}"#,
        #"{"input_tokens":null,"output_tokens":5}"#,
        #"{"prompt_tokens":10,"completion_tokens":5}"#,
        #"{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":"x"}"#,
        #"{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":-1}"#,
        #"{"input_tokens":10,"output_tokens":5,"cache_creation":{"ephemeral_1h_input_tokens":"x"}}"#,
        #"{"input_tokens":10,"output_tokens":5,"output_tokens_details":{"thinking_tokens":"x"}}"#,
    ])
    func aUsageThatIsNotCountsIsSkipped(usage: String) throws {
        let result = try read([assistant(ts: "2026-10-31T18:22:35.360Z", usage: usage)])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 1)
    }

    /// A figure no call could reach is a damaged log, and adding it up would trap: at every launch, since the row stays.
    @Test func aFigureBeyondAnyCallIsSkipped() throws {
        for usage in [#"{"input_tokens":9223372036854775807,"output_tokens":5}"#, #"{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":9223372036854775807}"#] {
            let result = try read([assistant(ts: "2026-10-31T18:22:35.360Z", usage: usage)])
            #expect(result.events.isEmpty, "\(usage)")
            #expect(result.skipped == 1, "\(usage)")
        }
    }

    @Test func theLargestRealisticFigureIsStillACount() throws {
        let result = try read([assistant(ts: "2026-10-31T18:22:35.360Z", usage: #"{"input_tokens":100000000000,"output_tokens":5}"#)])
        #expect(result.events.map(\.tokens) == [TokenCounts(input: 100_000_000_000, output: 5)])
    }

    @Test func aSideFigureThatIsMissingOrNullIsNone() throws {
        let result = try read([assistant(ts: "2026-10-31T18:22:35.360Z", usage: #"{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":null}"#)])
        #expect(result.events.map(\.tokens) == [TokenCounts(input: 10, output: 5)])
        #expect(result.skipped == 0)
    }

    /// Claude Code's own copy of a request embeds an assistant message, and thousands of them sit in healthy transcripts. It is no
    /// response, so its lack of usage says nothing. The second line has the word, as a line of any kind could.
    @Test func aLineThatOnlyCarriesAnAssistantMessageIsNoResponse() throws {
        let blob = #"{"type":"api-request-blob","timestamp":"2026-10-31T18:22:35.360Z","requestId":"r1","message":{"id":"m1","role":"assistant","content":"x"}}"#
        let mention = #"{"type":"api-request-blob","timestamp":"2026-10-31T18:22:35.360Z","requestId":"r2","note":"usage","other":{"usage":{}},"message":{"id":"m2","role":"assistant"}}"#
        let result = try read([blob, mention])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 0)
    }

    @Test func anAssistantLineWithNoUsageIsSkipped() throws {
        let noUsage = #"{"type":"assistant","timestamp":"2026-10-31T18:22:35.360Z","requestId":"r8","message":{"id":"m8","role":"assistant","content":"x"}}"#
        let nullUsage = #"{"type":"assistant","timestamp":"2026-10-31T18:22:35.360Z","requestId":"r7","message":{"id":"m7","role":"assistant","usage":null}}"#
        let lines = try read([noUsage, nullUsage])
        #expect(lines.events.isEmpty)
        #expect(lines.skipped == 2)

        let line = #"{"type":"assistant","timestamp":"2026-10-31T18:22:35.360Z","requestId":"r1","sessionId":"s1","message":{"id":"m1","role":"assistant","model":"claude-opus-4-5","token_stats":{"input_tokens":10}}}"#
        let result = try read([line])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 1)
    }

    /// A line that says it is a response owes usage wherever its message went. With nothing where the reader looks, the format
    /// changed, and the skipped count is what says so (spec 3, 5.4, 7): the message renamed, or its role.
    @Test(arguments: [
        #"{"type":"assistant","timestamp":"2026-10-31T18:22:35.360Z","requestId":"r1","response":{"id":"m1","role":"assistant","model":"claude-opus-4-5","usage":{"input_tokens":10,"output_tokens":5}}}"#,
        #"{"type":"assistant","timestamp":"2026-10-31T18:22:35.360Z","requestId":"r1","message":{"id":"m1","role":"model","model":"claude-opus-4-5","usage":{"input_tokens":10,"output_tokens":5}}}"#,
    ])
    func aResponseWhoseMessageMovedIsSkipped(line: String) throws {
        let result = try read([line, assistant(id: "m2", req: "r2", ts: "2026-10-31T18:22:36.000Z")])
        #expect(result.events.map(\.dedupKey) == ["claudeCode:r2"])
        #expect(result.skipped == 1)
    }

    // MARK: Blank ids

    /// As a key a blank id would merge every call that has it, a silent undercount.
    @Test func aBlankRequestIdFallsBackToTheMessageId() throws {
        let result = try read([
            assistant(id: "a", req: "", ts: "2026-10-31T18:22:35.360Z"),
            assistant(id: "b", req: "  ", ts: "2026-10-31T18:22:36.360Z"),
        ])
        #expect(result.events.map(\.dedupKey) == ["claudeCode:a", "claudeCode:b"])
        #expect(result.skipped == 0)
    }

    @Test func aResponseWithOnlyBlankIdsIsSkipped() throws {
        let result = try read([assistant(id: " ", req: "", ts: "2026-10-31T18:22:35.360Z")])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 1)
    }

    @Test func discoversNestedSubagentFiles() throws {
        let root = try makeTempDir()
        let transcript = root.appendingPathComponent("projects/p/s.jsonl")
        let subagent = root.appendingPathComponent("projects/p/s/subagents/agent-a.jsonl")
        let workflow = root.appendingPathComponent("projects/p/s/workflows/run-1/agent-b.jsonl")
        for file in [transcript, subagent, workflow] { try write([], to: file) }

        let found = try reader.discover(root: root)
        #expect(Set(found.map { $0.resolvingSymlinksInPath().path }) == Set([transcript, subagent, workflow].map { $0.resolvingSymlinksInPath().path }))
        #expect(found.count == 3)
    }

    @Test func discoveryTakesOnlyTranscriptsUnderProjects() throws {
        let root = try makeTempDir()
        let transcript = root.appendingPathComponent("projects/p/s.jsonl")
        try write([], to: transcript)
        // The prompt history next to `projects` is not a transcript; neither are a subagent's meta file or other files.
        for other in ["history.jsonl", "projects/p/s/subagents/agent-a.meta.json", "projects/p/notes.txt", "todos/t.jsonl"] {
            try write([], to: root.appendingPathComponent(other))
        }

        let found = try reader.discover(root: root)
        #expect(found.map { $0.resolvingSymlinksInPath().path } == [transcript.resolvingSymlinksInPath().path])
    }

    @Test func aMissingProjectsDirectoryHasNoFiles() throws {
        let root = try makeTempDir()
        let withoutProjects = try reader.discover(root: root)
        let withoutRoot = try reader.discover(root: root.appendingPathComponent("not-there"))
        #expect(withoutProjects.isEmpty)
        #expect(withoutRoot.isEmpty)
    }

    @Test func readsTheClaudeCodeSource() {
        #expect(reader.source == .claudeCode)
    }
}
