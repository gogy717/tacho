import Foundation
import Testing
import TachoKit

struct ModelTests {
    @Test func theCacheHitRateIsCacheReadsOverThePrompt() {
        #expect(TokenCounts(input: 10, cacheRead: 30, cacheWrite5m: 5, cacheWrite1h: 5).cacheHitRate == 0.6)
        #expect(TokenCounts(input: 10).cacheHitRate == 0)
        #expect(TokenCounts(cacheRead: 10).cacheHitRate == 1)
    }

    /// Output is no part of a prompt, and with no prompt there is no rate: not a rate of 0.
    @Test func outputHasNoCacheHitRate() {
        #expect(TokenCounts(input: 10, output: 1_000, cacheRead: 10).cacheHitRate == 0.5)
        #expect(TokenCounts(output: 1_000).cacheHitRate == nil)
        #expect(TokenCounts.zero.cacheHitRate == nil)
    }

    /// Today's figure is still rising until the newest logs are read. Older logs do not change it.
    @Test(arguments: [
        (IngestProgress.Phase.idle, true),
        (.recent, true),
        (.history, false),
        (.live, false),
    ])
    func theNewestLogsAreBeingReadUntilTheHistory(phase: IngestProgress.Phase, reading: Bool) {
        #expect(IngestProgress(phase: phase, filesDone: 0, filesTotal: 0).isReadingNewest == reading)
    }

    @Test func totalIsTheSumOfDisjointCategories() {
        let t = TokenCounts(input: 2, output: 500, reasoning: 281, cacheRead: 28_102, cacheWrite5m: 0, cacheWrite1h: 27_045)
        #expect(t.total == 55_649); #expect(t.prompt == 55_149); #expect(t.cacheWrite == 27_045)
    }

    @Test func addingCountsAddsEveryField() {
        let a = TokenCounts(input: 1, output: 2, reasoning: 3, cacheRead: 4, cacheWrite5m: 5, cacheWrite1h: 6)
        #expect(a + a == TokenCounts(input: 2, output: 4, reasoning: 6, cacheRead: 8, cacheWrite5m: 10, cacheWrite1h: 12))
    }

    @Test func quotaWindowLengths() { #expect(QuotaWindow.fiveHour.length == 18_000); #expect(QuotaWindow.weekly.length == 604_800) }

    @Test func sourceNames() { #expect(Source.omp.displayName == "oh-my-pi"); #expect(Source.copilot.displayName == "Copilot CLI") }

    @Test func zeroIsTheIdentityAndPlusEqualsAccumulates() {
        let a = TokenCounts(input: 1, output: 2, reasoning: 3, cacheRead: 4, cacheWrite5m: 5, cacheWrite1h: 6)
        #expect(TokenCounts.zero == TokenCounts())
        #expect(a + .zero == a)
        var sum = TokenCounts.zero
        sum += a
        sum += a
        #expect(sum == a + a)
    }

    /// The raw value is persisted and prefixes every dedup key ("claudeCode:<requestId>"); the display name is user-visible.
    @Test func sourcesKeepTheirRawValueAndDisplayName() {
        let table: [(source: Source, raw: String, name: String)] = [
            (.claudeCode, "claudeCode", "Claude Code"), (.codex, "codex", "Codex"), (.omp, "omp", "oh-my-pi"),
            (.pi, "pi", "pi"), (.copilot, "copilot", "Copilot CLI"), (.opencode, "opencode", "OpenCode"),
            (.grok, "grok", "Grok Build"),
        ]
        #expect(Source.allCases == table.map { $0.source })
        for row in table {
            #expect(row.source.rawValue == row.raw)
            #expect(row.source.displayName == row.name)
        }
    }

    @Test func usageEventInitializerDefaultsOptionalFields() {
        let completed = Date(timeIntervalSince1970: 1_793_697_600)
        let tokens = TokenCounts(input: 1, output: 2)
        let e = UsageEvent(source: .codex, dedupKey: "codex:thread-1", time: completed, tokens: tokens)
        #expect(e.source == .codex)
        #expect(e.dedupKey == "codex:thread-1")
        #expect(e.time == completed)
        #expect(e.tokens == tokens)
        #expect(e.client == nil); #expect(e.sessionId == nil); #expect(e.project == nil)
        #expect(e.isSubagent == false)
        #expect(e.provider == nil); #expect(e.model == nil)
        #expect(e.startTime == nil); #expect(e.generationMs == nil)
        #expect(e.speed == nil); #expect(e.geo == nil)
    }

    @Test func usageEventInitializerStoresEveryField() {
        let completed = Date(timeIntervalSince1970: 1_793_697_600)
        let started = Date(timeIntervalSince1970: 1_793_697_590)
        let tokens = TokenCounts(input: 2, output: 500, reasoning: 281, cacheRead: 28_102, cacheWrite1h: 27_045)
        let e = UsageEvent(
            source: .claudeCode, client: "claude-desktop", dedupKey: "claudeCode:r1",
            sessionId: "s1", project: "/p", isSubagent: true,
            provider: "anthropic", model: "claude-opus-5-5",
            time: completed, startTime: started, generationMs: 5_533.5, speed: "fast", geo: "us",
            tokens: tokens
        )
        #expect(e.source == .claudeCode); #expect(e.client == "claude-desktop"); #expect(e.dedupKey == "claudeCode:r1")
        #expect(e.sessionId == "s1"); #expect(e.project == "/p"); #expect(e.isSubagent)
        #expect(e.provider == "anthropic"); #expect(e.model == "claude-opus-5-5")
        #expect(e.time == completed); #expect(e.startTime == started); #expect(e.generationMs == 5_533.5)
        #expect(e.speed == "fast"); #expect(e.geo == "us")
        #expect(e.tokens == tokens)
    }

    @Test func quotaSnapshotScopeAndPlanAreOptional() {
        let observed = Date(timeIntervalSince1970: 1_793_683_423)
        let resets = observed.addingTimeInterval(QuotaWindow.fiveHour.length)
        let plain = QuotaSnapshot(provider: .anthropic, window: .fiveHour, usedPercent: 3, resetsAt: resets, observedAt: observed, origin: .claudeCache)
        #expect(plain.scope == nil); #expect(plain.plan == nil)
        #expect(plain.provider == .anthropic); #expect(plain.window == .fiveHour); #expect(plain.usedPercent == 3)
        #expect(plain.resetsAt == resets); #expect(plain.observedAt == observed); #expect(plain.origin == .claudeCache)
        let scoped = QuotaSnapshot(provider: .anthropic, window: .weekly, scope: "Fable", usedPercent: 9, resetsAt: resets, observedAt: observed, origin: .anthropicAPI, plan: "max")
        #expect(scoped.scope == "Fable"); #expect(scoped.plan == "max")
        #expect(scoped != plain)
    }
}
