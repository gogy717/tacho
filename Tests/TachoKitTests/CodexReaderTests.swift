import Foundation
import Testing
@testable import TachoKit

struct CodexReaderTests {
    private let reader = CodexReader()

    // MARK: Fixtures

    /// A usage object as Codex writes it: `input` is the whole prompt, `cached` and `cacheWrite` are parts of it,
    /// `output` includes `reasoning`.
    private func usage(_ input: Int, _ cached: Int, _ cacheWrite: Int, _ output: Int, _ reasoning: Int, _ total: Int) -> [String: Any] {
        [
            "input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": cacheWrite,
            "output_tokens": output, "reasoning_output_tokens": reasoning, "total_tokens": total,
        ]
    }

    /// 2026-11-01T00:00:`second`.000Z
    private func at(_ second: Int) -> String {
        String(format: "2026-11-01T00:00:%02ld.000Z", second)
    }

    private func record(type: String, ordinal: Int?, ts: String?, payload: [String: Any]) -> String {
        var line: [String: Any] = ["type": type, "payload": payload]
        if let ordinal { line["ordinal"] = ordinal }
        if let ts { line["timestamp"] = ts }
        return jsonLine(line)
    }

    private func meta(
        id: String = "t1",
        cwd: String = "/p",
        originator: String = "codex-tui",
        provider: String? = "openai",
        historyStart: Int? = nil,
        threadSource: String? = nil,
        source: Any? = nil,
        ordinal: Int? = 0
    ) -> String {
        var payload: [String: Any] = ["id": id, "session_id": id, "cwd": cwd, "originator": originator, "cli_version": "0.0.0"]
        if let provider { payload["model_provider"] = provider }
        if let historyStart { payload["subagent_history_start_ordinal"] = historyStart }
        if let threadSource { payload["thread_source"] = threadSource }
        if let source { payload["source"] = source }
        return record(type: "session_meta", ordinal: ordinal, ts: at(0), payload: payload)
    }

    /// The turn context carries a `cwd` of its own: the project must still come from the session meta.
    private func turnContext(model: String? = "gpt-5.6-sol", ordinal: Int? = 1) -> String {
        var payload: [String: Any] = ["turn_id": "u1", "cwd": "/elsewhere"]
        if let model { payload["model"] = model }
        return record(type: "turn_context", ordinal: ordinal, ts: at(1), payload: payload)
    }

    /// A `token_count`: `last` is what the call used, `total` the thread's running figures after it. A nil figure is left out.
    private func tokenCount(
        ordinal: Int? = nil,
        ts: String? = "2026-11-01T00:00:02.000Z",
        last: [String: Any]?,
        total: [String: Any]?,
        rateLimits: [String: Any]? = nil
    ) -> String {
        var info: [String: Any] = ["model_context_window": 272_000]
        if let last { info["last_token_usage"] = last }
        if let total { info["total_token_usage"] = total }
        return tokenCount(ordinal: ordinal, ts: ts, info: info, rateLimits: rateLimits)
    }

    /// A `token_count` with `info` as given: `NSNull()` for the first count of a thread, which carries rate limits only.
    private func tokenCount(ordinal: Int?, ts: String?, info: Any, rateLimits: [String: Any]?) -> String {
        var payload: [String: Any] = ["type": "token_count", "info": info]
        if let rateLimits { payload["rate_limits"] = rateLimits }
        return record(type: "event_msg", ordinal: ordinal, ts: ts, payload: payload)
    }

    private func window(_ used: Double, minutes: Int?, resetsAt: Int? = nil, resetsIn: Int? = nil) -> [String: Any] {
        var window: [String: Any] = ["used_percent": used]
        if let minutes { window["window_minutes"] = minutes }
        if let resetsAt { window["resets_at"] = resetsAt }
        if let resetsIn { window["resets_in_seconds"] = resetsIn }
        return window
    }

    /// `limitId` names the bucket the limits belong to: "codex" is the plan's. nil leaves the key out, `NSNull()` writes a null.
    private func rateLimits(
        limitId: Any? = "codex",
        limitName: String? = nil,
        primary: [String: Any]? = nil,
        secondary: [String: Any]? = nil,
        plan: String? = "plus"
    ) -> [String: Any] {
        var limits: [String: Any] = ["limit_name": limitName ?? NSNull() as Any, "credits": ["has_credits": false]]
        if let limitId { limits["limit_id"] = limitId }
        if let primary { limits["primary"] = primary }
        if let secondary { limits["secondary"] = secondary }
        if let plan { limits["plan_type"] = plan }
        return limits
    }

    /// What every thread starts with: the session meta, then the first turn's context.
    private var preamble: [String] { [meta(), turnContext()] }

    private func newFile(_ name: String = "rollout-x.jsonl") throws -> URL {
        try makeTempDir().appendingPathComponent(name)
    }

    /// Writes `lines` to a fresh file and reads it from its start.
    private func read(_ lines: [String]) throws -> ReadResult {
        let file = try newFile()
        try write(lines, to: file)
        return try reader.read(file, from: nil)
    }

    // MARK: Counting

    @Test func countsLastUsageWhenTotalChanges() throws {
        let result = try read(preamble + [
            tokenCount(ordinal: 2, ts: at(10), last: usage(1000, 0, 0, 10, 0, 1010), total: usage(1000, 0, 0, 10, 0, 1010)),
            tokenCount(ordinal: 3, ts: at(20), last: usage(2000, 1500, 0, 20, 0, 2020), total: usage(3000, 1500, 0, 30, 0, 3030)),
        ])
        #expect(result.events.count == 2)
        #expect(result.events.map(\.tokens) == [TokenCounts(input: 1_000, output: 10), TokenCounts(input: 500, output: 20, cacheRead: 1_500)])
        #expect(result.events.map(\.time) == [date(at(10)), date(at(20))])
        #expect(result.skipped == 0)
    }

    @Test func skipsUnchangedTotals() throws {
        let second = usage(3000, 1500, 0, 30, 0, 3030)
        let result = try read(preamble + [
            tokenCount(ordinal: 2, last: usage(1000, 0, 0, 10, 0, 1010), total: usage(1000, 0, 0, 10, 0, 1010)),
            tokenCount(ordinal: 3, last: usage(2000, 1500, 0, 20, 0, 2020), total: second),
            // Codex sends the count again after a rate-limit update, and after compaction with the context size as `last`: no call was made.
            tokenCount(ordinal: 4, last: usage(0, 0, 0, 0, 0, 25_934), total: second),
        ])
        #expect(result.events.count == 2)
        #expect(result.skipped == 0)
    }

    @Test func splitsCachedAndCacheWriteOutOfInput() throws {
        let call = usage(31_099, 28_032, 0, 174, 104, 31_273)
        let result = try read(preamble + [tokenCount(ordinal: 2, last: call, total: call)])
        #expect(result.events.map(\.tokens) == [TokenCounts(input: 3_067, output: 174, reasoning: 104, cacheRead: 28_032)])
    }

    @Test func countsCacheWritesAsFiveMinuteWrites() throws {
        let call = usage(1000, 600, 300, 5, 2, 1005)
        let result = try read(preamble + [tokenCount(ordinal: 2, last: call, total: call)])
        #expect(result.events.map(\.tokens) == [TokenCounts(input: 100, output: 5, reasoning: 2, cacheRead: 600, cacheWrite5m: 300)])
        #expect(result.events.map(\.dedupKey) == ["codex:t1:1000,600,300,5,2,1005"])
    }

