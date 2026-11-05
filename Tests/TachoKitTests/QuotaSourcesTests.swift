import Foundation
import GRDB
import Testing
import os
@testable import TachoKit

/// A clock tests move by hand.
private final class TestClock: Sendable {
    private let time: OSAllocatedUnfairLock<Date>

    init(_ start: Date) {
        time = OSAllocatedUnfairLock(initialState: start)
    }

    var now: Date { time.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        time.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Stands in for the network: answers every request with `status`, `headers` and `body`, and remembers what it was asked.
private final class StubServer: Sendable {
    private struct Answer {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    private let answer: OSAllocatedUnfairLock<Answer>
    private let requests = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    init(status: Int = 200, headers: [String: String] = [:], body: String = QuotaSourcesTests.usageBody) {
        answer = OSAllocatedUnfairLock(uncheckedState: Answer(status: status, headers: headers, body: Data(body.utf8)))
    }

    var received: [URLRequest] { requests.withLock { $0 } }

    func answer(status: Int, headers: [String: String] = [:], body: String = QuotaSourcesTests.usageBody) {
        answer.withLockUnchecked { $0 = Answer(status: status, headers: headers, body: Data(body.utf8)) }
    }

    @Sendable func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0.append(request) }
        let reply = answer.withLockUnchecked { $0 }
        let response = HTTPURLResponse(url: AnthropicUsageFetcher.url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        return (reply.body, try #require(response))
    }
}

/// Stands in for a server that redirects the usage URL elsewhere, and remembers the URLs it was asked for.
private final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
    static let requested = OSAllocatedUnfairLock<[URL]>(initialState: [])
    private static let elsewhere = URL(string: "https://elsewhere.example.invalid/")!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.requested.withLock { $0.append(url) }
        if url == Self.elsewhere {
            let answer = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client.urlProtocol(self, didReceive: answer, cacheStoragePolicy: .notAllowed)
        } else {
            let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": Self.elsewhere.absoluteString])!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: Self.elsewhere), redirectResponse: redirect)
            // Reached by a session that refuses the redirect, for which this response is the answer.
            client.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
        }
        client.urlProtocolDidFinishLoading(self)
    }
}

struct QuotaSourcesTests {
    static let usageBody = #"{"five_hour":{"utilization":5,"resets_at":"2026-11-03T09:20:00+00:00"},"seven_day":{"utilization":20,"resets_at":"2026-11-07T00:00:00+00:00"}}"#

    private static let claudeCache = #"{"oauthAccount":{"accountUuid":"acc1"},"cachedUsageUtilization":{"accountUuid":"acc1","fetchedAtMs":1793683423877,"utilization":{"limits":[{"kind":"session","percent":3,"resets_at":"2026-11-03T09:20:00.709695+00:00"},{"kind":"weekly_all","percent":14,"resets_at":"2026-11-04T00:00:00.709717+00:00"},{"kind":"weekly_scoped","percent":9,"resets_at":"2026-11-03T23:59:59.709869+00:00","scope":{"model":{"display_name":"Fable"}}}]}}}"#

    private static let now = date("2026-11-03T08:00:00Z")
    private static let resets = "2026-11-03T09:20:00Z"
    private static let resetsMs = 1793697600000.0

