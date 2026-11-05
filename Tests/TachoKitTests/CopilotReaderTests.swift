import Foundation
import Testing
@testable import TachoKit

struct CopilotReaderTests {
    private let reader = CopilotReader()

    private static let timestamp = "2026-11-02T03:19:06.680Z"

    // MARK: Fixtures

    private func event(type: String, ts: String? = CopilotReaderTests.timestamp, data: [String: Any]) -> String {
        var line: [String: Any] = ["type": type, "id": "e1", "parentId": NSNull(), "data": data]
        if let ts { line["timestamp"] = ts }
        return jsonLine(line)
    }

    /// The first line of a session. Its `cwd` is under `context`.
    private func sessionStart(cwd: String? = "/Users/x/proj") -> String {
        var context: [String: Any] = ["gitRoot": "/Users/x"]
        if let cwd { context["cwd"] = cwd }
        return event(type: "session.start", data: ["sessionId": "sess1", "version": 1, "context": context])
    }

    /// A hook firing. Its `cwd` is under `input`.
    private func hookStart(cwd: String = "/Users/x/hook") -> String {
        event(type: "hook.start", data: ["hookInvocationId": "h1", "hookType": "userPromptSubmitted", "input": ["cwd": cwd]])
    }

    /// A `session.usage_record` as Copilot writes it: `inputTokens` includes the cache, and `provider` is an object. A nil field is left out.
    private func usageRecord(
        ts: String? = CopilotReaderTests.timestamp,
        input: Int = 100,
        output: Int = 10,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int = 0,
        duration: Double? = 3000,
        ttft: Double? = 1000,
        model: String? = "gpt-6-luna",
        usageId: String? = "u1",
        session: String? = "sess1"
    ) -> String {
        var accounting: [String: Any] = ["sequence": 1]
        if let usageId { accounting["usageId"] = usageId }
        if let session { accounting["sourceSessionId"] = session }
        var usage: [String: Any] = [
            "inputTokens": input, "outputTokens": output, "cacheReadTokens": cacheRead, "cacheWriteTokens": cacheWrite, "reasoningTokens": reasoning,
            "provider": ["id": "p", "kind": "k", "label": "l"], "apiCallId": "call-1", "accounting": accounting,
        ]
        if let duration { usage["duration"] = duration }
        if let ttft { usage["timeToFirstTokenMs"] = ttft }
        if let model { usage["model"] = model }
        return event(type: "session.usage_record", ts: ts, data: ["usage": usage])
    }

    private func newFile() throws -> URL {
        try makeTempDir().appendingPathComponent("session-state/sess1/events.jsonl")
    }

    /// Writes `lines` to a fresh file and reads it from its start.
    private func read(_ lines: [String]) throws -> ReadResult {
        let file = try newFile()
        try write(lines, to: file)
        return try reader.read(file, from: nil)
    }

    // MARK: Usage records

    @Test func subtractsCacheFromInputTokens() throws {
        let result = try read([usageRecord(input: 20_976, output: 201, cacheRead: 20_831, cacheWrite: 142, reasoning: 180)])
        #expect(result.events.map(\.tokens) == [TokenCounts(input: 3, output: 201, reasoning: 180, cacheRead: 20_831, cacheWrite5m: 142)])
        #expect(result.skipped == 0)
    }

    @Test func clampsUncachedInputAtZero() throws {
        let result = try read([usageRecord(input: 100, cacheRead: 80, cacheWrite: 50)])
        #expect(result.events.map(\.tokens) == [TokenCounts(input: 0, output: 10, cacheRead: 80, cacheWrite5m: 50)])
    }

    @Test func aSideFigureTheUsageLacksIsZero() throws {
        let line = event(type: "session.usage_record", data: ["usage": ["inputTokens": 0, "outputTokens": 5, "accounting": ["usageId": "u1"]]])
        let result = try read([line])
        #expect(result.events.map(\.tokens) == [TokenCounts(output: 5)])
    }

    @Test func exactGenerationIsDurationMinusTtft() throws {
        let result = try read([usageRecord(duration: 3670, ttft: 3579.560125)])
        let event = try #require(result.events.first)
        #expect(abs(try #require(event.generationMs) - 90.439875) < 0.001)
    }