    @Test func clampsUncachedInputAtZero() throws {
        let result = try read(preamble + [tokenCount(ordinal: 2, last: usage(100, 80, 50, 0, 0, 100), total: usage(100, 80, 50, 0, 0, 100))])
        let event = try #require(result.events.first)
        #expect(event.tokens.input == 0)
        #expect(event.tokens.cacheRead == 80)
        #expect(event.tokens.cacheWrite5m == 50)
    }

    @Test func aTotalThatStartsOverIsStillACall() throws {
        // A resumed process starts its running figures again from a smaller number; `last` stays the call's own, so nothing goes negative.
        let result = try read(preamble + [
            tokenCount(ordinal: 2, last: usage(5000, 0, 0, 50, 0, 5050), total: usage(5000, 0, 0, 50, 0, 5050)),
            tokenCount(ordinal: 3, last: usage(700, 0, 0, 7, 0, 707), total: usage(700, 0, 0, 7, 0, 707)),
        ])
        #expect(result.events.map(\.tokens.input) == [5_000, 700])
    }

    // MARK: Parent history

    @Test func skipsParentHistoryInChildRollouts() throws {
        let result = try read([
            meta(id: "child", historyStart: 5),
            tokenCount(ordinal: 3, ts: at(10), last: usage(100, 0, 0, 1, 0, 101), total: usage(100, 0, 0, 1, 0, 101)),
            turnContext(ordinal: 6),
            tokenCount(ordinal: 7, ts: at(20), last: usage(200, 0, 0, 2, 0, 202), total: usage(200, 0, 0, 2, 0, 202)),
        ])
        #expect(result.events.map(\.dedupKey) == ["codex:child:200,0,0,2,0,202"])
        #expect(result.events.map(\.time) == [date(at(20))])
        #expect(result.skipped == 0)
    }

    @Test func theHistoryStartOrdinalItselfBelongsToTheChild() throws {
        let result = try read([
            meta(id: "child", historyStart: 5),
            tokenCount(ordinal: 4, last: usage(100, 0, 0, 1, 0, 101), total: usage(100, 0, 0, 1, 0, 101)),
            tokenCount(ordinal: 5, last: usage(200, 0, 0, 2, 0, 202), total: usage(200, 0, 0, 2, 0, 202)),
        ])
        #expect(result.events.map(\.dedupKey) == ["codex:child:200,0,0,2,0,202"])
    }

    @Test func theCopiedParentRecordsNeverReplaceTheChildsOwn() throws {
        // A child's rollout opens with its own session meta, then the parent's history: the parent's session meta,
        // its turn contexts and its counts, all below the history start.
        let result = try read([
            meta(id: "child", cwd: "/child", originator: "codex-tui", historyStart: 4, ordinal: 0),
            meta(id: "parent", cwd: "/parent", originator: "Codex Desktop", provider: "azure", ordinal: 1),
            turnContext(model: "parent-model", ordinal: 2),
            tokenCount(ordinal: 3, last: usage(100, 0, 0, 1, 0, 101), total: usage(100, 0, 0, 1, 0, 101)),
            turnContext(model: "child-model", ordinal: 4),
            tokenCount(ordinal: 5, last: usage(200, 0, 0, 2, 0, 202), total: usage(200, 0, 0, 2, 0, 202)),
        ])
        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(event.sessionId == "child")
        #expect(event.project == "/child")
        #expect(event.client == "codex-tui")
        #expect(event.provider == "openai")
        #expect(event.model == "child-model")
    }

    @Test func fallsBackToTheLineIndexWithoutAnOrdinal() throws {
        // No record has an ordinal, so a record's position is its line: lines 0 and 1 are the history below 2.
        let result = try read([
            meta(id: "child", historyStart: 2, ordinal: nil),
            tokenCount(last: usage(100, 0, 0, 1, 0, 101), total: usage(100, 0, 0, 1, 0, 101)),
            turnContext(ordinal: nil),
            tokenCount(last: usage(200, 0, 0, 2, 0, 202), total: usage(200, 0, 0, 2, 0, 202)),
        ])
        #expect(result.events.map(\.dedupKey) == ["codex:child:200,0,0,2,0,202"])
        #expect(result.events.map(\.model) == ["gpt-5.6-sol"])
    }

    @Test func theLineIndexContinuesAcrossReads() throws {
        let file = try newFile()
        try write([
            meta(id: "child", historyStart: 3, ordinal: nil),
            tokenCount(last: usage(100, 0, 0, 1, 0, 101), total: usage(100, 0, 0, 1, 0, 101)),
        ], to: file)
        let first = try reader.read(file, from: nil)
        #expect(first.events.isEmpty)

        // Lines 2 and 3 come in the second read: line 2 is still the parent's, line 3 is the first of the child's own.
        try append([
            tokenCount(last: usage(150, 0, 0, 1, 0, 151), total: usage(150, 0, 0, 1, 0, 151)),
            tokenCount(last: usage(200, 0, 0, 2, 0, 202), total: usage(200, 0, 0, 2, 0, 202)),
        ].map { $0 + "\n" }.joined(), to: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.map(\.dedupKey) == ["codex:child:200,0,0,2,0,202"])
    }

    @Test func aRecordsOwnOrdinalWinsOverItsLine() throws {
        // A continuation file starts at the ordinal where the file it continues stopped, not at 0.
        let result = try read([
            meta(id: "child", historyStart: 830, ordinal: 828),
            tokenCount(ordinal: 829, last: usage(100, 0, 0, 1, 0, 101), total: usage(100, 0, 0, 1, 0, 101)),
            tokenCount(ordinal: 830, last: usage(200, 0, 0, 2, 0, 202), total: usage(200, 0, 0, 2, 0, 202)),
        ])
        #expect(result.events.map(\.dedupKey) == ["codex:child:200,0,0,2,0,202"])
    }

    // MARK: Attribution

    @Test func attributesFromSessionMetaAndTurnContext() throws {
        let result = try read(preamble + [
            tokenCount(ordinal: 2, ts: at(10), last: usage(2000, 1500, 0, 20, 0, 2020), total: usage(3000, 1500, 0, 30, 0, 3030)),
        ])
        let event = try #require(result.events.first)
        #expect(event.source == .codex)
        #expect(event.model == "gpt-5.6-sol")
        #expect(event.provider == "openai")
        #expect(event.client == "codex-tui")
        #expect(event.project == "/p")
        #expect(event.sessionId == "t1")
        #expect(event.dedupKey == "codex:t1:3000,1500,0,30,0,3030")
        #expect(event.time == date(at(10)))
        // The rollout does not say when a response started, so there is no start time and no generation time.
        #expect(event.startTime == nil)
        #expect(event.generationMs == nil)
        #expect(!event.isSubagent)
    }