    /// `{"accountUuid":…,"utilization":…}` as `cachedUsageUtilization` of a config signed in to `acc1`.
    private func config(utilization: String, cacheAccount: String = "acc1", fetchedAt: String = #""fetchedAtMs":1793683423877"#) -> Data {
        Data(#"{"oauthAccount":{"accountUuid":"acc1"},"cachedUsageUtilization":{"accountUuid":"\#(cacheAccount)",\#(fetchedAt),"utilization":\#(utilization)}}"#.utf8)
    }

    private func limits(_ snapshots: [QuotaSnapshot]) -> [String] {
        snapshots.map { "\($0.provider.rawValue) \($0.window.rawValue) \($0.scope ?? "-") \($0.usedPercent)" }.sorted()
    }

    // MARK: Claude's cache

    @Test func parsesLimitsFromTheClaudeCache() throws {
        let snapshots = ClaudeCacheQuota.snapshots(claudeJSON: Data(Self.claudeCache.utf8))
        #expect(limits(snapshots) == ["anthropic fiveHour - 3.0", "anthropic weekly - 14.0", "anthropic weekly Fable 9.0"])
        #expect(snapshots.allSatisfy { $0.observedAt == ms(1793683423877) && $0.origin == .claudeCache })
        let resetsAt = try #require(snapshots.first { $0.window == .fiveHour }?.resetsAt)
        #expect(abs(resetsAt.timeIntervalSince(date("2026-11-03T09:20:00.709Z")) - 0.000695) < 0.000001)
    }

    @Test func fallsBackToFiveHourAndSevenDay() {
        let json = config(utilization: #"{"five_hour":{"utilization":2,"resets_at":"\#(Self.resets)"},"seven_day":{"utilization":13,"resets_at":"\#(Self.resets)"}}"#)
        #expect(limits(ClaudeCacheQuota.snapshots(claudeJSON: json)) == ["anthropic fiveHour - 2.0", "anthropic weekly - 13.0"])
    }

    @Test func aWindowInLimitsWinsOverItsLegacyField() {
        let json = config(utilization: #"{"limits":[{"kind":"session","percent":3,"resets_at":"\#(Self.resets)"}],"five_hour":{"utilization":2,"resets_at":"\#(Self.resets)"},"seven_day":{"utilization":13,"resets_at":"\#(Self.resets)"}}"#)
        #expect(limits(ClaudeCacheQuota.snapshots(claudeJSON: json)) == ["anthropic fiveHour - 3.0", "anthropic weekly - 13.0"])
    }

    @Test func ignoresTheCacheOfAnotherAccount() {
        let json = config(utilization: #"{"five_hour":{"utilization":2,"resets_at":"\#(Self.resets)"}}"#, cacheAccount: "acc2")
        #expect(ClaudeCacheQuota.snapshots(claudeJSON: json).isEmpty)
    }

    @Test func ignoresACacheWithoutAFetchTime() {
        let json = config(utilization: #"{"five_hour":{"utilization":2,"resets_at":"\#(Self.resets)"}}"#, fetchedAt: #""other":1"#)
        #expect(ClaudeCacheQuota.snapshots(claudeJSON: json).isEmpty)
    }

    @Test func readsNothingFromAFileThatIsNotJSON() {
        #expect(ClaudeCacheQuota.snapshots(claudeJSON: Data("{".utf8)).isEmpty)
        #expect(ClaudeCacheQuota.accountUuid(claudeJSON: Data("{".utf8)) == nil)
    }

    @Test func readsTheAccountOfTheConfig() {
        #expect(ClaudeCacheQuota.accountUuid(claudeJSON: Data(Self.claudeCache.utf8)) == "acc1")
        #expect(ClaudeCacheQuota.accountUuid(claudeJSON: Data("{}".utf8)) == nil)
    }

    /// A blank scope reads back from the store as no scope, so the model's figure would pass as the account's.
    @Test(arguments: [#""scope":{"model":{"display_name":""}},"#, #""scope":{"model":{"display_name":"  "}},"#, #""scope":{"model":{}},"#, ""])
    func dropsAScopedLimitWithoutAModelName(scope: String) {
        // Ahead of the account's own limit: the first of a window wins, so one let through would take its place.
        let body = #"{"limits":[{"kind":"weekly_scoped",\#(scope)"percent":90,"resets_at":"\#(Self.resets)"},{"kind":"weekly_all","percent":14,"resets_at":"\#(Self.resets)"}]}"#
        #expect(limits(ClaudeCacheQuota.snapshots(claudeJSON: config(utilization: body))) == ["anthropic weekly - 14.0"])
    }

    @Test func dropsAKindThatIsNoWindowOfOurs() {
        let body = #"{"limits":[{"kind":"session","percent":3,"resets_at":"\#(Self.resets)"},{"kind":"monthly_credits","percent":50,"resets_at":"\#(Self.resets)"}]}"#
        #expect(limits(ClaudeCacheQuota.snapshots(claudeJSON: config(utilization: body))) == ["anthropic fiveHour - 3.0"])
    }

    @Test(arguments: [#""resets_at":null,"#, #""resets_at":"soon","#, ""])
    func dropsALimitWithoutAResetTime(reset: String) {
        let body = #"{"limits":[{"kind":"session",\#(reset)"percent":3}],"seven_day":{\#(reset)"utilization":13}}"#
        #expect(ClaudeCacheQuota.snapshots(claudeJSON: config(utilization: body)).isEmpty)
    }

    @Test func keepsUseWithinAHundredPercent() {
        let body = #"{"five_hour":{"utilization":104.5,"resets_at":"\#(Self.resets)"},"seven_day":{"utilization":-1,"resets_at":"\#(Self.resets)"}}"#
        #expect(limits(ClaudeCacheQuota.snapshots(claudeJSON: config(utilization: body))) == ["anthropic fiveHour - 100.0", "anthropic weekly - 0.0"])
    }

    @Test func passesOnTheOriginAndPlanItIsGiven() {
        let body: [String: Any] = ["five_hour": ["utilization": 5, "resets_at": Self.resets]]
        let snapshot = ClaudeUsageParser.snapshots(utilization: body, observedAt: Self.now, origin: .anthropicAPI, plan: "max").first
        #expect(snapshot == QuotaSnapshot(
            provider: .anthropic, window: .fiveHour, usedPercent: 5, resetsAt: date(Self.resets), observedAt: Self.now, origin: .anthropicAPI, plan: "max"
        ))
    }

    // MARK: oh-my-pi's cache

    /// The `cache` table, as `.schema cache` prints it.
    private static let cacheSchema = """
        CREATE TABLE cache (
        				key TEXT PRIMARY KEY,
        				value TEXT NOT NULL,
        				expires_at INTEGER NOT NULL
        			);
        CREATE INDEX idx_cache_expires ON cache(expires_at);
        """

    /// A row of the `cache` table.
    private struct CacheRow {
        var key: String
        var value: String
        var expiresAt = 4_000_000_000
    }

    /// One limit of a report. oh-my-pi's report carries the account in `scope` and `metadata` too, as this one does.
    private func limit(
        _ id: String,
        label: String = "Limit",
        windowId: String = "7d",
        durationMs: Double? = 604_800_000,
        amount: String = #"{"usedFraction":0.25,"unit":"percent"}"#,
        status: String = "ok",
        resetsAt: Double? = QuotaSourcesTests.resetsMs
    ) -> String {
        let duration = durationMs.map { #","durationMs":\#($0)"# } ?? ""
        let reset = resetsAt.map { #","resetsAt":\#($0)"# } ?? ""
        return #"{"id":"\#(id)","label":"\#(label)","scope":{"provider":"p","accountId":"account-of-the-limit","windowId":"\#(windowId)","shared":true},"window":{"id":"\#(windowId)","label":"\#(windowId)"\#(duration)\#(reset)},"amount":\#(amount),"status":"\#(status)"}"#
    }

    /// oh-my-pi's envelope around a report.
    private func report(_ provider: String, fetchedAt: Double = 1793683423877, metadata: String = #"{"email":"someone@example.invalid"}"#, limits: [String]) -> String {
        #"{"value":{"provider":"\#(provider)","fetchedAt":\#(fetchedAt),"limits":[\#(limits.joined(separator: ","))],"metadata":\#(metadata)},"expiresAt":1}"#
    }

    /// A key as oh-my-pi builds one: its usage identity after the provider and base URL.
    private func key(_ provider: String, account: String?, base: String = "default") -> String {
        let identity = ["oauth", account.map { "account:\($0)" }, "email:someone@example.invalid"].compactMap { $0 }.joined(separator: "|")
        return "usage_cache:report:\(provider):\(base):\(identity)"
    }

    private func agentDB(_ rows: [CacheRow], at file: URL? = nil) throws -> URL {
        let file = try file ?? makeTempDir().appendingPathComponent("agent.db")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try DatabaseQueue(path: file.path)
        try writer.write { db in
            try db.execute(sql: Self.cacheSchema)
            for row in rows {
                try db.execute(sql: "INSERT INTO cache (key, value, expires_at) VALUES (?, ?, ?)", arguments: [row.key, row.value, row.expiresAt])
            }
        }
        try writer.close()
        return file
    }

    private func insert(_ row: CacheRow, with writer: DatabaseQueue) throws {
        try writer.write { try $0.execute(sql: "INSERT INTO cache (key, value, expires_at) VALUES (?, ?, ?)", arguments: [row.key, row.value, row.expiresAt]) }
    }

    /// An open connection to an empty `agent.db` in WAL mode, everything so far checkpointed.
    private func liveAgentDB(at file: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.journalMode = .wal
        let writer = try DatabaseQueue(path: file.path, configuration: configuration)
        try writer.write { try $0.execute(sql: Self.cacheSchema) }
        _ = try writer.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        return writer
    }

    /// Copies the files of a live database over those of `target`, which no process then holds.
    private func copyFiles(of source: URL, to target: URL, suffixes: [String]) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in suffixes {
            try Data(contentsOf: URL(fileURLWithPath: source.path + suffix)).write(to: URL(fileURLWithPath: target.path + suffix))
        }
    }

    private func anthropicRow(account: String?, percent: Double = 0.25) -> CacheRow {
        let amount = #"{"usedFraction":\#(percent),"unit":"percent"}"#
        return CacheRow(
            key: key("3:anthropic", account: account),
            value: report("anthropic", limits: [
                limit("anthropic:5h", windowId: "5h", durationMs: 18_000_000, amount: amount),
                limit("anthropic:7d", amount: amount),
            ])
        )
    }

    private func omp(_ rows: [CacheRow], account: String? = "acc1") throws -> [QuotaSnapshot] {
        try OmpQuotaCache.snapshots(agentDB: try agentDB(rows), anthropicAccount: account)
    }

    @Test func ompCacheKeepsTheSameAccount() throws {
        let xai = CacheRow(key: key("xai-oauth", account: "x1"), value: report("xai-oauth", limits: [limit("xai-oauth:credits:1w", windowId: "1w")]))
        let snapshots = try omp([anthropicRow(account: "acc1", percent: 0.25), anthropicRow(account: "acc2", percent: 0.75), xai])
        #expect(limits(snapshots) == ["anthropic fiveHour - 25.0", "anthropic weekly - 25.0", "xai weekly - 25.0"])
        #expect(snapshots.allSatisfy { $0.observedAt == ms(1793683423877) && $0.origin == .ompCache && $0.resetsAt == ms(Self.resetsMs) })
    }

    @Test func ompCacheMatchesTheWholeAccount() throws {
        var row = anthropicRow(account: "acc10")
        #expect(try omp([row]).isEmpty)
        row.key = "usage_cache:report:3:anthropic:default:oauth|subaccount:acc1|email:someone@example.invalid"
        #expect(try omp([row]).isEmpty)
    }

    /// oh-my-pi leaves out what it does not know of an account, so its uuid can be the last part of the key.
    @Test func ompCacheFindsAnAccountAtTheEndOfTheKey() throws {
        var row = anthropicRow(account: "acc1")
        row.key = "usage_cache:report:3:anthropic:default:oauth|account:acc1"
        #expect(try omp([row]).count == 2)
    }

    /// With no account to compare with, or none in the key, the report may be anyone's.
    @Test func ompCacheDropsAnthropicItCannotMatch() throws {
        #expect(try omp([anthropicRow(account: "acc1")], account: nil).isEmpty)
        #expect(try omp([anthropicRow(account: nil)]).isEmpty)
    }

    @Test func ompCacheNeedsNoClaudeAccountForOtherProviders() throws {
        let xai = CacheRow(key: key("xai-oauth", account: "x1"), value: report("xai-oauth", limits: [limit("xai-oauth:credits:1w", windowId: "1w")]))
        #expect(limits(try omp([xai], account: nil)) == ["xai weekly - 25.0"])
    }

    @Test func ompCacheMapsOpenAIAndItsPlan() throws {
        let codex = CacheRow(key: key("1:openai-codex", account: "o1"), value: report("openai-codex", metadata: #"{"planType":"plus"}"#, limits: [
            limit("openai-codex:primary", windowId: "5h", durationMs: 18_000_000),
            limit("openai-codex:secondary", windowId: "7d"),
        ]))
        let snapshots = try omp([codex])
        #expect(limits(snapshots) == ["openai fiveHour - 25.0", "openai weekly - 25.0"])
        #expect(snapshots.allSatisfy { $0.plan == "plus" })
    }

    /// `scope.shared` cannot tell these from the plan's own limits: oh-my-pi sets it on them too.
    @Test func ompCacheLeavesOutLimitsThatAreNotTheAccounts() throws {
        let xai = CacheRow(key: key("xai-oauth", account: "x1"), value: report("xai-oauth", limits: [
            limit("xai-oauth:product:grokbuild:1w", label: "Grok Build (Weekly)", windowId: "1w", amount: #"{"usedFraction":0.9,"unit":"percent"}"#),
            limit("xai-oauth:credits:1w", windowId: "1w"),
        ]))
        let codex = CacheRow(key: key("1:openai-codex", account: "o1"), value: report("openai-codex", limits: [
            limit("openai-codex:spark:secondary", label: "7 days (Spark)", amount: #"{"usedFraction":0.9,"unit":"percent"}"#),
        ]))
        #expect(limits(try omp([xai, codex])) == ["xai weekly - 25.0"])
    }

    @Test func ompCacheNamesAModelLimitAsClaudesCacheDoes() throws {
        let row = CacheRow(key: key("3:anthropic", account: "acc1"), value: report("anthropic", limits: [
            limit("anthropic:7d:fable", label: "Claude 7 Day (Fable)"),
            limit("anthropic:7d:nameless", label: "Claude 7 Day"),
            limit("anthropic:7d:blank", label: "Claude 7 Day ( )"),
        ]))
        #expect(limits(try omp([row])) == ["anthropic weekly Fable 25.0"])
    }

    @Test func ompCacheDropsAWindowOfAnotherLength() throws {
        let row = CacheRow(key: key("1:openai-codex", account: "o1"), value: report("openai-codex", limits: [
            limit("openai-codex:primary", windowId: "30d", durationMs: 2_592_000_000),
            limit("openai-codex:secondary", windowId: "1h", durationMs: 3_600_000),
        ]))
        #expect(try omp([row]).isEmpty)
    }

    @Test(arguments: [("5h", "fiveHour"), ("1w", "weekly"), ("7d", "weekly"), ("weekly", "weekly")])
    func ompCacheTakesTheLengthFromTheWindowsIdWhenItHasNoDuration(windowId: String, expected: String) throws {
        let row = CacheRow(key: key("xai-oauth", account: "x1"), value: report("xai-oauth", limits: [limit("xai-oauth:credits:1w", windowId: windowId, durationMs: nil)]))
        #expect(try omp([row]).map(\.window.rawValue) == [expected])
    }

    @Test func ompCacheTakesTheLengthFromTheWindowsIdWhenItsDurationIsZero() throws {
        let row = CacheRow(key: key("xai-oauth", account: "x1"), value: report("xai-oauth", limits: [limit("xai-oauth:credits:1w", windowId: "1w", durationMs: 0)]))
        #expect(try omp([row]).map(\.window) == [.weekly])
    }

    @Test(arguments: [
        (#"{"usedFraction":0.4,"used":1,"limit":100,"unit":"percent"}"#, 40.0),
        (#"{"used":30,"limit":200,"unit":"requests"}"#, 15.0),
        (#"{"used":38,"unit":"percent"}"#, 38.0),
        (#"{"remainingFraction":0.75,"unit":"percent"}"#, 25.0),
        (#"{"usedFraction":1.2,"unit":"percent"}"#, 100.0),
    ])
    func ompCacheReadsWhicheverAmountIsThere(amount: String, expected: Double) throws {
        let row = CacheRow(key: key("xai-oauth", account: "x1"), value: report("xai-oauth", limits: [limit("xai-oauth:credits:1w", windowId: "1w", amount: amount)]))
        #expect(try omp([row]).map(\.usedPercent) == [expected])
    }

    @Test func ompCacheDropsAnAmountItCannotRead() throws {
        let xai = { (amount: String, status: String) in
            CacheRow(key: self.key("xai-oauth:\(status)", account: "x1"), value: self.report("xai-oauth", limits: [self.limit("xai-oauth:credits:1w", windowId: "1w", amount: amount, status: status)]))
        }
        #expect(try omp([xai(#"{"used":0,"limit":0,"unit":"requests"}"#, "ok"), xai(#"{"usedFraction":0.9,"unit":"percent"}"#, "unknown")]).isEmpty)
    }

    @Test func ompCacheDropsALimitWithoutAResetTime() throws {
        let row = CacheRow(key: key("xai-oauth", account: "x1"), value: report("xai-oauth", limits: [limit("xai-oauth:credits:1w", windowId: "1w", resetsAt: nil)]))
        #expect(try omp([row]).isEmpty)
    }

    @Test func ompCacheSkipsRowsThatAreNotUsableReports() throws {
        let good = CacheRow(key: key("xai-oauth", account: "x1"), value: report("xai-oauth", limits: [limit("xai-oauth:credits:1w", windowId: "1w")]))
        let rows = [
            good,
            CacheRow(key: key("a", account: "x"), value: "{"),
            CacheRow(key: key("b", account: "x"), value: #"{"value":null,"expiresAt":1}"#),
            CacheRow(key: key("c", account: "x"), value: report("github-copilot", limits: [limit("copilot:chat", windowId: "1w")])),
            CacheRow(key: key("d", account: "x"), value: #"{"value":{"provider":"xai-oauth","limits":[]},"expiresAt":1}"#),
            CacheRow(key: "usage_cache:failure:x", value: good.value),
            CacheRow(key: key("e", account: "x"), value: good.value.replacingOccurrences(of: "1793683423877", with: "1793683423878"), expiresAt: 1),
        ]
        #expect(try omp(rows).map(\.observedAt) == [ms(1793683423877)])
    }

    /// `NOT NULL` is enforced on writes, not on reads: a half-written page can read as NULL, and only a table without it lets a
    /// test write that.
    @Test func ompCacheSkipsARowWithNoValue() throws {
        let good = CacheRow(key: key("xai-oauth", account: "x1"), value: report("xai-oauth", limits: [limit("xai-oauth:credits:1w", windowId: "1w")]))
        let file = try makeTempDir().appendingPathComponent("agent.db")
        let writer = try DatabaseQueue(path: file.path)
        try writer.write { db in
            try db.execute(sql: "CREATE TABLE cache (key TEXT, value TEXT, expires_at INTEGER)")
            try db.execute(sql: "INSERT INTO cache VALUES (?, NULL, ?)", arguments: [key("a", account: "x"), good.expiresAt])
            try db.execute(sql: "INSERT INTO cache VALUES (?, ?, ?)", arguments: [good.key, good.value, good.expiresAt])
        }
        try writer.close()
        #expect(limits(try OmpQuotaCache.snapshots(agentDB: file, anthropicAccount: nil)) == ["xai weekly - 25.0"])
    }

    @Test func ompCacheKeepsBracketsInAModelsName() throws {
        let row = CacheRow(key: key("3:anthropic", account: "acc1"), value: report("anthropic", limits: [limit("anthropic:7d:fable-preview", label: "Claude 7 Day (Fable (preview))")]))
        #expect(try omp([row]).map(\.scope) == ["Fable (preview)"])
    }

    @Test func ompCacheThrowsWithoutACacheTable() throws {
        let file = try makeTempDir().appendingPathComponent("agent.db")
        let writer = try DatabaseQueue(path: file.path)
        try writer.write { try $0.execute(sql: "CREATE TABLE other (id INTEGER)") }
        try writer.close()
        #expect(throws: (any Error).self) { try OmpQuotaCache.snapshots(agentDB: file, anthropicAccount: nil) }
    }

    // MARK: The usage endpoint

    private func token(expiresIn seconds: TimeInterval = 3_600) -> ClaudeToken {
        ClaudeToken(accessToken: "tok", expiresAt: Self.now.addingTimeInterval(seconds))
    }

    private func fetcher(_ server: StubServer, clock: TestClock = TestClock(QuotaSourcesTests.now), token: ClaudeToken? = nil) -> AnthropicUsageFetcher {
        let usable = token ?? self.token()
        return AnthropicUsageFetcher(token: { usable }, send: server.send, now: { clock.now })
    }

    @Test func fetcherSendsBearerAndBetaHeaders() async throws {
        let server = StubServer()
        let outcome = await fetcher(server).fetch()

        let request = try #require(server.received.first)
        #expect(server.received.count == 1)
        #expect(request.url == AnthropicUsageFetcher.url)
        #expect(AnthropicUsageFetcher.url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")

        guard case .snapshots(let snapshots) = outcome else {
            Issue.record("expected snapshots, got \(outcome)")
            return
        }
        #expect(limits(snapshots) == ["anthropic fiveHour - 5.0", "anthropic weekly - 20.0"])
        #expect(snapshots.allSatisfy { $0.origin == .anthropicAPI && $0.observedAt == Self.now })
    }

    @Test func fetcherSkipsAnExpiringToken() async {
        let server = StubServer()
        let outcome = await fetcher(server, token: token(expiresIn: 30)).fetch()
        guard case .skipped = outcome else {
            Issue.record("expected skipped, got \(outcome)")
            return
        }
        #expect(server.received.isEmpty)
    }

    @Test func fetcherUsesATokenWithAMinuteLeft() async {
        let server = StubServer()
        _ = await fetcher(server, token: token(expiresIn: 60)).fetch()
        #expect(server.received.count == 1)
    }

    @Test func fetcherBacksOffOn429() async {
        let server = StubServer(status: 429, headers: ["Retry-After": "120"], body: "{}")
        let clock = TestClock(Self.now)
        let fetcher = fetcher(server, clock: clock)

        #expect(await fetcher.fetch() == .backoff(until: Self.now.addingTimeInterval(120)))

        clock.advance(119)
        guard case .skipped = await fetcher.fetch() else {
            Issue.record("expected skipped during the back-off")
            return
        }
        #expect(server.received.count == 1)
    }

    @Test func fetcherAsksAgainOnceTheBackoffHasPassed() async {
        let server = StubServer(status: 429, headers: ["Retry-After": "120"], body: "{}")
        let clock = TestClock(Self.now)
        let fetcher = fetcher(server, clock: clock)
        _ = await fetcher.fetch()

        clock.advance(120)
        server.answer(status: 200)
        guard case .snapshots = await fetcher.fetch() else {
            Issue.record("expected snapshots after the back-off")
            return
        }
        #expect(server.received.count == 2)
    }

    /// An HTTP date is a time to wait until, in any of the three forms RFC 9110 has a recipient accept: ten minutes on from `now`.
    @Test(arguments: ["Tue, 03 Nov 2026 08:10:00 GMT", "Tuesday, 03-Nov-26 08:10:00 GMT", "Tue Nov  3 08:10:00 2026"])
    func fetcherBacksOffUntilAnHTTPDate(retryAfter: String) async {
        let server = StubServer(status: 429, headers: ["Retry-After": retryAfter], body: "{}")
        let clock = TestClock(Self.now)
        let fetcher = fetcher(server, clock: clock)

        #expect(await fetcher.fetch() == .backoff(until: Self.now.addingTimeInterval(600)))

        clock.advance(599)
        guard case .skipped = await fetcher.fetch() else {
            Issue.record("expected skipped during the back-off")
            return
        }
        #expect(server.received.count == 1)
    }

    /// A date already gone by says no more than a negative number of seconds does.
    @Test(arguments: [[:], ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"], ["Retry-After": "-5"]])
    func fetcherWaitsAnIntervalWhenItIsNotToldHowLong(headers: [String: String]) async {
        let server = StubServer(status: 429, headers: headers, body: "{}")
        #expect(await fetcher(server).fetch() == .backoff(until: Self.now.addingTimeInterval(300)))
    }

    @Test(arguments: [401, 403, 500, 302])
    func fetcherSkipsAnAnswerThatIsNotOK(status: Int) async {
        guard case .skipped = await fetcher(StubServer(status: status)).fetch() else {
            Issue.record("expected skipped for HTTP \(status)")
            return
        }
    }

    /// An error envelope parses as a quota with no windows, which must not pass for one.
    @Test(arguments: [#"{"error":{"type":"rate_limit_error"}}"#, "not json", "[]"])
    func fetcherSkipsABodyWithNoQuota(body: String) async {
        guard case .skipped = await fetcher(StubServer(body: body)).fetch() else {
            Issue.record("expected skipped for \(body)")
            return
        }
    }

    @Test func fetcherNeverRepeatsAFailuresTextOrTheToken() async {
        struct Failure: Error, CustomStringConvertible {
            var description: String { "failed sending Bearer tok" }
        }
        let fetcher = AnthropicUsageFetcher(token: { self.token() }, send: { _ in throw Failure() }, now: { Self.now })
        let outcome = await fetcher.fetch()
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected skipped, got \(outcome)")
            return
        }
        #expect(!reason.contains("tok"))
    }

    @Test func fetcherSkipsWithoutASignIn() async {
        let server = StubServer()
        let fetcher = AnthropicUsageFetcher(token: { nil }, send: server.send, now: { Self.now })
        guard case .skipped = await fetcher.fetch() else {
            Issue.record("expected skipped")
            return
        }
        #expect(server.received.isEmpty)
    }

    @Test func fetcherSkipsWhenTheSignInCannotBeRead() async {
        struct Unreadable: Error {}
        let server = StubServer()
        let fetcher = AnthropicUsageFetcher(token: { throw Unreadable() }, send: server.send, now: { Self.now })
        guard case .skipped = await fetcher.fetch() else {
            Issue.record("expected skipped")
            return
        }
        #expect(server.received.isEmpty)
    }

    @Test func parsesTheKeychainItem() {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1793690000000,"subscriptionType":"max"}}"#
        #expect(ClaudeToken.parse(Data(json.utf8)) == ClaudeToken(accessToken: "tok", expiresAt: ms(1793690000000)))
    }

    /// The spec promises the user that only `accessToken` and `expiresAt` are used, so the plan the item names goes no further.
    @Test func ignoresTheSubscriptionTypeOfTheKeychainItem() {
        let plain = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1793690000000}}"#
        let withPlan = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1793690000000,"subscriptionType":"max"}}"#
        #expect(ClaudeToken.parse(Data(withPlan.utf8)) == ClaudeToken.parse(Data(plain.utf8)))
    }

    @Test func fetchedSnapshotsNameNoPlan() async throws {
        let item = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1893690000000,"subscriptionType":"max"}}"#
        let server = StubServer()
        let fetcher = AnthropicUsageFetcher(token: { ClaudeToken.parse(Data(item.utf8)) }, send: server.send, now: { Self.now })
        guard case .snapshots(let snapshots) = await fetcher.fetch() else {
            Issue.record("expected snapshots")
            return
        }
        #expect(!snapshots.isEmpty)
        #expect(snapshots.allSatisfy { $0.plan == nil })
    }

    @Test(arguments: [
        #"{"claudeAiOauth":{"expiresAt":1793690000000}}"#,
        #"{"claudeAiOauth":{"accessToken":"","expiresAt":1793690000000}}"#,
        #"{"claudeAiOauth":{"accessToken":"to k","expiresAt":1793690000000}}"#,
        #"{"claudeAiOauth":{"accessToken":"tok"}}"#,
        #"{}"#,
        "not json",
    ])
    func refusesAKeychainItemItCannotUse(json: String) {
        #expect(ClaudeToken.parse(Data(json.utf8)) == nil)
    }

    @Test func commandOutputIsWhatTheCommandPrinted() throws {
        #expect(try AnthropicUsageFetcher.commandOutput("/bin/sh", ["-c", "printf out"], timeout: 10) == Data("out".utf8))
    }

    /// More than a pipe holds: a read that waited for the command to end first would hang.
    @Test func commandOutputTakesMoreThanAPipeHolds() throws {
        let output = try AnthropicUsageFetcher.commandOutput("/bin/sh", ["-c", "head -c 300000 /dev/zero"], timeout: 10)
        #expect(output?.count == 300_000)
    }

    @Test func commandOutputIsNilWhenTheCommandFails() throws {
        #expect(try AnthropicUsageFetcher.commandOutput("/bin/sh", ["-c", "printf out; exit 44"], timeout: 10) == nil)
    }

    @Test func commandOutputGivesUpAtTheTimeout() throws {
        let started = Date()
        #expect(try AnthropicUsageFetcher.commandOutput("/bin/sleep", ["30"], timeout: 0.1) == nil)
        // Under the 30 s the command would take, with room for a loaded CI runner.
        #expect(Date().timeIntervalSince(started) < 25)
    }

    @Test func commandOutputThrowsForACommandThatIsNotThere() {
        #expect(throws: (any Error).self) { try AnthropicUsageFetcher.commandOutput("/no/such/command", [], timeout: 10) }
    }

    @Test func theRealSendStopsAtARedirect() async throws {
        let configuration = AnthropicUsageFetcher.sessionConfiguration
        configuration.protocolClasses = [RedirectingProtocol.self]
        // The real 10 s limit is for a network. Nothing leaves this process here, and a loaded CI runner can take longer than that.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        RedirectingProtocol.requested.withLock { $0 = [] }

        let (_, response) = try await AnthropicUsageFetcher.send(URLRequest(url: AnthropicUsageFetcher.url), configuration: configuration)

        #expect(response.statusCode == 302)
        #expect(RedirectingProtocol.requested.withLock { $0 } == [AnthropicUsageFetcher.url])
    }

    @Test func theRealSessionKeepsNothingOnDisk() {
        let configuration = AnthropicUsageFetcher.sessionConfiguration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.timeoutIntervalForRequest == 10)
        #expect(configuration.timeoutIntervalForResource == 10)
    }

    // MARK: The poller

    private func home(config: String? = QuotaSourcesTests.claudeCache) throws -> URL {
        let home = try makeTempDir()
        if let config {
            try Data(config.utf8).write(to: claudeFile(in: home))
            try pin(claudeFile(in: home))
        }
        return home
    }

    private func claudeFile(in home: URL) -> URL {
        home.appendingPathComponent(".claude.json")
    }

    private func agentFile(in home: URL) -> URL {
        home.appendingPathComponent(".omp/agent/agent.db")
    }

    private func rowCount(in store: EventStore) throws -> Int? {
        try store.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM quotaSnapshot") }
    }

    /// Gives `file` a modification time of whole seconds: a finer one would not survive being set again.
    private func pin(_ file: URL, at time: Date = QuotaSourcesTests.now) throws {
        try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: file.path)
    }

    /// Rewrites a pinned `file` and pins it again, as a change no mtime shows.
    private func replace(_ file: URL, with content: String) throws {
        try Data(content.utf8).write(to: file)
        try pin(file)
    }

    @Test func pollerRecordsTheClaudeCacheOnce() async throws {
        let store = try EventStore.inMemory()
        let poller = QuotaPoller(store: store, home: try home(), fetcher: nil)

        await poller.pollOnce()
        #expect(limits(try store.latestSnapshots()) == ["anthropic fiveHour - 3.0", "anthropic weekly - 14.0", "anthropic weekly Fable 9.0"])

        await poller.pollOnce()
        #expect(try rowCount(in: store) == 3)
    }

    @Test func pollerLeavesAFileWithTheSameMtimeUnread() async throws {
        let store = try EventStore.inMemory()
        let home = try home()
        let poller = QuotaPoller(store: store, home: home, fetcher: nil)
        await poller.pollOnce()

        try replace(claudeFile(in: home), with: Self.claudeCache.replacingOccurrences(of: "1793683423877", with: "1793683423999"))
        await poller.pollOnce()

        #expect(try rowCount(in: store) == 3)
    }

    @Test func pollerReadsAFileAgainWhenItsMtimeChanges() async throws {
        let store = try EventStore.inMemory()
        let home = try home()
        let poller = QuotaPoller(store: store, home: home, fetcher: nil)
        await poller.pollOnce()

        try replace(claudeFile(in: home), with: Self.claudeCache.replacingOccurrences(of: "1793683423877", with: "1793683423999"))
        try pin(claudeFile(in: home), at: Self.now.addingTimeInterval(5))
        await poller.pollOnce()

        #expect(try rowCount(in: store) == 6)
    }

    /// Half a file is no JSON. Its mtime will not change again if the writer is done by the next poll.
    @Test func pollerReadsAgainAFileCaughtHalfWritten() async throws {
        let store = try EventStore.inMemory()
        let home = try home(config: "{")
        let poller = QuotaPoller(store: store, home: home, fetcher: nil)
        await poller.pollOnce()
        #expect(try rowCount(in: store) == 0)

        try replace(claudeFile(in: home), with: Self.claudeCache)
        await poller.pollOnce()
        #expect(try rowCount(in: store) == 3)
    }

    @Test func pollerReadsTheOmpCacheForTheClaudeAccount() async throws {
        let store = try EventStore.inMemory()
        let home = try home()
        _ = try agentDB([anthropicRow(account: "acc1"), anthropicRow(account: "acc2", percent: 0.75)].enumerated().map { index, row in
            var row = row
            row.value = row.value.replacingOccurrences(of: "1793683423877", with: "179368342400\(index)")
            return row
        }, at: agentFile(in: home))

        await QuotaPoller(store: store, home: home, fetcher: nil).pollOnce()

        let latest = try store.latestSnapshots()
        #expect(limits(latest) == ["anthropic fiveHour - 25.0", "anthropic weekly - 25.0", "anthropic weekly Fable 9.0"])
    }

    @Test func pollerLeavesClaudesConfigUnreadWhenClaudeCodeIsOff() async throws {
        let store = try EventStore.inMemory()
        let poller = QuotaPoller(store: store, home: try home(), fetcher: nil, enabled: [.omp])

        await poller.pollOnce()

        #expect(try rowCount(in: store) == 0)
    }

    @Test func pollerLeavesAgentDBUnreadWhenOmpIsOff() async throws {
        let store = try EventStore.inMemory()
        let home = try home(config: nil)
        let row = CacheRow(key: key("xai-oauth", account: "x1"), value: report("xai-oauth", limits: [limit("xai-oauth:credits:1w", windowId: "1w")]))
        _ = try agentDB([row], at: agentFile(in: home))

        await QuotaPoller(store: store, home: home, fetcher: nil, enabled: [.claudeCode]).pollOnce()
        #expect(try rowCount(in: store) == 0)

        await QuotaPoller(store: store, home: home, fetcher: nil, enabled: [.omp]).pollOnce()
        #expect(try rowCount(in: store) == 1)
    }

    /// The account oh-my-pi's report has to name comes from `~/.claude.json`, so with that file unread the report matches nothing.
    @Test func withClaudeCodeOffNoAccountReachesTheOmpQuery() async throws {
        let store = try EventStore.inMemory()
        let home = try home()
        _ = try agentDB([anthropicRow(account: "acc1")], at: agentFile(in: home))

        await QuotaPoller(store: store, home: home, fetcher: nil, enabled: [.omp]).pollOnce()

        #expect(try rowCount(in: store) == 0)
    }

    /// With neither file changed, only the switch can say that there is something to read.
    @Test func pollerReadsAFileWhenItsSourceComesBackOn() async throws {
        let store = try EventStore.inMemory()
        let poller = QuotaPoller(store: store, home: try home(), fetcher: nil, enabled: [])
        await poller.pollOnce()
        #expect(try rowCount(in: store) == 0)

        await poller.setEnabled([.claudeCode])
        await poller.pollOnce()

        #expect(try rowCount(in: store) == 3)
    }

    /// A write to `agent.db` lands in its `-wal`: the database's own mtime does not move until a checkpoint.
    @Test func pollerSeesAnOmpReportStillInTheJournal() async throws {
        let store = try EventStore.inMemory()
        let home = try home(config: nil)
        let file = agentFile(in: home)
        let live = try makeTempDir().appendingPathComponent("live.db")
        let writer = try liveAgentDB(at: live)
        try copyFiles(of: live, to: file, suffixes: ["", "-wal", "-shm"])
        let poller = QuotaPoller(store: store, home: home, fetcher: nil)
        await poller.pollOnce()

        let row = CacheRow(key: key("xai-oauth", account: "x1"), value: report("xai-oauth", limits: [limit("xai-oauth:credits:1w", windowId: "1w")]))
        try insert(row, with: writer)
        try copyFiles(of: live, to: file, suffixes: ["-wal", "-shm"])
        await poller.pollOnce()
        try writer.close()

        #expect(limits(try store.latestSnapshots()) == ["xai weekly - 25.0"])
    }

    @Test func pollerReadsOmpAgainWhenTheClaudeAccountChanges() async throws {
        let store = try EventStore.inMemory()
        let home = try home(config: #"{"oauthAccount":{"accountUuid":"acc2"}}"#)
        _ = try agentDB([anthropicRow(account: "acc1")], at: agentFile(in: home))
        let poller = QuotaPoller(store: store, home: home, fetcher: nil)
        await poller.pollOnce()
        #expect(try rowCount(in: store) == 0)

        try replace(claudeFile(in: home), with: #"{"oauthAccount":{"accountUuid":"acc1"}}"#)
        try pin(claudeFile(in: home), at: Self.now.addingTimeInterval(5))
        await poller.pollOnce()

        #expect(try rowCount(in: store) == 2)
    }

    /// `agent.db` is another app's and can be locked, or half-written under an immutable read.
    @Test func pollerTriesAgainAfterADatabaseItCouldNotRead() async throws {
        let store = try EventStore.inMemory()
        let home = try home(config: nil)
        let file = agentFile(in: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: file)
        try pin(file)
        let poller = QuotaPoller(store: store, home: home, fetcher: nil)
        await poller.pollOnce()

        try FileManager.default.removeItem(at: file)
        let row = CacheRow(key: key("xai-oauth", account: "x1"), value: report("xai-oauth", limits: [limit("xai-oauth:credits:1w", windowId: "1w")]))
        _ = try agentDB([row], at: file)
        try pin(file)
        await poller.pollOnce()

        #expect(try rowCount(in: store) == 1)
    }

    /// Only Anthropic's reports need the account that file names, and the file is read again once it is whole.
    @Test func pollerReadsOmpEvenWhenTheClaudeFileIsBad() async throws {
        let store = try EventStore.inMemory()
        let home = try home(config: "{")
        let row = CacheRow(key: key("xai-oauth", account: "x1"), value: report("xai-oauth", limits: [limit("xai-oauth:credits:1w", windowId: "1w")]))
        _ = try agentDB([row], at: agentFile(in: home))
        let poller = QuotaPoller(store: store, home: home, fetcher: nil)
        await poller.pollOnce()
        #expect(limits(try store.latestSnapshots()) == ["xai weekly - 25.0"])

        try replace(claudeFile(in: home), with: Self.claudeCache)
        await poller.pollOnce()
        #expect(try rowCount(in: store) == 4)
    }

    @Test func pollerRecordsNothingWithoutFiles() async throws {
        let store = try EventStore.inMemory()
        await QuotaPoller(store: store, home: try home(config: nil), fetcher: nil).pollOnce()
        #expect(try rowCount(in: store) == 0)
    }

    @Test func pollerFetchesEveryFiveMinutes() async throws {
        let store = try EventStore.inMemory()
        let server = StubServer()
        let clock = TestClock(Self.now)
        let poller = QuotaPoller(store: store, home: try home(config: nil), fetcher: fetcher(server, clock: clock), now: { clock.now })

        await poller.fetchIfDue()
        #expect(server.received.count == 1)
        #expect(limits(try store.latestSnapshots()) == ["anthropic fiveHour - 5.0", "anthropic weekly - 20.0"])

        clock.advance(299)
        await poller.fetchIfDue()
        #expect(server.received.count == 1)

        clock.advance(1)
        await poller.fetchIfDue()
        #expect(server.received.count == 2)
    }

    @Test func pollerFetchesNothingWithoutAFetcher() async throws {
        let store = try EventStore.inMemory()
        let server = StubServer()
        let clock = TestClock(Self.now)
        let poller = QuotaPoller(store: store, home: try home(config: nil), fetcher: fetcher(server, clock: clock), now: { clock.now })

        await poller.setFetcher(nil)
        await poller.fetchIfDue()
        #expect(server.received.isEmpty)
    }

    /// Switching the fetcher off and on again does not buy an extra request.
    @Test func aNewFetcherKeepsToTheInterval() async throws {
        let store = try EventStore.inMemory()
        let server = StubServer()
        let clock = TestClock(Self.now)
        let poller = QuotaPoller(store: store, home: try home(config: nil), fetcher: fetcher(server, clock: clock), now: { clock.now })
        await poller.fetchIfDue()

        await poller.setFetcher(nil)
        await poller.setFetcher(fetcher(server, clock: clock))
        await poller.fetchIfDue()

        #expect(server.received.count == 1)
    }

    @Test func startPollsAndFetchesUntilStopped() async throws {
        let store = try EventStore.inMemory()
        let server = StubServer()
        let poller = QuotaPoller(store: store, home: try home(), fetcher: fetcher(server))

        await poller.start()
        await poller.start()
        let deadline = Date().addingTimeInterval(5)
        while try rowCount(in: store) ?? 0 < 5, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        await poller.stop()

        #expect(try rowCount(in: store) == 5)
        #expect(server.received.count == 1)
    }
}