    @Test func generationTimeNeedsBothFigures() throws {
        let result = try read([
            usageRecord(duration: 3000, ttft: nil, usageId: "a"),
            usageRecord(duration: nil, ttft: 1000, usageId: "b"),
            usageRecord(duration: nil, ttft: nil, usageId: "c"),
        ])
        #expect(result.events.map(\.generationMs) == [nil, nil, nil])
    }

    @Test func keysByUsageIdAndSession() throws {
        let result = try read([usageRecord(model: "gpt-6-luna", usageId: "u1", session: "sess1")])
        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(event.dedupKey == "copilot:u1")
        #expect(event.sessionId == "sess1")
        #expect(event.provider == "copilot")
        #expect(event.model == "gpt-6-luna")
    }

    @Test func aRecordIsTimedByItsTimestampAndIsTheUsers() throws {
        let result = try read([usageRecord(ts: "2026-11-02T03:19:07.123Z")])
        let event = try #require(result.events.first)
        #expect(event.time == date("2026-11-02T03:19:07.123Z"))
        #expect(event.source == .copilot)
        #expect(event.client == nil)
        #expect(event.isSubagent == false)
        #expect(event.startTime == nil)
        #expect(result.quotas.isEmpty)
    }

    @Test func aRecordWithoutASessionOrAModelStillCounts() throws {
        let result = try read([usageRecord(model: nil, session: nil)])
        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(event.sessionId == nil)
        #expect(event.model == nil)
        #expect(result.skipped == 0)
    }

