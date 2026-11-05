import Foundation
import Testing
@testable import TachoKit

struct GrokReaderTests {
    private let reader = GrokReader()

    private static let project = "%2FUsers%2Fdemo%2FCode%2Fdemo-app"
    private static let endedAt = "2026-10-20T08:15:42.250125+00:00"

    // MARK: Fixtures

    /// The figures of a turn, or of one model in a turn. `input` includes the cached part, as on disk.
    private func figures(input: Int = 0, output: Int = 0, cached: Int = 0, created: Int = 0, reasoning: Int = 0) -> [String: Any] {
        [
            "inputTokens": input, "outputTokens": output, "cachedReadTokens": cached, "cacheCreationTokens": created,
            "reasoningTokens": reasoning, "totalTokens": input + output, "modelCalls": 1, "costUsdTicks": 0,
        ]
    }

    private var someFigures: [String: Any] { figures(input: 100, output: 10) }

    /// One entry of `turns`. `modelUsage` nil leaves the key out.
    private func turn(
        number: Int? = 1,
        endedAt: String? = GrokReaderTests.endedAt,
        figures: [String: Any]? = nil,
        primary: String? = "grok-4.7-build",
        modelUsage: [String: Any]? = nil
    ) -> [String: Any] {
        var turn = figures ?? someFigures
        if let number { turn["turnNumber"] = number }
        if let endedAt { turn["endedAt"] = endedAt }
        if let primary { turn["primaryModelId"] = primary }
        if let modelUsage { turn["modelUsage"] = modelUsage }
        return turn
    }

    /// A `usage.json` as Grok writes it: one object holding the session's totals and its turns.
    private func usageJSON(_ turns: [Any]) -> String {
        jsonLine(["sessionId": "g1", "updatedAt": GrokReaderTests.endedAt, "session": someFigures, "turns": turns])
    }

    private func usageFile(project: String = GrokReaderTests.project, session: String = "g1") throws -> URL {
        try makeTempDir().appendingPathComponent("sessions").appendingPathComponent(project).appendingPathComponent(session).appendingPathComponent("usage.json")
    }

    /// Writes a `usage.json` with `turns` to a fresh file and reads it.
    private func read(_ turns: [Any]) throws -> ReadResult {
        let file = try usageFile()
        try write([usageJSON(turns)], to: file)
        return try reader.read(file, from: nil)
    }

    /// A line of `logs/unified.jsonl` with the billing config. A nil field is left out.
    private func billing(
        ts: String? = "2026-10-30T10:00:00.000Z",
        percent: Double? = 16,
        type: String? = "USAGE_PERIOD_TYPE_WEEKLY",
        end: String? = "2026-11-01T07:31:55.424Z"
    ) -> String {
        var period: [String: Any] = ["start": "2026-10-25T07:31:55.424Z"]
        if let type { period["type"] = type }
        if let end { period["end"] = end }
        var config: [String: Any] = ["currentPeriod": period]
        if let percent { config["creditUsagePercent"] = percent }
        var line: [String: Any] = ["src": "cli", "pid": 1, "lvl": "info", "msg": "billing: fetched credits config", "ctx": ["config": config]]
        if let ts { line["ts"] = ts }
        return jsonLine(line)
    }

    /// Another line of the log.
    private func otherLogLine(_ msg: String = "billing: refresh scheduled") -> String {
        jsonLine(["ts": "2026-10-30T10:00:00.000Z", "src": "cli", "pid": 1, "lvl": "info", "msg": msg])
    }

    private func logFile() throws -> URL {
        try makeTempDir().appendingPathComponent("logs/unified.jsonl")
    }

    /// Writes `lines` to a fresh log and reads it from its start.
    private func readLog(_ lines: [String]) throws -> ReadResult {
        let file = try logFile()
        try write(lines, to: file)
        return try reader.read(file, from: nil)
    }