    @Test func followsTheLatestModelOfTheTurnContexts() throws {
        let result = try read([
            meta(), turnContext(model: "gpt-5.6-sol", ordinal: 1),
            tokenCount(ordinal: 2, last: usage(10, 0, 0, 1, 0, 11), total: usage(10, 0, 0, 1, 0, 11)),
            turnContext(model: "gpt-6-astra", ordinal: 3),
            tokenCount(ordinal: 4, last: usage(20, 0, 0, 2, 0, 22), total: usage(30, 0, 0, 3, 0, 33)),
            // A turn context without a model leaves the thread's model as it was.
            turnContext(model: nil, ordinal: 5),
            tokenCount(ordinal: 6, last: usage(40, 0, 0, 4, 0, 44), total: usage(70, 0, 0, 7, 0, 77)),
        ])
        #expect(result.events.map(\.model) == ["gpt-5.6-sol", "gpt-6-astra", "gpt-6-astra"])
    }

    @Test func hasNoModelBeforeTheFirstTurnContext() throws {
        let result = try read([
            meta(),
            tokenCount(ordinal: 1, last: usage(10, 0, 0, 1, 0, 11), total: usage(10, 0, 0, 1, 0, 11)),
        ])
        #expect(result.events.map(\.model) == [nil])
        #expect(result.events.map(\.dedupKey) == ["codex:t1:10,0,0,1,0,11"])
    }

    @Test func takesTheProviderFromTheSessionMetaAndDefaultsToOpenAI() throws {
        let call = usage(10, 0, 0, 1, 0, 11)
        let named = try read([meta(provider: "azure"), turnContext(), tokenCount(ordinal: 2, last: call, total: call)])
        let unnamed = try read([meta(provider: nil), turnContext(), tokenCount(ordinal: 2, last: call, total: call)])
        #expect(named.events.map(\.provider) == ["azure"])
        #expect(unnamed.events.map(\.provider) == ["openai"])
    }

    @Test func takesTheClientFromTheOriginator() throws {
        let call = usage(10, 0, 0, 1, 0, 11)
        let result = try read([meta(originator: "codex_work_desktop"), turnContext(), tokenCount(ordinal: 2, last: call, total: call)])
        #expect(result.events.map(\.client) == ["codex_work_desktop"])
    }

    /// Whether the one call of a thread with this session meta is marked as a subagent's.
    private func isSubagent(_ meta: String) throws -> Bool {
        let call = usage(10, 0, 0, 1, 0, 11)
        let result = try read([meta, turnContext(), tokenCount(ordinal: 2, last: call, total: call)])
        return try #require(result.events.first).isSubagent
    }

    @Test func marksSpawnedSubagentsByTheirThreadSource() throws {
        let source: [String: Any] = ["subagent": ["thread_spawn": ["parent_thread_id": "t0", "depth": 1]]]
        #expect(try isSubagent(meta(threadSource: "subagent")))
        #expect(try isSubagent(meta(threadSource: "subagent", source: source)))
    }

    @Test func marksGuardianReviewsAsSubagents() throws {
        #expect(try isSubagent(meta(threadSource: "guardian_review")))
        #expect(try isSubagent(meta(threadSource: "guardian_review", source: ["subagent": ["other": "guardian"]])))
    }

    @Test func marksAThreadWhoseSourceIsASubagentWhateverItsThreadSource() throws {
        // Older rollouts have no thread source; the source alone says whether the thread belongs to a subagent.
        #expect(try isSubagent(meta(source: ["subagent": ["thread_spawn": ["parent_thread_id": "t0"]]])))
        #expect(try isSubagent(meta(source: ["subagent": ["other": "guardian"]])))
        #expect(try isSubagent(meta(source: ["subagent": "review"])))
    }

    @Test func leavesThreadsTheUserOpenedAlone() throws {
        #expect(try !isSubagent(meta(threadSource: "user", source: "vscode")))
        #expect(try !isSubagent(meta(source: "cli")))
        #expect(try !isSubagent(meta()))
    }

    // MARK: Rate limits

