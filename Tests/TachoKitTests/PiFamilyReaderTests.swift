import Foundation
import Testing
@testable import TachoKit

struct PiFamilyReaderTests {
    private let omp = PiFamilyReader(source: .omp)
    private let pi = PiFamilyReader(source: .pi)

    // MARK: Fixtures

    /// The fixed-width slot on the first line of an omp session, which omp rewrites in place. pi has none.
    private var titleSlot: String {
        jsonLine(["type": "title", "v": 1, "title": "A title", "updatedAt": "2026-11-02T03:00:00.000Z", "pad": "        "])
    }

    private func header(id: String? = "s1", cwd: String = "/p", parentSession: String? = nil) -> String {
        var line: [String: Any] = ["type": "session", "version": 3, "timestamp": "2026-11-02T03:00:00.000Z", "cwd": cwd]
        if let id { line["id"] = id }
        if let parentSession { line["parentSession"] = parentSession }
        return jsonLine(line)
    }

    /// What an omp session starts with.
    private var preamble: [String] { [titleSlot, header()] }

    private var someUsage: [String: Any] { ["input": 1, "output": 2, "cacheRead": 3, "cacheWrite": 0] }

    private var zeroUsage: [String: Any] { ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0] }

    /// A `message` record of `role`. `fields` go in the message, next to its role, provider, model and usage.
    private func message(
        role: String = "assistant",
        id: String? = "e1",
        ts: String? = "2026-11-02T03:19:06.680Z",
        provider: String = "anthropic",
        model: String = "claude-opus-5-5",
        usage: [String: Any]? = nil,
        fields: [String: Any] = ["responseId": "resp1"]
    ) -> String {
        var body: [String: Any] = ["role": role, "provider": provider, "model": model, "usage": usage ?? someUsage]
        body.merge(fields) { _, new in new }
        var line: [String: Any] = ["type": "message", "parentId": "e0", "message": body]
        if let id { line["id"] = id }
        if let ts { line["timestamp"] = ts }
        return jsonLine(line)
    }

    /// A `model_usage` record: a side call outside the transcript.
    private func sideCall(id: String? = "mu1", ts: String? = "2026-11-02T03:19:06.680Z", usage: [String: Any]? = nil) -> String {
        var line: [String: Any] = [
            "type": "model_usage", "parentId": "e0", "purpose": "cache-warm", "provider": "anthropic", "model": "claude-opus-5-5",
            "usage": usage ?? someUsage,
        ]
        if let id { line["id"] = id }
        if let ts { line["timestamp"] = ts }
        return jsonLine(line)
    }

    private func newFile() throws -> URL {
        try makeTempDir().appendingPathComponent("2026-11-02_s1.jsonl")
    }

    /// Writes `lines` to a fresh file and reads it from its start.
    private func read(_ lines: [String], with reader: PiFamilyReader? = nil) throws -> ReadResult {
        let file = try newFile()
        try write(lines, to: file)
        return try (reader ?? omp).read(file, from: nil)
    }

    // MARK: Assistant messages

    // MARK: Figures that are not counts

    @Test func aUsageThatIsNotCountsIsSkipped() throws {
        let bad: [[String: Any]] = [
            ["input": "10", "output": 5],
            ["input": -7, "output": 5],
            ["input": 10, "output": 1.5],
            ["input": Int.max, "output": 5],
            ["input": 10],
            ["output": 5],
            ["promptTokens": 10, "completionTokens": 5],
            ["input": 10, "output": 5, "cacheRead": "x"],
            ["input": 10, "output": 5, "cacheWrite": -1],
            ["input": 10, "output": 5, "reasoning": "x"],
            ["input": 10, "output": 5, "cttl": ["ephemeral1h": "x"]],
        ]
        for figures in bad {
            for line in [message(usage: figures), sideCall(usage: figures)] {
                let result = try read([header(), line])
                #expect(result.events.isEmpty, "\(figures)")
                #expect(result.skipped == 1, "\(figures)")
            }
        }
    }

    @Test func aSideFigureThatIsMissingOrNullIsNone() throws {
        let result = try read([header(), message(usage: ["input": 10, "output": 5, "cacheRead": NSNull()])])
        #expect(result.events.map(\.tokens) == [TokenCounts(input: 10, output: 5)])
        #expect(result.skipped == 0)
    }

    @Test func aSideCallWithNoUsageIsSkipped() throws {
        let line = jsonLine(["type": "model_usage", "id": "mu1", "timestamp": "2026-11-02T03:19:06.680Z", "token_stats": ["input": 10]])
        let result = try read([header(), line])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 1)
    }

    @Test func anAssistantRecordWithNoUsageIsSkipped() throws {
        let line = jsonLine(["type": "message", "id": "e1", "timestamp": "2026-11-02T03:19:06.680Z", "message": ["role": "assistant", "responseId": "resp1", "token_stats": ["input": 10]]])
        let result = try read([header(), line])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 1)
    }

    @Test func readsOmpAssistantMessage() throws {
        let result = try read(preamble + [
            message(
                usage: ["input": 4, "output": 704, "cacheRead": 0, "cacheWrite": 15_903, "cttl": ["ephemeral1h": 15_903]],
                fields: ["completedAt": 1_793_682_935_820, "duration": 6822.13837499998, "ttft": 1289.1347090000054, "responseId": "resp1"]
            ),
        ])
        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(event.tokens == TokenCounts(input: 4, output: 704, cacheWrite1h: 15_903))
        #expect(event.time == ms(1_793_682_935_820))
        #expect(abs(try #require(event.generationMs) - 5533.003666) < 0.001)
        #expect(event.dedupKey == "omp:resp1")
        #expect(event.provider == "anthropic")
        #expect(event.model == "claude-opus-5-5")
        #expect(event.source == .omp)
        #expect(event.client == nil)
        #expect(event.startTime == nil)
        #expect(result.quotas.isEmpty)
        #expect(result.skipped == 0)
    }

    @Test func splitsCacheWritesByLifetime() throws {
        let result = try read(preamble + [
            message(usage: ["input": 0, "output": 0, "cacheWrite": 100, "cttl": ["ephemeral1h": 40]], fields: ["responseId": "a"]),
            message(usage: ["input": 0, "output": 0, "cacheWrite": 100, "cacheWrite1h": 30], fields: ["responseId": "b"]),
            // A session without the split: every write is a five-minute one.
            message(usage: ["input": 0, "output": 0, "cacheWrite": 100], fields: ["responseId": "c"]),
            // The figure Anthropic reports wins over the flat one.
            message(usage: ["input": 0, "output": 0, "cacheWrite": 100, "cttl": ["ephemeral1h": 40], "cacheWrite1h": 30], fields: ["responseId": "d"]),
        ])
        #expect(result.events.map(\.tokens) == [
            TokenCounts(cacheWrite5m: 60, cacheWrite1h: 40),
            TokenCounts(cacheWrite5m: 70, cacheWrite1h: 30),
            TokenCounts(cacheWrite5m: 100),
            TokenCounts(cacheWrite5m: 60, cacheWrite1h: 40),
        ])
    }

    @Test func aOneHourFigureAboveTheTotalLeavesNoNegativeFiveMinuteWrite() throws {
        let result = try read(preamble + [message(usage: ["input": 0, "output": 1, "cacheWrite": 10, "cttl": ["ephemeral1h": 40]])])
        #expect(result.events.map(\.tokens) == [TokenCounts(output: 1, cacheWrite1h: 40)])
    }

    @Test func aSideFigureTheUsageLacksIsZero() throws {
        let result = try read(preamble + [message(usage: ["input": 0, "output": 5])])
        #expect(result.events.map(\.tokens) == [TokenCounts(output: 5)])
    }

    @Test func aCallThatFailedAfterUsingTokensStillCounts() throws {
        let result = try read(preamble + [message(fields: ["stopReason": "error", "responseId": "r1"])])
        #expect(result.events.map(\.dedupKey) == ["omp:r1"])
    }

    @Test func skipsZeroUsageErrors() throws {
        let result = try read(preamble + [
            message(id: "e1", usage: zeroUsage, fields: ["stopReason": "error"]),
            message(id: "e2", usage: zeroUsage, fields: ["stop": "error"]),
            message(id: "e3", usage: zeroUsage, fields: ["stopReason": "aborted"]),
            sideCall(usage: zeroUsage),
        ])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 0)
    }

    @Test func onlyAssistantMessagesCount() throws {
        let result = try read(preamble + [
            message(role: "user"),
            message(role: "toolResult"),
            jsonLine(["type": "custom", "id": "c1", "usage": someUsage]),
        ])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 0)
    }

    @Test func aMessageWhoseUsageIsNoObjectIsSkipped() throws {
        let line = jsonLine(["type": "message", "id": "e1", "timestamp": "2026-11-02T03:19:06.680Z", "message": ["role": "assistant", "usage": "none"]])
        let result = try read(preamble + [line])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 1)
    }

    // MARK: Time

    @Test func timeIsTheCompletionElseTheRecordTimestamp() throws {
        let result = try read(preamble + [
            message(ts: "2026-11-02T03:19:06.680Z", fields: ["completedAt": 1_793_682_935_820, "timestamp": 1_793_682_000_000, "responseId": "a"]),
            message(ts: "2026-11-02T03:19:07.680Z", fields: ["timestamp": 1_793_682_000_000, "responseId": "b"]),
        ])
        #expect(result.events.map(\.time) == [ms(1_793_682_935_820), date("2026-11-02T03:19:07.680Z")])
    }

    @Test func generationTimeLeavesOutTheWaitForTheFirstToken() throws {
        let result = try read(preamble + [
            message(fields: ["duration": 3000, "ttft": 1000, "responseId": "both"]),
            message(fields: ["duration": 3000, "ttft": 1000, "durationMs": 9000, "responseId": "all"]),
            // Without the wait a duration would overstate the generation time, so there is none.
            message(fields: ["duration": 3000, "responseId": "durationOnly"]),
            message(fields: ["ttft": 1000, "responseId": "ttftOnly"]),
            message(fields: ["ttft": 1000, "durationMs": 9000, "responseId": "piDuration"]),
            message(fields: ["responseId": "none"]),
        ])
        #expect(result.events.map(\.generationMs) == [2000, 2000, nil, nil, 9000, nil])
    }

    // MARK: Keys

    @Test func keyIsTheResponseIdElseTheRespIdElseTheRecordId() throws {
        let result = try read(preamble + [
            message(id: "e1", fields: ["responseId": "a", "respId": "x"]),
            message(id: "e2", fields: ["respId": "b"]),
            message(id: "e3", fields: [:]),
        ])
        #expect(result.events.map(\.dedupKey) == ["omp:a", "omp:b", "omp:e3"])
    }

    @Test func aBlankIdIsNoId() throws {
        let result = try read(preamble + [
            message(id: "e1", fields: ["responseId": "", "respId": "b"]),
            message(id: "e2", fields: ["responseId": "  ", "respId": "\t\n"]),
            message(id: "e3", fields: ["responseId": "c", "respId": ""]),
        ])
        #expect(result.events.map(\.dedupKey) == ["omp:b", "omp:e2", "omp:c"])
        #expect(result.skipped == 0)
    }

    @Test func callsWithNothingButBlankIdsAreSkippedNotMergedIntoOne() throws {
        let result = try read(preamble + [
            message(id: "", fields: ["responseId": "", "respId": ""]),
            message(id: "  ", fields: [:]),
            sideCall(id: ""),
            sideCall(id: " "),
        ])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 4)
    }

    @Test func forkReplaysShareTheirKey() throws {
        let original = try read([titleSlot, header(id: "parent"), message(id: "e1", fields: ["responseId": "resp1"])])
        let fork = try read([titleSlot, header(id: "fork", parentSession: "/s/parent.jsonl"), message(id: "e1", fields: ["responseId": "resp1"])])
        #expect(original.events.map(\.dedupKey) == ["omp:resp1"])
        #expect(fork.events.map(\.dedupKey) == original.events.map(\.dedupKey))
    }

    // MARK: Side calls

    @Test func countsModelUsageSideChannel() throws {
        let line = #"{"type":"model_usage","id":"mu1","timestamp":"2026-11-02T03:19:06.680Z","purpose":"cache-warm","provider":"anthropic","model":"claude-opus-5-5","usage":{"input":2,"output":5,"cacheRead":180915,"cacheWrite":0}}"#
        let result = try read(preamble + [line])
        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(event.dedupKey == "omp:mu:mu1")
        #expect(event.tokens == TokenCounts(input: 2, output: 5, cacheRead: 180_915))
        #expect(event.time == date("2026-11-02T03:19:06.680Z"))
        #expect(event.generationMs == nil)
        #expect(event.provider == "anthropic")
        #expect(event.model == "claude-opus-5-5")
        #expect(event.sessionId == "s1")
        #expect(event.project == "/p")
    }

    @Test func aSideCallSplitsItsCacheWritesLikeAMessage() throws {
        let result = try read(preamble + [sideCall(usage: ["input": 0, "output": 0, "cacheWrite": 100, "cttl": ["ephemeral1h": 40]])])
        #expect(result.events.map(\.tokens) == [TokenCounts(cacheWrite5m: 60, cacheWrite1h: 40)])
    }

    // MARK: pi

    @Test func piUsesDurationMsReasoningAndCacheWrite1h() throws {
        let result = try read([
            header(),
            message(
                ts: "2026-11-02T03:19:06.680Z",
                provider: "xai",
                model: "grok-4.7",
                usage: ["input": 7686, "output": 422, "cacheRead": 1536, "cacheWrite": 0, "cacheWrite1h": 0, "reasoning": 248],
                fields: ["durationMs": 5610, "respId": "r9", "timestamp": 1_793_682_000_000]
            ),
        ], with: pi)
        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(event.tokens == TokenCounts(input: 7_686, output: 422, reasoning: 248, cacheRead: 1_536))
        #expect(event.generationMs == 5610)
        #expect(event.dedupKey == "pi:r9")
        #expect(event.source == .pi)
        #expect(event.provider == "xai")
        #expect(event.model == "grok-4.7")
        #expect(event.time == date("2026-11-02T03:19:06.680Z"))
        #expect(event.sessionId == "s1")
    }

    @Test func everyKeyStartsWithTheSource() throws {
        let result = try read([header(), message(fields: ["responseId": "a"]), sideCall(id: "b")], with: pi)
        #expect(result.events.map(\.dedupKey) == ["pi:a", "pi:mu:b"])
        #expect(result.events.map(\.source) == [.pi, .pi])
    }

    // MARK: Attribution

    @Test func marksSubagentsFromTheParentSessionHeader() throws {
        let result = try read([titleSlot, header(id: "child", cwd: "/work", parentSession: "/s/parent.jsonl"), message(), sideCall()])
        #expect(result.events.map(\.isSubagent) == [true, true])
        #expect(result.events.map(\.sessionId) == ["child", "child"])
        #expect(result.events.map(\.project) == ["/work", "/work"])
    }

    @Test func aSessionWithoutAParentIsTheUsers() throws {
        let result = try read(preamble + [message()])
        #expect(result.events.map(\.isSubagent) == [false])
    }

    @Test func aCallBeforeAnyHeaderStillCounts() throws {
        let result = try read([message()])
        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(event.sessionId == nil)
        #expect(event.project == nil)
        #expect(event.isSubagent == false)
        #expect(result.skipped == 0)
    }

    // MARK: Reading on

    @Test func keepsTheHeaderAcrossReads() throws {
        let file = try newFile()
        try write([titleSlot, header(id: "child", cwd: "/work", parentSession: "/s/parent.jsonl")], to: file)
        let first = try omp.read(file, from: nil)
        #expect(first.events.isEmpty)

        try append(message() + "\n", to: file)
        let second = try omp.read(file, from: first.cursor)
        let event = try #require(second.events.first)
        #expect(second.events.count == 1)
        #expect(event.sessionId == "child")
        #expect(event.project == "/work")
        #expect(event.isSubagent)
    }

    @Test func aSecondReadReturnsOnlyWhatIsNew() throws {
        let file = try newFile()
        try write(preamble + [message(fields: ["responseId": "a"])], to: file)
        let first = try omp.read(file, from: nil)
        let unchanged = try omp.read(file, from: first.cursor)
        #expect(unchanged.events.isEmpty)
        #expect(unchanged.cursor.offset == first.cursor.offset)

        try append(message(fields: ["responseId": "b"]) + "\n", to: file)
        let second = try omp.read(file, from: unchanged.cursor)
        #expect(second.events.map(\.dedupKey) == ["omp:b"])
    }

    @Test func aHalfWrittenLineWaitsForTheNextRead() throws {
        let file = try newFile()
        let line = message()
        try write(preamble, to: file)
        try append(String(line.prefix(40)), to: file)
        let first = try omp.read(file, from: nil)
        #expect(first.events.isEmpty)
        #expect(first.skipped == 0)

        try append(String(line.dropFirst(40)) + "\n", to: file)
        let second = try omp.read(file, from: first.cursor)
        #expect(second.events.map(\.dedupKey) == ["omp:resp1"])
        #expect(second.events.first?.sessionId == "s1")
        #expect(second.skipped == 0)
    }

    @Test func aFileReplacedByAShorterOneTakesNothingFromTheOld() throws {
        let file = try newFile()
        try write([
            titleSlot, header(id: "old", cwd: "/old", parentSession: "/s/parent.jsonl"),
            message(id: "e1", fields: ["responseId": "a"]), message(id: "e2", fields: ["responseId": "b"]),
        ], to: file)
        let first = try omp.read(file, from: nil)

        try write([message(id: "e3", fields: ["responseId": "c"])], to: file)
        let second = try omp.read(file, from: first.cursor)
        let event = try #require(second.events.first)
        #expect(second.events.map(\.dedupKey) == ["omp:c"])
        #expect(event.sessionId == nil)
        #expect(event.project == nil)
        #expect(event.isSubagent == false)
    }

    @Test func aCursorThatLostItsStateReadsTheFileAgain() throws {
        // The header exists only at the top of the file: going on without it would leave every later call unattributed.
        for state in [nil, Data("not json".utf8)] {
            let file = try newFile()
            try write(preamble + [message(fields: ["responseId": "a"])], to: file)
            var cursor = try omp.read(file, from: nil).cursor
            cursor.state = state

            try append(message(fields: ["responseId": "b"]) + "\n", to: file)
            let result = try omp.read(file, from: cursor)
            #expect(result.events.map(\.dedupKey) == ["omp:a", "omp:b"])
            #expect(result.events.map(\.sessionId) == ["s1", "s1"])
        }
    }

    // MARK: Lines it cannot use

    @Test func readsRecordsWhateverTheirSpacing() throws {
        let result = try read([
            #"{ "type": "session", "id": "s1", "cwd": "/p" }"#,
            #"{ "type": "message", "id": "e1", "timestamp": "2026-11-02T03:19:06.680Z", "message": { "role": "assistant", "responseId": "a", "usage": { "input": 0, "output": 5 } } }"#,
        ])
        #expect(result.events.map(\.dedupKey) == ["omp:a"])
        #expect(result.events.map(\.sessionId) == ["s1"])
    }

    @Test func countsARecordItCannotDecodeAsSkipped() throws {
        let result = try read(preamble + [
            #"{"type":"message","usage":{"#,
            // No time at all.
            message(ts: nil),
            sideCall(ts: nil),
            // No key at all.
            message(id: nil, fields: [:]),
            sideCall(id: nil),
            // A header that names no session.
            header(id: nil),
        ])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 6)
    }

    @Test func aHeaderWithoutAnIdLeavesTheSessionAsItWas() throws {
        let result = try read(preamble + [header(id: nil, cwd: "/elsewhere"), message()])
        #expect(result.events.map(\.sessionId) == ["s1"])
        #expect(result.events.map(\.project) == ["/p"])
    }

    @Test func aLineThatIsNotARecordOfItsOwnIsNoSkip() throws {
        let result = try read(preamble + ["not json at all", #"{"type":"message","message":{"role":"toolResult"#, message(fields: ["responseId": "a"])])
        #expect(result.events.map(\.dedupKey) == ["omp:a"])
        #expect(result.skipped == 0)
    }

    // MARK: Discovery

    @Test func discoversEveryJsonlUnderAgentSessions() throws {
        let root = try makeTempDir()
        let wanted = ["agent/sessions/--p--/a.jsonl", "agent/sessions/--p--/a/0-sub.jsonl", "agent/sessions/b.jsonl"]
        let unwanted = ["agent/sessions/--p--/notes.txt", "agent/sessions/--p--/c.jsonl.bak", "agent/other.jsonl", "sessions/d.jsonl"]
        for path in wanted + unwanted {
            try write([], to: root.appendingPathComponent(path))
        }
        let found = try omp.discover(root: root).map(\.lastPathComponent).sorted()
        #expect(found == ["0-sub.jsonl", "a.jsonl", "b.jsonl"])
    }

    @Test func discoversNothingWithoutASessionsDirectory() throws {
        #expect(try pi.discover(root: try makeTempDir()).isEmpty)
    }

    @Test func itsSourceIsTheOneItWasGiven() {
        #expect(omp.source == .omp)
        #expect(pi.source == .pi)
    }
}