    /// Sets the file's modification time, so a test does not depend on the clock's resolution.
    private func setModified(_ file: URL, to modified: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    // MARK: Turns

    @Test func turnsBecomeEventsPerModel() throws {
        let same = figures(input: 120_000, output: 1_500, cached: 90_000, created: 0, reasoning: 400)
        let result = try read([turn(number: 1, figures: same, modelUsage: ["grok-4.7-build": same])])
        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(event.tokens == TokenCounts(input: 30_000, output: 1_500, reasoning: 400, cacheRead: 90_000))
        #expect(event.dedupKey == "grok:g1:1:grok-4.7-build")
        #expect(event.project == "/Users/demo/Code/demo-app")
        #expect(result.quotas.isEmpty)
        #expect(result.skipped == 0)
    }

    @Test func attributesTheTurnFromItsPathAndItsRecord() throws {
        let result = try read([turn(number: 3, modelUsage: ["grok-4.7-build": someFigures])])
        let event = try #require(result.events.first)
        #expect(event.source == .grok)
        #expect(event.provider == "xai")
        #expect(event.model == "grok-4.7-build")
        #expect(event.sessionId == "g1")
        // The microseconds stay: `date` would cut them off.
        #expect(abs(event.time.timeIntervalSince(date("2026-10-20T08:15:42.000Z")) - 0.250125) < 1e-6)
        #expect(event.isSubagent == false)
        #expect(event.generationMs == nil)
        #expect(event.startTime == nil)
    }

    @Test func aTurnOfSeveralModelsGivesAnEventForEach() throws {
        let result = try read([
            turn(
                number: 2,
                figures: figures(input: 300, output: 30),
                primary: "grok-b",
                modelUsage: ["grok-b": figures(input: 200, output: 20), "grok-a": figures(input: 100, output: 10)]
            ),
        ])
        #expect(result.events.map(\.dedupKey) == ["grok:g1:2:grok-a", "grok:g1:2:grok-b"])
        #expect(result.events.map(\.model) == ["grok-a", "grok-b"])
        #expect(result.events.map(\.tokens) == [TokenCounts(input: 100, output: 10), TokenCounts(input: 200, output: 20)])
    }

    @Test func aTurnWithoutModelUsageCountsItsOwnFiguresForItsPrimaryModel() throws {
        let own = figures(input: 100, output: 10, cached: 40, reasoning: 5)
        let result = try read([
            turn(number: 1, figures: own, primary: "grok-a"),
            turn(number: 2, figures: own, primary: "grok-b", modelUsage: [:]),
        ])
        #expect(result.events.map(\.dedupKey) == ["grok:g1:1:grok-a", "grok:g1:2:grok-b"])
        #expect(result.events.map(\.model) == ["grok-a", "grok-b"])
        #expect(result.events.map(\.tokens) == [
            TokenCounts(input: 60, output: 10, reasoning: 5, cacheRead: 40), TokenCounts(input: 60, output: 10, reasoning: 5, cacheRead: 40),
        ])
    }

    @Test func splitsCacheReadsAndWritesOutOfInput() throws {
        let result = try read([turn(figures: figures(input: 1000, output: 10, cached: 300, created: 200))])
        #expect(result.events.map(\.tokens) == [TokenCounts(input: 500, output: 10, cacheRead: 300, cacheWrite5m: 200)])
    }

    @Test func clampsUncachedInputAtZero() throws {
        let result = try read([turn(figures: figures(input: 100, output: 10, cached: 80, created: 50))])
        #expect(result.events.map(\.tokens) == [TokenCounts(input: 0, output: 10, cacheRead: 80, cacheWrite5m: 50)])
    }

    @Test func aFigureAModelLacksIsZero() throws {
        let result = try read([turn(modelUsage: ["grok-a": ["outputTokens": 5]])])
        #expect(result.events.map(\.tokens) == [TokenCounts(output: 5)])
    }

    private static let tokenFigures = ["inputTokens", "outputTokens", "cachedReadTokens", "cacheCreationTokens", "reasoningTokens"]

    @Test func aFigureThatIsNotACountSkipsTheTurn() throws {
        // What would otherwise pass as 0, or take from the input, with nothing to say so.
        let wrong: [Any] = ["12", 1.5, true, ["n": 1], [1], -1]
        for figure in Self.tokenFigures {
            for value in wrong {
                var bad = figures(input: 100, output: 10)
                bad[figure] = value
                let inModelUsage = try read([turn(modelUsage: ["grok-a": bad])])
                #expect(inModelUsage.events.isEmpty, "\(figure) = \(value)")
                #expect(inModelUsage.skipped == 1, "\(figure) = \(value)")

                let onTheTurn = try read([turn(figures: bad)])
                #expect(onTheTurn.events.isEmpty, "\(figure) = \(value), no modelUsage")
                #expect(onTheTurn.skipped == 1, "\(figure) = \(value), no modelUsage")
            }
        }
    }

    @Test func aFigureThatIsNotACountLeavesTheOtherModelsOfTheTurn() throws {
        var bad = figures(input: 100, output: 10)
        bad["outputTokens"] = "ten"
        let result = try read([turn(modelUsage: ["grok-a": bad, "grok-b": someFigures])])
        #expect(result.events.map(\.model) == ["grok-b"])
        #expect(result.skipped == 1)
    }

    @Test func aNullSideFigureIsLikeAMissingOne() throws {
        // Reasoning and the cache are not there for every call, so a null says none. The call counts.
        for figure in ["reasoningTokens", "cachedReadTokens", "cacheCreationTokens"] {
            var figuresWithNull = figures(input: 100, output: 10)
            figuresWithNull[figure] = NSNull()
            let result = try read([turn(modelUsage: ["grok-a": figuresWithNull])])
            #expect(result.events.map(\.tokens) == [TokenCounts(input: 100, output: 10)], "\(figure)")
            #expect(result.skipped == 0, "\(figure)")
        }
    }

    @Test func aNullMainFigureSkipsTheTurn() throws {
        // Every call has an input and an output, so a null there is a figure lost, and reading it as 0 would hide that.
        for figure in ["inputTokens", "outputTokens"] {
            var figuresWithNull = figures(input: 100, output: 10)
            figuresWithNull[figure] = NSNull()
            let inModelUsage = try read([turn(modelUsage: ["grok-a": figuresWithNull])])
            #expect(inModelUsage.events.isEmpty, "\(figure)")
            #expect(inModelUsage.skipped == 1, "\(figure)")

            let onTheTurn = try read([turn(figures: figuresWithNull)])
            #expect(onTheTurn.events.isEmpty, "\(figure), no modelUsage")
            #expect(onTheTurn.skipped == 1, "\(figure), no modelUsage")
        }
    }

    @Test func aTurnWithNoFigureAtAllIsSkippedNotCountedAsZero() throws {
        let allNull: [String: Any] = ["inputTokens": NSNull(), "outputTokens": NSNull(), "reasoningTokens": NSNull()]
        let result = try read([
            turn(number: 1, modelUsage: ["grok-a": [String: Any]()]),
            turn(number: 2, modelUsage: ["grok-a": allNull]),
            turn(number: 3, figures: [:]),
            // `modelUsage` that is no object falls back to the turn, which has nothing either.
            { var bad = turn(number: 4, figures: [:]); bad["modelUsage"] = "none"; return bad }(),
        ])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 4)
    }

    @Test func aFigureBeyondAnyCallSkipsTheTurn() throws {
        let result = try read([turn(modelUsage: ["grok-a": ["inputTokens": Int.max, "outputTokens": 10]])])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 1)
    }

    @Test func aRealZeroIsACount() throws {
        let result = try read([turn(modelUsage: ["grok-a": figures(input: 0, output: 0)])])
        #expect(result.events.map(\.tokens) == [.zero])
        #expect(result.skipped == 0)
    }

    @Test func aFigureOutsideTheOnesItReadsIsNoReasonToSkip() throws {
        var other = figures(input: 100, output: 10)
        other["totalTokens"] = "many"
        other["costUsdTicks"] = 1.5
        let result = try read([turn(modelUsage: ["grok-a": other])])
        #expect(result.events.count == 1)
        #expect(result.skipped == 0)
    }

    @Test func aProjectNameThatDoesNotDecodeStaysAsItIs() throws {
        let file = try usageFile(project: "100%done")
        try write([usageJSON([turn()])], to: file)
        #expect(try reader.read(file, from: nil).events.map(\.project) == ["100%done"])
    }

    // MARK: Rewrites

    @Test func rereadsRewrittenUsageJson() throws {
        let file = try usageFile()
        try write([usageJSON([turn(number: 1, modelUsage: ["grok-a": someFigures])])], to: file)
        let first = try reader.read(file, from: nil)
        #expect(first.events.map(\.dedupKey) == ["grok:g1:1:grok-a"])

        try write([usageJSON([turn(number: 1, modelUsage: ["grok-a": someFigures]), turn(number: 2, modelUsage: ["grok-a": someFigures])])], to: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.map(\.dedupKey) == ["grok:g1:1:grok-a", "grok:g1:2:grok-a"])
    }

    @Test func anUnchangedFileGivesNothing() throws {
        let file = try usageFile()
        try write([usageJSON([turn()])], to: file)
        let first = try reader.read(file, from: nil)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.isEmpty)
        #expect(second.skipped == 0)
        #expect(second.cursor == first.cursor)
    }

    @Test func aRewriteOfTheSameSizeIsReadAgain() throws {
        let file = try usageFile()
        try write([usageJSON([turn(figures: figures(input: 100))])], to: file)
        try setModified(file, to: date("2026-11-01T00:00:00.000Z"))
        let first = try reader.read(file, from: nil)

        try write([usageJSON([turn(figures: figures(input: 200))])], to: file)
        try setModified(file, to: date("2026-11-01T00:00:01.000Z"))
        let second = try reader.read(file, from: first.cursor)
        #expect(second.cursor.size == first.cursor.size)
        #expect(second.events.map(\.tokens) == [TokenCounts(input: 200)])
    }

    @Test func aRewriteWithTheSameTimeIsReadAgain() throws {
        let file = try usageFile()
        let modified = date("2026-11-01T00:00:00.000Z")
        try write([usageJSON([turn(number: 1)])], to: file)
        try setModified(file, to: modified)
        let first = try reader.read(file, from: nil)

        try write([usageJSON([turn(number: 1), turn(number: 2)])], to: file)
        try setModified(file, to: modified)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.count == 2)
    }

    @Test func aRereadDoesNotGoByTheOffset() throws {
        let file = try usageFile()
        try write([usageJSON([turn()])], to: file)
        var cursor = try reader.read(file, from: nil).cursor

        // The file unchanged: an offset elsewhere does not make it new.
        cursor.offset = 0
        #expect(try reader.read(file, from: cursor).events.isEmpty)

        // The file changed: the read starts from the top, wherever the offset is.
        cursor.offset = 5
        cursor.size += 1
        #expect(try reader.read(file, from: cursor).events.count == 1)
    }

    @Test func theCursorDescribesTheFileItRead() throws {
        let file = try usageFile()
        try write([usageJSON([turn()])], to: file)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64)
        let cursor = try reader.read(file, from: nil).cursor
        #expect(cursor.size == size)
        #expect(cursor.offset == size)
        #expect(cursor.state == nil)
        #expect(cursor.complete == false)
    }

    // MARK: Files it cannot use

    @Test func aHalfWrittenFileCountsAsSkippedAndIsReadOnceItIsWhole() throws {
        let file = try usageFile()
        try write([String(usageJSON([turn()]).prefix(30))], to: file)
        let first = try reader.read(file, from: nil)
        #expect(first.events.isEmpty)
        #expect(first.skipped == 1)

        try write([usageJSON([turn()])], to: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.count == 1)
        #expect(second.skipped == 0)
    }

    @Test func aFileWithoutTurnsCountsAsSkipped() throws {
        let file = try usageFile()
        try write([jsonLine(["sessionId": "g1"])], to: file)
        let result = try reader.read(file, from: nil)
        #expect(result.events.isEmpty)
        #expect(result.skipped == 1)
    }

    @Test func noTurnsYetIsNoSkip() throws {
        let result = try read([])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 0)
    }

    @Test func countsATurnItCannotDecodeAsSkipped() throws {
        let result = try read([
            "not an object",
            turn(number: nil),
            turn(endedAt: nil),
            turn(endedAt: "yesterday"),
            // Without a model there is no key.
            turn(primary: nil),
            turn(modelUsage: ["grok-a": "not an object"]),
        ])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 6)
    }

    @Test func aModelItCannotDecodeLeavesTheOthersOfTheTurn() throws {
        let result = try read([turn(modelUsage: ["grok-a": "not an object", "grok-b": someFigures])])
        #expect(result.events.map(\.model) == ["grok-b"])
        #expect(result.skipped == 1)
    }

    // MARK: The billing log

    @Test func billingLogBecomesAWeeklySnapshot() throws {
        let line = #"{"ts":"2026-10-30T10:00:00.000Z","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":16.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-25T07:31:55.424Z","end":"2026-11-01T07:31:55.424Z"}}}}"#
        let result = try readLog([line])
        #expect(result.quotas == [
            QuotaSnapshot(
                provider: .xai, window: .weekly, usedPercent: 16, resetsAt: date("2026-11-01T07:31:55.424Z"),
                observedAt: date("2026-10-30T10:00:00.000Z"), origin: .grokLog
            ),
        ])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 0)
    }

    @Test func readsTheOffsetsTheLogWritesInADate() throws {
        let result = try readLog([billing(end: "2026-11-01T18:31:55.424+11:00")])
        #expect(result.quotas.map(\.resetsAt) == [date("2026-11-01T07:31:55.424Z")])
    }

    @Test func aPeriodThatIsNotAWeekGivesNoSnapshot() throws {
        // An account billed monthly has a percent of its month: calling it weekly would break the projection.
        let result = try readLog([
            billing(type: "USAGE_PERIOD_TYPE_MONTHLY"),
            billing(type: nil),
            jsonLine(["ts": "2026-10-30T10:00:00.000Z", "msg": "billing: fetched credits config", "ctx": ["config": NSNull()]]),
            // A period that says nothing else about itself is judged the same way, before anything else on the line.
            billing(ts: nil, percent: nil, type: "USAGE_PERIOD_TYPE_MONTHLY", end: nil),
        ])
        #expect(result.quotas.isEmpty)
        #expect(result.skipped == 0)
    }

    @Test func aWeekIsAWeekInAnyCase() throws {
        let result = try readLog([billing(type: "usage_period_type_weekly"), billing(type: "Weekly")])
        #expect(result.quotas.count == 2)
    }

    @Test func aPlanUsedUpShowsAsFull() throws {
        let result = try readLog([billing(percent: 120), billing(percent: 100), billing(percent: 37.5), billing(percent: 0)])
        #expect(result.quotas.map(\.usedPercent) == [100, 100, 37.5, 0])
    }

    @Test func aNegativePercentIsUnusable() throws {
        let result = try readLog([billing(percent: -5)])
        #expect(result.quotas.isEmpty)
        #expect(result.skipped == 1)
    }

    @Test func otherLinesOfTheLogAreNotItsOwn() throws {
        let result = try readLog([
            otherLogLine(),
            otherLogLine("not JSON follows"),
            "not json at all",
            "not json either: billing: fetched credits config",
            // The words inside another line's text.
            otherLogLine(#"saw "billing: fetched credits config" earlier"#),
            jsonLine(["ts": "2026-10-30T10:00:00.000Z", "msg": "retrying", "ctx": ["last": "billing: fetched credits config"]]),
        ])
        #expect(result.quotas.isEmpty)
        #expect(result.skipped == 0)
    }

    @Test func aLineNamingTheConfigInAnotherFieldIsNotTheConfig() throws {
        let period: [String: Any] = ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-11-01T07:31:55.424Z"]
        let line = jsonLine([
            "ts": "2026-10-30T10:00:00.000Z", "msg": "retrying", "of": "billing: fetched credits config",
            "ctx": ["config": ["creditUsagePercent": 16, "currentPeriod": period]],
        ])
        let result = try readLog([line])
        #expect(result.quotas.isEmpty)
        #expect(result.skipped == 0)
    }

    @Test func countsABillingLineItCannotDecodeAsSkipped() throws {
        let result = try readLog([
            #"{"msg":"billing: fetched credits config","ctx":{"#,
            billing(ts: nil),
            billing(percent: nil),
            billing(end: nil),
        ])
        #expect(result.quotas.isEmpty)
        #expect(result.skipped == 4)
    }

    @Test func tailsTheLogAcrossReads() throws {
        let file = try logFile()
        try write([otherLogLine(), billing(percent: 10)], to: file)
        let first = try reader.read(file, from: nil)
        #expect(first.quotas.map(\.usedPercent) == [10])

        let unchanged = try reader.read(file, from: first.cursor)
        #expect(unchanged.quotas.isEmpty)

        try append(billing(percent: 12) + "\n", to: file)
        let second = try reader.read(file, from: unchanged.cursor)
        #expect(second.quotas.map(\.usedPercent) == [12])
    }

    @Test func aHalfWrittenLogLineWaitsForTheNextRead() throws {
        let file = try logFile()
        let line = billing()
        try write([otherLogLine()], to: file)
        try append(String(line.prefix(40)), to: file)
        let first = try reader.read(file, from: nil)
        #expect(first.quotas.isEmpty)
        #expect(first.skipped == 0)

        try append(String(line.dropFirst(40)) + "\n", to: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.quotas.count == 1)
        #expect(second.skipped == 0)
    }

    @Test func aLogReplacedByAShorterOneIsReadFromItsStartOnce() throws {
        let file = try logFile()
        try write([otherLogLine(), otherLogLine(), billing(percent: 10), billing(percent: 11)], to: file)
        let first = try reader.read(file, from: nil)

        try write([billing(percent: 12)], to: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.quotas.map(\.usedPercent) == [12])
    }

    // MARK: Discovery

    @Test func discoversEveryUsageFileAndTheLog() throws {
        let root = try makeTempDir()
        let wanted = ["sessions/%2Fa/g1/usage.json", "sessions/%2Fa/g2/usage.json", "sessions/%2Fb/g3/usage.json", "logs/unified.jsonl"]
        let unwanted = [
            "sessions/%2Fa/g1/updates.jsonl", "sessions/%2Fa/g1/summary.json", "sessions/%2Fa/g1/deep/usage.json", "sessions/%2Fa/usage.json",
            "sessions/usage.json", "sessions/index.sqlite", "logs/mcp/unified.jsonl", "logs/other.jsonl", "auth.json",
        ]
        for path in wanted + unwanted {
            try write([], to: root.appendingPathComponent(path))
        }
        // A directory listing resolves the temporary directory's symlink, so the paths are compared resolved.
        let prefix = root.resolvingSymlinksInPath().path + "/"
        let found = try reader.discover(root: root).map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: "") }.sorted()
        #expect(found == wanted.sorted())
    }

    @Test func discoversNothingWithoutItsDirectories() throws {
        #expect(try reader.discover(root: try makeTempDir()).isEmpty)
    }

    @Test func discoversTheLogWithoutAnySession() throws {
        let root = try makeTempDir()
        try write([], to: root.appendingPathComponent("logs/unified.jsonl"))
        #expect(try reader.discover(root: root).map(\.lastPathComponent) == ["unified.jsonl"])
    }

    @Test func itsSourceIsGrok() {
        #expect(reader.source == .grok)
    }
}