    @Test func emitsRateLimitSnapshots() throws {
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let limits = rateLimits(
            primary: window(10, minutes: 300, resetsAt: 1_792_555_400),
            secondary: window(4, minutes: 10_080, resetsAt: 1_793_083_701)
        )
        let result = try read(preamble + [tokenCount(ordinal: 2, ts: "2026-11-01T00:00:00.000Z", last: call, total: call, rateLimits: limits)])
        let observed = date("2026-11-01T00:00:00.000Z")
        #expect(result.quotas == [
            QuotaSnapshot(
                provider: .openai, window: .fiveHour, usedPercent: 10, resetsAt: Date(timeIntervalSince1970: 1_792_555_400),
                observedAt: observed, origin: .codexLog, plan: "plus"
            ),
            QuotaSnapshot(
                provider: .openai, window: .weekly, usedPercent: 4, resetsAt: Date(timeIntervalSince1970: 1_793_083_701),
                observedAt: observed, origin: .codexLog, plan: "plus"
            ),
        ])
        #expect(result.events.count == 1)
    }

    @Test func resetsInSecondsVariant() throws {
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let limits = rateLimits(primary: window(50, minutes: 300, resetsIn: 600))
        let time = "2026-11-01T00:00:00.000Z"
        let result = try read(preamble + [tokenCount(ordinal: 2, ts: time, last: call, total: call, rateLimits: limits)])
        #expect(result.quotas.map(\.resetsAt) == [date(time).addingTimeInterval(600)])
        #expect(result.quotas.map(\.usedPercent) == [50])
    }

    @Test func anAbsoluteResetTimeWinsOverARelativeOne() throws {
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let limits = rateLimits(primary: window(50, minutes: 300, resetsAt: 1_792_555_400, resetsIn: 600))
        let result = try read(preamble + [tokenCount(ordinal: 2, last: call, total: call, rateLimits: limits)])
        #expect(result.quotas.map(\.resetsAt) == [Date(timeIntervalSince1970: 1_792_555_400)])
    }

    @Test func aWeeklyOnlyPlanReportsItsWeeklyWindowAsThePrimaryOne() throws {
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let limits = rateLimits(primary: window(12, minutes: 10_080, resetsAt: 1_793_083_701), secondary: nil)
        let result = try read(preamble + [tokenCount(ordinal: 2, last: call, total: call, rateLimits: limits)])
        #expect(result.quotas.map(\.window) == [.weekly])
        #expect(result.quotas.map(\.usedPercent) == [12])
    }

    @Test func skipsWindowsThatAreNeitherFiveHoursNorAWeek() throws {
        let call = usage(1000, 0, 0, 10, 0, 1010)
        // The monthly window of a free plan fits no window the forecast models; calling it weekly would break the projection.
        let monthly = rateLimits(primary: window(30, minutes: 43_200, resetsAt: 1_793_000_000), plan: "free")
        let result = try read(preamble + [tokenCount(ordinal: 2, last: call, total: call, rateLimits: monthly)])
        #expect(result.quotas.isEmpty)
        #expect(result.events.count == 1)

        // Only the length itself decides: close lengths, and windows that give none, are no five-hour or weekly window either.
        let others = rateLimits(
            primary: window(1, minutes: 299, resetsAt: 1_793_000_000),
            secondary: window(2, minutes: 10_081, resetsAt: 1_793_000_000)
        )
        let lengthless = rateLimits(primary: window(3, minutes: nil, resetsAt: 1_793_000_000))
        let other = try read(preamble + [
            tokenCount(ordinal: 2, last: call, total: call, rateLimits: others),
            tokenCount(ordinal: 3, last: usage(0, 0, 0, 0, 0, 1), total: call, rateLimits: lengthless),
        ])
        #expect(other.quotas.isEmpty)

        // A plan's other window still comes through.
        let mixed = rateLimits(
            primary: window(30, minutes: 43_200, resetsAt: 1_793_000_000),
            secondary: window(4, minutes: 10_080, resetsAt: 1_793_083_701)
        )
        let kept = try read(preamble + [tokenCount(ordinal: 2, last: call, total: call, rateLimits: mixed)])
        #expect(kept.quotas.map(\.window) == [.weekly])
    }

    @Test func skipsWindowsWithoutAUsedPercentOrAResetTime() throws {
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let limits = rateLimits(
            primary: ["window_minutes": 300, "resets_at": 1_792_555_400],
            secondary: window(4, minutes: 10_080)
        )
        let result = try read(preamble + [tokenCount(ordinal: 2, last: call, total: call, rateLimits: limits)])
        #expect(result.quotas.isEmpty)
        #expect(result.skipped == 0)
    }

    @Test func skipsTheRateLimitsOfAModelBucket() throws {
        // Besides the plan's limits ("codex"), Codex reports model allowances such as "codex_bengalfox" (GPT-5.3-Codex-Spark), whose
        // five-hour and weekly windows are the model's, not the account's. They give no snapshot, and the call still counts.
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let spark = rateLimits(
            limitId: "codex_bengalfox", limitName: "GPT-5.3-Codex-Spark",
            primary: window(50, minutes: 300, resetsAt: 1_792_555_400),
            secondary: window(20, minutes: 10_080, resetsAt: 1_793_083_701)
        )
        let result = try read(preamble + [tokenCount(ordinal: 2, last: call, total: call, rateLimits: spark)])
        #expect(result.quotas.isEmpty)
        #expect(result.events.count == 1)
        #expect(result.skipped == 0)
    }

    @Test func aModelBucketBetweenPlanSnapshotsNeverBecomesTheNewest() throws {
        // Codex records only the bucket it heard of last, so the buckets interleave in one rollout.
        let spark = rateLimits(
            limitId: "codex_bengalfox", limitName: "GPT-5.3-Codex-Spark",
            primary: window(50, minutes: 300, resetsAt: 1_792_555_400),
            secondary: window(20, minutes: 10_080, resetsAt: 1_793_083_701)
        )
        let result = try read(preamble + [
            tokenCount(ordinal: 2, ts: at(10), last: usage(10, 0, 0, 1, 0, 11), total: usage(10, 0, 0, 1, 0, 11), rateLimits: rateLimits(primary: window(10, minutes: 300, resetsAt: 1_792_555_400))),
            tokenCount(ordinal: 3, ts: at(20), last: usage(20, 0, 0, 2, 0, 22), total: usage(30, 0, 0, 3, 0, 33), rateLimits: spark),
            tokenCount(ordinal: 4, ts: at(30), last: usage(30, 0, 0, 3, 0, 33), total: usage(60, 0, 0, 6, 0, 66), rateLimits: rateLimits(primary: window(12, minutes: 300, resetsAt: 1_792_555_400))),
        ])
        #expect(result.events.count == 3)
        #expect(result.quotas.map(\.usedPercent) == [10, 12])
        #expect(result.quotas.map(\.observedAt) == [date(at(10)), date(at(30))])
    }

    @Test func onlyTheCodexBucketOrNoneIsThePlan() throws {
        let call = usage(1000, 0, 0, 10, 0, 1010)
        // The plan: "codex" in any case, or no bucket at all (a missing key or a null).
        for bucket in ["codex", "Codex", "CODEX", nil, NSNull()] as [Any?] {
            let limits = rateLimits(limitId: bucket, primary: window(10, minutes: 300, resetsAt: 1_792_555_400))
            let result = try read(preamble + [tokenCount(ordinal: 2, last: call, total: call, rateLimits: limits)])
            #expect(result.quotas.map(\.usedPercent) == [10], "bucket \(String(describing: bucket))")
        }
        // Any other bucket is a model's allowance.
        for bucket in ["premium", "codex_bengalfox", "codex-other", "codexx"] {
            let limits = rateLimits(limitId: bucket, primary: window(10, minutes: 300, resetsAt: 1_792_555_400))
            let result = try read(preamble + [tokenCount(ordinal: 2, last: call, total: call, rateLimits: limits)])
            #expect(result.quotas.isEmpty, "bucket \(bucket)")
        }
    }

    @Test func keepsUsedPercentWithinZeroToAHundred() throws {
        let result = try read(preamble + [
            tokenCount(
                ordinal: 2, ts: at(10), last: usage(10, 0, 0, 1, 0, 11), total: usage(10, 0, 0, 1, 0, 11),
                rateLimits: rateLimits(primary: window(120, minutes: 300, resetsAt: 1_792_555_400), secondary: window(-5, minutes: 10_080, resetsAt: 1_793_083_701))
            ),
            tokenCount(
                ordinal: 3, ts: at(20), last: usage(20, 0, 0, 2, 0, 22), total: usage(30, 0, 0, 3, 0, 33),
                rateLimits: rateLimits(primary: window(37.5, minutes: 300, resetsAt: 1_792_555_400), secondary: window(0, minutes: 10_080, resetsAt: 1_793_083_701))
            ),
        ])
        #expect(result.quotas.map(\.window) == [.fiveHour, .weekly, .fiveHour, .weekly])
        #expect(result.quotas.map(\.usedPercent) == [100, 0, 37.5, 0])
    }

    @Test func keepsTheRateLimitsOfACountWhoseTotalDidNotChange() throws {
        // Codex sends a count again whenever its rate limits are updated: no new call, but a new observation.
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let result = try read(preamble + [
            tokenCount(ordinal: 2, ts: at(10), last: call, total: call, rateLimits: rateLimits(primary: window(10, minutes: 300, resetsAt: 1_792_555_400))),
            tokenCount(ordinal: 3, ts: at(20), last: usage(0, 0, 0, 0, 0, 1010), total: call, rateLimits: rateLimits(primary: window(12, minutes: 300, resetsAt: 1_792_555_400))),
        ])
        #expect(result.events.count == 1)
        #expect(result.quotas.map(\.usedPercent) == [10, 12])
        #expect(result.quotas.map(\.observedAt) == [date(at(10)), date(at(20))])
    }

    @Test func aCountWithoutInfoCarriesRateLimitsOnly() throws {
        // The first count of a thread has `info: null`.
        let limits = rateLimits(primary: window(10, minutes: 300, resetsAt: 1_792_555_400))
        let result = try read(preamble + [tokenCount(ordinal: 2, ts: at(10), info: NSNull(), rateLimits: limits)])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 0)
        #expect(result.quotas.map(\.usedPercent) == [10])
    }

    @Test func aCountWithoutRateLimitsHasNoSnapshots() throws {
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let result = try read(preamble + [
            tokenCount(ordinal: 2, last: call, total: call, rateLimits: nil),
            tokenCount(ordinal: 3, last: usage(1, 0, 0, 1, 0, 2), total: usage(1001, 0, 0, 11, 0, 1012), rateLimits: ["limit_id": "premium", "primary": NSNull(), "secondary": NSNull()]),
        ])
        #expect(result.quotas.isEmpty)
        #expect(result.events.count == 2)
    }

    @Test func skipsTheRateLimitsOfParentHistoryToo() throws {
        let call = usage(100, 0, 0, 1, 0, 101)
        let result = try read([
            meta(id: "child", historyStart: 5),
            tokenCount(ordinal: 3, ts: at(10), last: call, total: call, rateLimits: rateLimits(primary: window(80, minutes: 300, resetsAt: 1_792_555_400))),
            tokenCount(ordinal: 7, ts: at(20), last: usage(200, 0, 0, 2, 0, 202), total: usage(300, 0, 0, 3, 0, 303), rateLimits: rateLimits(primary: window(5, minutes: 300, resetsAt: 1_792_555_400))),
        ])
        #expect(result.quotas.map(\.usedPercent) == [5])
        #expect(result.quotas.map(\.observedAt) == [date(at(20))])
    }

    // MARK: State across reads

    @Test func keepsStateAcrossReads() throws {
        let file = try newFile()
        try write(preamble, to: file)
        let first = try reader.read(file, from: nil)
        #expect(first.events.isEmpty)

        try append(tokenCount(ordinal: 2, ts: at(10), last: usage(2000, 1500, 0, 20, 0, 2020), total: usage(3000, 1500, 0, 30, 0, 3030)) + "\n", to: file)
        let second = try reader.read(file, from: first.cursor)
        let event = try #require(second.events.first)
        #expect(second.events.count == 1)
        #expect(event.model == "gpt-5.6-sol")
        #expect(event.project == "/p")
        #expect(event.sessionId == "t1")
        #expect(event.client == "codex-tui")
        #expect(event.dedupKey == "codex:t1:3000,1500,0,30,0,3030")
    }

    @Test func remembersThePreviousTotalAcrossReads() throws {
        let file = try newFile()
        let call = usage(1000, 0, 0, 10, 0, 1010)
        try write(preamble + [tokenCount(ordinal: 2, last: call, total: call)], to: file)
        let first = try reader.read(file, from: nil)
        #expect(first.events.count == 1)

        // The same total again, as after a rate-limit update, and then a call.
        try append([
            tokenCount(ordinal: 3, last: usage(0, 0, 0, 0, 0, 1010), total: call),
            tokenCount(ordinal: 4, last: usage(2000, 1500, 0, 20, 0, 2020), total: usage(3000, 1500, 0, 30, 0, 3030)),
        ].map { $0 + "\n" }.joined(), to: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.map(\.dedupKey) == ["codex:t1:3000,1500,0,30,0,3030"])
    }

    @Test func theHistoryStartSurvivesAcrossReads() throws {
        let file = try newFile()
        try write([meta(id: "child", historyStart: 5)], to: file)
        let first = try reader.read(file, from: nil)

        try append([
            tokenCount(ordinal: 3, last: usage(100, 0, 0, 1, 0, 101), total: usage(100, 0, 0, 1, 0, 101)),
            tokenCount(ordinal: 7, last: usage(200, 0, 0, 2, 0, 202), total: usage(200, 0, 0, 2, 0, 202)),
        ].map { $0 + "\n" }.joined(), to: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.map(\.dedupKey) == ["codex:child:200,0,0,2,0,202"])
    }

    @Test func theCursorAdvancesPastEveryLineRead() throws {
        let file = try newFile()
        let call = usage(1000, 0, 0, 10, 0, 1010)
        try write(preamble + [tokenCount(ordinal: 2, last: call, total: call)], to: file)
        let first = try reader.read(file, from: nil)
        #expect(first.cursor.offset == first.cursor.size)
        // Only an archive is complete: a rollout that is still being written to can grow.
        #expect(!first.cursor.complete)

        // Nothing was appended: nothing is read, and the call is not counted twice.
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.isEmpty)
        #expect(second.quotas.isEmpty)
        #expect(second.cursor.offset == first.cursor.offset)
    }

    @Test func aHalfWrittenLineCountsOnceWhenItsEndArrives() throws {
        let file = try newFile()
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let line = tokenCount(ordinal: 2, last: call, total: call, rateLimits: rateLimits(primary: window(10, minutes: 300, resetsAt: 1_792_555_400)))
        let cut = line.index(line.startIndex, offsetBy: line.count / 2)
        try write(preamble, to: file)
        try append(String(line[..<cut]), to: file)
        let first = try reader.read(file, from: nil)
        // Caught mid-write: neither an event nor an unreadable line.
        #expect(first.events.isEmpty)
        #expect(first.quotas.isEmpty)
        #expect(first.skipped == 0)

        try append(String(line[cut...]) + "\n", to: file)
        let second = try reader.read(file, from: first.cursor)
        #expect(second.events.map(\.dedupKey) == ["codex:t1:1000,0,0,10,0,1010"])
        #expect(second.quotas.count == 1)
        #expect(second.skipped == 0)
    }

    @Test func anUnreadableStateReadsTheFileAgain() throws {
        // The thread and its model are written once, at the top of a rollout; without them the rest of the file could not be told.
        let file = try newFile()
        let first = usage(1000, 0, 0, 10, 0, 1010)
        try write(preamble + [tokenCount(ordinal: 2, last: first, total: first)], to: file)
        let before = try reader.read(file, from: nil)

        try append(tokenCount(ordinal: 3, last: usage(2000, 1500, 0, 20, 0, 2020), total: usage(3000, 1500, 0, 30, 0, 3030)) + "\n", to: file)
        for state in [Data("not json".utf8), nil] {
            var cursor = before.cursor
            cursor.state = state
            let result = try reader.read(file, from: cursor)
            #expect(result.events.map(\.dedupKey) == ["codex:t1:1000,0,0,10,0,1010", "codex:t1:3000,1500,0,30,0,3030"])
            #expect(result.events.map(\.model) == ["gpt-5.6-sol", "gpt-5.6-sol"])
        }
    }

    @Test func aRewrittenFileIsReadAgainFromNothing() throws {
        let file = try newFile()
        let call = usage(1000, 0, 0, 10, 0, 1010)
        try write([meta(id: "old", cwd: "/old"), turnContext(model: "old-model"), tokenCount(ordinal: 2, last: call, total: call)], to: file)
        let before = try reader.read(file, from: nil)
        #expect(before.events.map(\.sessionId) == ["old"])

        // Shorter than what was read, so the reader starts over. Nothing of the old file may leak into what the new one yields:
        // not its thread, project or model, and not its previous total (the new file's first count has the same total).
        try write([meta(id: "new", cwd: "/n"), tokenCount(ordinal: 1, last: call, total: call), #"{"type":"event_msg","payload":{"type":"token_count","info":"#], to: file)
        try #require(try Data(contentsOf: file).count < Int(before.cursor.offset))
        let after = try reader.read(file, from: before.cursor)
        let event = try #require(after.events.first)
        #expect(after.events.count == 1)
        #expect(event.sessionId == "new")
        #expect(event.project == "/n")
        #expect(event.model == nil)
        // The old file had no unreadable line; the new one has one, and it is counted once.
        #expect(after.skipped == 1)
    }

    // MARK: Lines it cannot use

    @Test func countsTokenCountsItCannotUseAsSkipped() throws {
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let result = try read(preamble + [
            // No total: the call cannot be told from a repeat and has no key.
            tokenCount(ordinal: 2, last: call, total: nil),
            // No `last`: the figures of the call are missing.
            tokenCount(ordinal: 3, last: nil, total: usage(2000, 0, 0, 20, 0, 2020)),
            // Objects with none of the figures: a shape this reader does not know.
            tokenCount(ordinal: 4, last: [:], total: usage(3000, 0, 0, 30, 0, 3030)),
            tokenCount(ordinal: 5, last: call, total: ["something": 1]),
            // No timestamp: the call has no time.
            tokenCount(ordinal: 6, ts: nil, last: call, total: usage(4000, 0, 0, 40, 0, 4040), rateLimits: rateLimits(primary: window(10, minutes: 300, resetsAt: 1_792_555_400))),
            // The one that can be used.
            tokenCount(ordinal: 7, last: call, total: usage(5000, 0, 0, 50, 0, 5050)),
        ])
        #expect(result.events.map(\.dedupKey) == ["codex:t1:5000,0,0,50,0,5050"])
        #expect(result.quotas.isEmpty)
        #expect(result.skipped == 5)
    }

    @Test func anUnusableCountDoesNotHideTheNextOneWithTheSameTotal() throws {
        // A count whose figures could not be read has not been counted, so it must not make a later count a repeat.
        let total = usage(2000, 0, 0, 20, 0, 2020)
        let result = try read(preamble + [
            tokenCount(ordinal: 2, last: nil, total: total),
            tokenCount(ordinal: 3, last: usage(2000, 0, 0, 20, 0, 2020), total: total),
        ])
        #expect(result.events.map(\.dedupKey) == ["codex:t1:2000,0,0,20,0,2020"])
        #expect(result.skipped == 1)
    }

    @Test func countsACallOfAnUnknownThreadAsSkipped() throws {
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let result = try read([tokenCount(ordinal: 0, last: call, total: call)])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 1)
    }

    @Test func countsASessionMetaWithoutAnIdAsSkipped() throws {
        let result = try read([record(type: "session_meta", ordinal: 0, ts: at(0), payload: ["cwd": "/p"])])
        #expect(result.skipped == 1)
    }

    @Test func countsUnparseableLinesOfItsKindAsSkipped() throws {
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let result = try read(preamble + [
            #"{"type":"event_msg","payload":{"type":"token_count","info":"#,
            // A line of another kind is never parsed, so it is no skip either.
            #"{"type":"response_item","payload":{"type":"message"#,
            tokenCount(ordinal: 4, last: call, total: call),
        ])
        #expect(result.skipped == 1)
        #expect(result.events.count == 1)
    }

    @Test func aUsageThatIsNotCountsIsSkipped() throws {
        let good = usage(100, 0, 0, 10, 0, 110)
        let bad: [[String: Any]] = [
            ["input_tokens": 100, "completion_tokens": 500, "total_tokens": 600],
            ["output_tokens": 10, "total_tokens": 600],
            ["input_tokens": "100", "output_tokens": 10],
            ["input_tokens": -7, "output_tokens": 10],
            ["input_tokens": 100, "output_tokens": 1.5],
            ["input_tokens": Int.max, "output_tokens": 10],
            ["input_tokens": 100, "output_tokens": 10, "cached_input_tokens": "x"],
            ["input_tokens": 100, "output_tokens": 10, "reasoning_output_tokens": -1],
        ]
        for figures in bad {
            let asLast = try read(preamble + [tokenCount(ordinal: 2, last: figures, total: good)])
            #expect(asLast.events.isEmpty, "\(figures)")
            #expect(asLast.skipped == 1, "\(figures)")
            let asTotal = try read(preamble + [tokenCount(ordinal: 2, last: good, total: figures)])
            #expect(asTotal.events.isEmpty, "\(figures)")
            #expect(asTotal.skipped == 1, "\(figures)")
        }
    }

    @Test func aSideFigureThatIsMissingOrNullIsNone() throws {
        let figures: [String: Any] = ["input_tokens": 100, "output_tokens": 10, "cached_input_tokens": NSNull()]
        let result = try read(preamble + [tokenCount(ordinal: 2, last: figures, total: usage(100, 0, 0, 10, 0, 110))])
        #expect(result.events.map(\.tokens) == [TokenCounts(input: 100, output: 10)])
        #expect(result.skipped == 0)
    }

    @Test func aBlankThreadIdIsNoThread() throws {
        let call = usage(100, 0, 0, 10, 0, 110)
        let result = try read([meta(id: " "), turnContext(), tokenCount(ordinal: 2, last: call, total: call)])
        #expect(result.events.isEmpty)
        #expect(result.skipped == 2)
    }

    // MARK: Usage records no count covers

    private func usageRecord(ordinal: Int?, response: String? = "r1", second: Int = 5, figures: [String: Any]) -> String {
        var payload: [String: Any] = ["thread_id": "t1", "usage": figures]
        if let response { payload["response_id"] = response }
        return record(type: "token_usage_record", ordinal: ordinal, ts: at(second), payload: payload)
    }

    private func compacted(ordinal: Int?) -> String {
        record(type: "compacted", ordinal: ordinal, ts: at(6), payload: ["message": ""])
    }

    private var call: [String: Any] { usage(1000, 0, 0, 10, 0, 1010) }
    private var compaction: [String: Any] { usage(90000, 80000, 0, 2000, 0, 92000) }

    @Test func aRecordItsCountFollowsIsOneCall() throws {
        let result = try read(preamble + [usageRecord(ordinal: 2, figures: call), tokenCount(ordinal: 3, last: call, total: call)])
        #expect(result.events.map(\.dedupKey) == ["codex:t1:1000,0,0,10,0,1010"])
    }

    /// Codex records a compaction's usage and leaves it out of its running total, so no count ever covers it.
    @Test func aRecordBeforeACompactionIsACallOfItsOwn() throws {
        let result = try read(preamble + [usageRecord(ordinal: 2, figures: compaction), compacted(ordinal: 3)])
        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(event.dedupKey == "codex:t1:usage:r1")
        #expect(event.tokens == TokenCounts(input: 10000, output: 2000, cacheRead: 80000))
        #expect(event.time == date("2026-11-01T00:00:05.000Z"))
        #expect(event.model == "gpt-5.6-sol")
        #expect(event.sessionId == "t1")
        #expect(event.project == "/p")
        #expect(event.provider == "openai")
        #expect(result.skipped == 0)
    }

    @Test func aRecordAnotherRecordFollowsIsACallOfItsOwn() throws {
        let result = try read(preamble + [
            usageRecord(ordinal: 2, response: "r1", figures: compaction),
            usageRecord(ordinal: 3, response: "r2", figures: call),
            tokenCount(ordinal: 4, last: call, total: call),
        ])
        #expect(result.events.map(\.dedupKey) == ["codex:t1:usage:r1", "codex:t1:1000,0,0,10,0,1010"])
    }

    @Test func aCountOfOtherFiguresDoesNotCoverARecord() throws {
        let result = try read(preamble + [usageRecord(ordinal: 2, figures: compaction), tokenCount(ordinal: 3, last: call, total: call)])
        #expect(result.events.map(\.dedupKey) == ["codex:t1:usage:r1", "codex:t1:1000,0,0,10,0,1010"])
    }

    @Test func aRepeatedCountCoversNothing() throws {
        let result = try read(preamble + [
            tokenCount(ordinal: 2, last: call, total: call),
            usageRecord(ordinal: 3, figures: call),
            tokenCount(ordinal: 4, last: call, total: call),
            compacted(ordinal: 5),
        ])
        #expect(result.events.map(\.dedupKey) == ["codex:t1:1000,0,0,10,0,1010", "codex:t1:usage:r1"])
    }

    /// A record is settled by what comes after it, which can be the next turn's context.
    @Test func aRecordKeepsTheModelItWasWrittenUnder() throws {
        let result = try read([meta(), turnContext(model: "gpt-first"),
            usageRecord(ordinal: 2, response: "r1", figures: compaction),
            turnContext(model: "gpt-next", ordinal: 3),
            usageRecord(ordinal: 4, response: "r2", figures: call),
            tokenCount(ordinal: 5, last: call, total: call),
        ])
        #expect(result.events.map(\.model) == ["gpt-first", "gpt-next"])
    }

    /// A record and what settles it can land either side of a read.
    @Test func aRecordIsHeldAcrossReads() throws {
        let file = try newFile()
        try write(preamble + [usageRecord(ordinal: 2, figures: call)], to: file)
        let first = try reader.read(file, from: nil)
        #expect(first.events.isEmpty)
        try append(tokenCount(ordinal: 3, last: call, total: call) + "\n", to: file)
        let covered = try reader.read(file, from: first.cursor)
        #expect(covered.events.map(\.dedupKey) == ["codex:t1:1000,0,0,10,0,1010"])

        let other = try newFile()
        try write(preamble + [usageRecord(ordinal: 2, figures: compaction)], to: other)
        let held = try reader.read(other, from: nil)
        try append(compacted(ordinal: 3) + "\n", to: other)
        let settled = try reader.read(other, from: held.cursor)
        #expect(settled.events.map(\.dedupKey) == ["codex:t1:usage:r1"])
    }

    @Test func aRecordInACopyOfTheParentsHistoryIsNotOurs() throws {
        let result = try read([meta(historyStart: 5), turnContext(ordinal: 1), usageRecord(ordinal: 3, figures: compaction), compacted(ordinal: 4)])
        #expect(result.events.isEmpty)
    }

    @Test func aRecordThatCannotBeReadIsSkipped() throws {
        let noResponse = try read(preamble + [usageRecord(ordinal: 2, response: nil, figures: call)])
        #expect(noResponse.skipped == 1)
        let blank = try read(preamble + [usageRecord(ordinal: 2, response: " ", figures: call)])
        #expect(blank.skipped == 1)
        let badFigures = try read(preamble + [usageRecord(ordinal: 2, figures: ["input_tokens": "x", "output_tokens": 5])])
        #expect(badFigures.skipped == 1)
    }

    /// An archive is never written again, so a record still held at its end has nothing left to settle it.
    @Test func anArchiveSettlesItsLastRecord() throws {
        let archive = try newArchive(text(preamble + [usageRecord(ordinal: 2, figures: compaction)]))
        let result = try reader.read(archive, from: nil)
        #expect(result.events.map(\.dedupKey) == ["codex:t1:usage:r1"])
    }

    @Test func aLoneRecordAndMereMentionsMakeNoEvent() throws {
        let call = usage(1000, 0, 0, 10, 0, 1010)
        // A record is held until what follows settles it, and nothing here does. At the end of a plain rollout that is the known
        // limit `CodexReader` records: the record counts once the rollout is archived, and not before.
        let usageRecord = record(type: "token_usage_record", ordinal: 2, ts: at(5), payload: ["thread_id": "t1", "response_id": "r1", "usage": call])
        // Records of other kinds that merely mention the words the reader looks for.
        let mention = record(type: "event_msg", ordinal: 3, ts: at(6), payload: ["type": "agent_message", "message": "the token_count record"])
        let response = record(type: "response_item", ordinal: 4, ts: at(7), payload: ["type": "message", "content": "session_meta turn_context"])
        let result = try read(preamble + [usageRecord, mention, response])
        #expect(result.events.isEmpty)
        #expect(result.quotas.isEmpty)
        #expect(result.skipped == 0)
    }

    // MARK: Answers with no usage

    /// Items the model wrote, each the payload of a `response_item` as Codex writes it: the timestamp, the ordinal, the type, then the
    /// payload, whose kind comes first.
    private static let answers = [
        #"{"type":"function_call","name":"shell","arguments":"{}","call_id":"c1"}"#,
        #"{"type":"custom_tool_call","status":"completed","call_id":"c1","name":"apply_patch","input":"x"}"#,
        #"{"type":"local_shell_call","call_id":"c1","status":"completed","action":{"type":"exec","command":["ls"]}}"#,
        #"{"type":"web_search_call","status":"completed","action":{"type":"search","query":"x"}}"#,
        #"{"type":"message","id":"i1","role":"assistant","content":[{"type":"output_text","text":"x"}]}"#,
    ]

    private func item(_ payload: String, ordinal: Int? = nil) -> String {
        let position = ordinal.map { "\"ordinal\":\($0)," } ?? ""
        return #"{"timestamp":"\#(at(3))",\#(position)"type":"response_item","payload":\#(payload)}"#
    }

    /// Each answer's usage comes in a count or a record after it. A run longer than a healthy rollout ever has means the reader no
    /// longer finds them, and every answer of the run is then skipped: the one sign of a renamed format (spec 3, 5.4, 7).
    @Test(arguments: CodexReaderTests.answers)
    func aLongRunOfAnswersWithNoUsageIsSkipped(payload: String) throws {
        #expect(try read(preamble + Array(repeating: item(payload), count: 19)).skipped == 0)
        #expect(try read(preamble + Array(repeating: item(payload), count: 20)).skipped == 20)
        #expect(try read(preamble + Array(repeating: item(payload), count: 21)).skipped == 21)
    }

    @Test(arguments: [
        #"{"type":"message","id":"i1","role":"user","content":[{"type":"input_text","text":"x"}]}"#,
        #"{"type":"function_call_output","call_id":"c1","output":"x"}"#,
        #"{"type":"custom_tool_call_output","call_id":"c1","output":"x"}"#,
        #"{"type":"reasoning","id":"i1","summary":[],"encrypted_content":"x"}"#,
    ])
    func whatTheModelDidNotWriteIsNoAnswer(payload: String) throws {
        #expect(try read(preamble + Array(repeating: item(payload), count: 25)).skipped == 0)
    }

    @Test func aCountOrARecordEndsTheRun() throws {
        let run = Array(repeating: item(Self.answers[0]), count: 19)
        #expect(try read(preamble + run + [tokenCount(last: call, total: call)] + run).skipped == 0)
        #expect(try read(preamble + run + [usageRecord(ordinal: nil, figures: compaction)] + run).skipped == 0)
    }

    @Test func aRunGoesOnAcrossReads() throws {
        let file = try newFile()
        try write(preamble + Array(repeating: item(Self.answers[0]), count: 15), to: file)
        let first = try reader.read(file, from: nil)
        #expect(first.skipped == 0)
        try append(Array(repeating: item(Self.answers[0]) + "\n", count: 5).joined(), to: file)
        #expect(try reader.read(file, from: first.cursor).skipped == 20)
    }

    /// The parent's answers have their usage in the parent's own rollout. What tells them apart is each line's ordinal, not its place.
    @Test func onlyASubagentsOwnAnswersCount() throws {
        let copied = (2..<27).map { item(Self.answers[0], ordinal: $0) }
        #expect(try read([meta(historyStart: 30), turnContext()] + copied).skipped == 0)
        let own = (30..<50).map { item(Self.answers[0], ordinal: $0) }
        #expect(try read([meta(historyStart: 30), turnContext()] + copied + own).skipped == 20)
    }

    /// What the model wrote is conversation, so an answer is told from its bytes and never parsed: one that would not parse is an
    /// answer all the same, and no line that cannot be read.
    @Test func anAnswerIsNeverParsed() throws {
        let cut = #"{"timestamp":"\#(at(3))","ordinal":2,"type":"response_item","payload":{"type":"function_call","arguments":"#
        #expect(try read(preamble + Array(repeating: cut, count: 19)).skipped == 0)
    }

    // MARK: Compressed rollouts

    private func text(_ lines: [String]) -> Data {
        Data(lines.map { $0 + "\n" }.joined().utf8)
    }

    /// A new file named `name` holding `content` as one zstd frame.
    private func newArchive(_ content: Data, named name: String = "rollout-x.jsonl.zst") throws -> URL {
        let file = try newFile(name)
        try ZstdFixture.compress(content).write(to: file)
        return file
    }

    @Test func readsZstdRollouts() throws {
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let rollout = preamble + [
            tokenCount(ordinal: 2, ts: at(10), last: call, total: call, rateLimits: rateLimits(primary: window(10, minutes: 300, resetsAt: 1_792_555_400))),
            tokenCount(ordinal: 3, ts: at(20), last: usage(2000, 1500, 0, 20, 0, 2020), total: usage(3000, 1500, 0, 30, 0, 3030)),
        ]
        let plain = try newFile("rollout-x.jsonl")
        try write(rollout, to: plain)
        let archive = try newArchive(text(rollout))

        let fromPlain = try reader.read(plain, from: nil)
        let fromArchive = try reader.read(archive, from: nil)
        #expect(fromArchive.events.count == 2)
        #expect(fromArchive.events == fromPlain.events)
        #expect(fromArchive.quotas.count == 1)
        #expect(fromArchive.quotas == fromPlain.quotas)
        #expect(fromArchive.skipped == 0)

        // The cursor describes the compressed file, and says that it was read to its end.
        let cursor = fromArchive.cursor
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        #expect(cursor.complete)
        #expect(cursor.size == (attributes[.size] as? NSNumber)?.uint64Value)
        #expect(cursor.offset == cursor.size)
        #expect(cursor.inode == (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        let modified = try #require(attributes[.modificationDate] as? Date)
        #expect(abs(cursor.mtime.timeIntervalSince(modified)) < 0.001)

        // An archive does not change: read again with that cursor, there is nothing new.
        let again = try reader.read(archive, from: cursor)
        #expect(again.events.isEmpty)
        #expect(again.quotas.isEmpty)
        #expect(again.skipped == 0)
        #expect(again.cursor == cursor)
    }

    @Test func readsTheLastLineOfAnArchiveWithoutAFinalNewline() throws {
        // An archive never grows, so a last line without its newline is a whole one, not a half-written one.
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let archive = try newArchive(Data((preamble + [tokenCount(ordinal: 2, last: call, total: call)]).joined(separator: "\n").utf8))
        let result = try reader.read(archive, from: nil)
        #expect(result.events.map(\.dedupKey) == ["codex:t1:1000,0,0,10,0,1010"])
        #expect(result.skipped == 0)
    }

    @Test func anArchiveThatChangedIsReadAgain() throws {
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let archive = try newArchive(text(preamble + [tokenCount(ordinal: 2, last: call, total: call)]))
        let first = try reader.read(archive, from: nil)
        #expect(first.events.count == 1)

        let longer = text(preamble + [
            tokenCount(ordinal: 2, last: call, total: call),
            tokenCount(ordinal: 3, last: usage(2000, 1500, 0, 20, 0, 2020), total: usage(3000, 1500, 0, 30, 0, 3030)),
        ])
        try ZstdFixture.compress(longer).write(to: archive)
        let second = try reader.read(archive, from: first.cursor)
        // All of it again: the store keeps the call it already has.
        #expect(second.events.count == 2)
        #expect(second.cursor.size != first.cursor.size)
        #expect(second.cursor.complete)
    }

    @Test func anArchiveCutShortThrowsAndReadsOnceItIsWhole() throws {
        let call = usage(1000, 0, 0, 10, 0, 1010)
        let frame = ZstdFixture.compress(text(preamble + [tokenCount(ordinal: 2, last: call, total: call)]))
        let archive = try newFile("rollout-x.jsonl.zst")
        try frame.prefix(frame.count / 2).write(to: archive)
        #expect(throws: ZstdError.truncated) { try reader.read(archive, from: nil) }

        try frame.write(to: archive)
        #expect(try reader.read(archive, from: nil).events.count == 1)
    }

    // MARK: Discovery

    @Test func discoversRolloutsUnderSessionsAndEveryJsonlUnderArchivedSessions() throws {
        let root = try makeTempDir()
        let wanted = [
            "sessions/2026/11/01/rollout-2026-11-01T05-35-15-01a1933e.jsonl",
            "sessions/2026/10/03/rollout-2026-10-03T09-15-53-01a0fee7.jsonl.zst",
            "sessions/2026/10/03/rollout-2026-10-03T09-15-53-01a0fee7_01a0f122.jsonl.zst",
            "archived_sessions/rollout-2026-08-23T23-07-20-01a02ebb.jsonl.zst",
            "archived_sessions/anything.jsonl",
            "archived_sessions/older/x.jsonl.zst",
        ]
        let unwanted = [
            "sessions/2026/11/01/notes.jsonl", "sessions/2026/11/01/rollout-x.json", "sessions/2026/11/01/rollout-x.jsonl.tmp",
            "sessions/2026/11/01/rollout-x.zst", "archived_sessions/readme.txt", "archived_sessions/x.jsonl.bak",
            "history.jsonl", "session_index.jsonl", "rollout-at-the-root.jsonl", "logs/rollout-x.jsonl",
        ]
        for name in wanted + unwanted { try write([], to: root.appendingPathComponent(name)) }

        let found = try reader.discover(root: root)
        #expect(Set(found.map { $0.resolvingSymlinksInPath().path }) == Set(wanted.map { root.appendingPathComponent($0).resolvingSymlinksInPath().path }))
        #expect(found.count == wanted.count)
    }

    @Test func aMissingSessionsDirectoryHasNoFiles() throws {
        let root = try makeTempDir()
        #expect(try reader.discover(root: root).isEmpty)
        #expect(try reader.discover(root: root.appendingPathComponent("not-there")).isEmpty)
    }

    @Test func readsTheCodexSource() {
        #expect(reader.source == .codex)
    }
}