    @Test func onlyUsageRecordsCount() throws {
        let figures: [String: Any] = ["inputTokens": 100, "outputTokens": 10, "accounting": ["usageId": "u1"]]
        // Each line names the record's type, so that it gets past the prefilter and its own type is what decides.
        let result = try read([
            event(type: "assistant.message", data: ["usage": figures, "about": "session.usage_record"]),
            event(type: "session.usage_checkpoint", data: ["usage": figures, "about": "session.usage_record"]),
            event(type: "session.shutdown", data: ["about": "session.usage_record", "accountingSnapshot": ["tokenDetails": ["input": ["tokenCount": 100]]]]),
        ])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 0)
    }

    // MARK: The project

    @Test func projectComesFromTheSessionStartEvent() throws {
        let inOneRead = try read([sessionStart(cwd: "/Users/x/proj"), usageRecord()])
        #expect(inOneRead.events.map(\.project) == ["/Users/x/proj"])

        let file = try newFile()
        try write([sessionStart(cwd: "/Users/x/proj")], to: file)
        let first = try reader.read(file, from: nil)
        #expect(first.events.isEmpty)

        try append(usageRecord() + "\n", to: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.map(\.project) == ["/Users/x/proj"])
    }

    @Test func aHookGivesTheProjectWhenTheStartEventHasNone() throws {
        let result = try read([sessionStart(cwd: nil), hookStart(cwd: "/Users/x/hook"), usageRecord()])
        #expect(result.events.map(\.project) == ["/Users/x/hook"])
    }

    @Test func theFirstCwdInTheFileWins() throws {
        let startFirst = try read([sessionStart(cwd: "/first"), hookStart(cwd: "/second"), usageRecord()])
        #expect(startFirst.events.map(\.project) == ["/first"])

        let hookFirst = try read([hookStart(cwd: "/first"), sessionStart(cwd: "/second"), usageRecord()])
        #expect(hookFirst.events.map(\.project) == ["/first"])
    }

    @Test func theFirstCwdWinsOnALineParsedForAnotherReason() throws {
        // Once the project is known a `cwd` alone is not parsed, so these lines name a usage record to get past the prefilter.
        let result = try read([
            sessionStart(cwd: "/first"),
            event(type: "session.start", data: ["about": "session.usage_record", "context": ["cwd": "/second"]]),
            event(type: "hook.start", data: ["about": "session.usage_record", "input": ["cwd": "/third"]]),
            usageRecord(),
        ])
        #expect(result.events.map(\.project) == ["/first"])
    }

    @Test func theFirstCwdStaysAcrossReads() throws {
        let file = try newFile()
        try write([sessionStart(cwd: "/first")], to: file)
        let first = try reader.read(file, from: nil)

        try append(hookStart(cwd: "/second") + "\n" + usageRecord() + "\n", to: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.map(\.project) == ["/first"])
    }

    @Test func aCallBeforeAnyCwdHasNoProjectButLaterOnesDo() throws {
        let result = try read([usageRecord(usageId: "a"), hookStart(cwd: "/late"), usageRecord(usageId: "b")])
        #expect(result.events.map(\.project) == [nil, "/late"])
    }

    @Test func aCwdOnAnotherEventIsNotTheProject() throws {
        let result = try read([event(type: "tool.execution_start", data: ["input": ["cwd": "/elsewhere"], "context": ["cwd": "/elsewhere"]]), usageRecord()])
        #expect(result.events.map(\.project) == [nil])
    }

    // MARK: Reading on

    @Test func aSecondReadReturnsOnlyWhatIsNew() throws {
        let file = try newFile()
        try write([sessionStart(), usageRecord(usageId: "a")], to: file)
        let first = try reader.read(file, from: nil)
        let unchanged = try reader.read(file, from: first.cursor)
        #expect(unchanged.events.isEmpty)
        #expect(unchanged.cursor.offset == first.cursor.offset)

        try append(usageRecord(usageId: "b") + "\n", to: file)
        let second = try reader.read(file, from: unchanged.cursor)
        #expect(second.events.map(\.dedupKey) == ["copilot:b"])
    }

    @Test func aHalfWrittenLineWaitsForTheNextRead() throws {
        let file = try newFile()
        let line = usageRecord()
        try write([sessionStart()], to: file)
        try append(String(line.prefix(40)), to: file)
        let first = try reader.read(file, from: nil)
        #expect(first.events.isEmpty)
        #expect(first.skipped == 0)

        try append(String(line.dropFirst(40)) + "\n", to: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.map(\.project) == ["/Users/x/proj"])
        #expect(second.skipped == 0)
    }

    @Test func aFileReplacedByAShorterOneTakesNothingFromTheOld() throws {
        let file = try newFile()
        try write([sessionStart(cwd: "/old"), usageRecord(usageId: "a"), usageRecord(usageId: "b")], to: file)
        let first = try reader.read(file, from: nil)

        try write([usageRecord(usageId: "c")], to: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.map(\.dedupKey) == ["copilot:c"])
        #expect(second.events.map(\.project) == [nil])
    }

    @Test func aCursorThatLostItsStateReadsTheFileAgain() throws {
        // The project exists only near the top of the file: going on without it would leave every later call unattributed.
        for state in [nil, Data("not json".utf8)] {
            let file = try newFile()
            try write([sessionStart(), usageRecord(usageId: "a")], to: file)
            var cursor = try reader.read(file, from: nil).cursor
            cursor.state = state

            try append(usageRecord(usageId: "b") + "\n", to: file)
            let result = try reader.read(file, from: cursor)
            #expect(result.events.map(\.dedupKey) == ["copilot:a", "copilot:b"])
            #expect(result.events.map(\.project) == ["/Users/x/proj", "/Users/x/proj"])
        }
    }

    // MARK: Lines it cannot use

    @Test func readsRecordsWhateverTheirSpacing() throws {
        let result = try read([
            #"{ "type": "session.start", "data": { "context": { "cwd": "/p" } } }"#,
            #"{ "type": "session.usage_record", "timestamp": "2026-11-02T03:19:06.680Z", "data": { "usage": { "inputTokens": 0, "outputTokens": 5, "accounting": { "usageId": "a" } } } }"#,
        ])
        #expect(result.events.map(\.dedupKey) == ["copilot:a"])
        #expect(result.events.map(\.project) == ["/p"])
    }

    @Test func countsARecordItCannotDecodeAsSkipped() throws {
        let result = try read([
            sessionStart(),
            #"{"type":"session.usage_record","data":{"#,
            event(type: "session.usage_record", data: ["other": 1]),
            // No key. `apiCallId` is in the fixture and must not stand in for one.
            usageRecord(usageId: nil),
            usageRecord(ts: nil),
            usageRecord(ts: "yesterday"),
        ])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 5)
    }

    @Test func linesThatAreNotItsOwnAreNoSkip() throws {
        let result = try read([
            sessionStart(),
            "not json at all",
            "not json either: session.usage_record",
            // A mention inside a text has its quotes escaped.
            event(type: "assistant.message", data: ["text": #"saw "session.usage_record" and "cwd" earlier"#]),
            usageRecord(),
        ])
        #expect(result.events.count == 1)
        #expect(result.skipped == 0)

        // The word alone is no `cwd`, also while the project is unknown.
        let unknown = try read(["not json either: cwd", usageRecord()])
        #expect(unknown.skipped == 0)
    }

    @Test func onceTheProjectIsKnownOtherCwdsAreNotParsed() throws {
        let unparseable = #"{"type":"hook.start","data":{"input":{"cwd":"/cut"#
        let known = try read([sessionStart(), unparseable, usageRecord()])
        #expect(known.skipped == 0)

        let unknown = try read([unparseable, usageRecord()])
        #expect(unknown.skipped == 1)
    }

    // MARK: Discovery

    // MARK: Figures that are not counts

    private func usageRecord(figures: [String: Any]) -> String {
        var usage = figures
        usage["accounting"] = ["usageId": "u1", "sourceSessionId": "sess1"]
        usage["model"] = "gpt-6-luna"
        return event(type: "session.usage_record", data: ["usage": usage])
    }

    @Test func aUsageThatIsNotCountsIsSkipped() throws {
        let bad: [[String: Any]] = [
            ["inputTokens": "100", "outputTokens": 10],
            ["inputTokens": -7, "outputTokens": 10],
            ["inputTokens": 100, "outputTokens": 1.5],
            ["inputTokens": Int.max, "outputTokens": 10],
            ["inputTokens": 100],
            ["outputTokens": 10],
            ["promptTokens": 100, "completionTokens": 10],
            ["inputTokens": 100, "outputTokens": 10, "cacheReadTokens": "x"],
            ["inputTokens": 100, "outputTokens": 10, "reasoningTokens": -1],
        ]
        for figures in bad {
            let result = try read([usageRecord(figures: figures)])
            #expect(result.events.isEmpty, "\(figures)")
            #expect(result.skipped == 1, "\(figures)")
        }
    }

    @Test func aSideFigureThatIsMissingOrNullIsNone() throws {
        let result = try read([usageRecord(figures: ["inputTokens": 100, "outputTokens": 10, "cacheReadTokens": NSNull()])])
        #expect(result.events.map(\.tokens) == [TokenCounts(input: 100, output: 10)])
        #expect(result.skipped == 0)
    }

    @Test func aBlankUsageIdIsSkipped() throws {
        let result = try read([usageRecord(usageId: ""), usageRecord(usageId: "  ")])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 2)
    }

    @Test func discoversTheEventsOfEverySession() throws {
        let root = try makeTempDir()
        let wanted = ["session-state/a/events.jsonl", "session-state/b/events.jsonl"]
        let unwanted = [
            "session-state/a/workspace.yaml", "session-state/a/deep/events.jsonl", "session-state/events.jsonl",
            "session-state/c/other.jsonl", "logs/events.jsonl", "events.jsonl",
        ]
        for path in wanted + unwanted {
            try write([], to: root.appendingPathComponent(path))
        }
        // A directory listing resolves the temporary directory's symlink, so the paths are compared resolved.
        let prefix = root.resolvingSymlinksInPath().path + "/"
        let found = try reader.discover(root: root).map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: "") }.sorted()
        #expect(found == wanted)
    }

    @Test func discoversNothingWithoutASessionStateDirectory() throws {
        #expect(try reader.discover(root: try makeTempDir()).isEmpty)
    }

    @Test func itsSourceIsCopilot() {
        #expect(reader.source == .copilot)
    }
}
