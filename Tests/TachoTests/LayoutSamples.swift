import Foundation
@testable import Tacho
import TachoKit

/// Made-up use for the layout matrix, at its widest: five CLIs, a model id as long as OpenRouter's, a scoped weekly limit, and four
/// limits with a record. Every name is public or made up, and nothing here came from a log.
enum LayoutSamples {
    /// As long as a real OpenRouter id, and the most used, so that Speed picks it and every list shows it.
    static let longModel = "meta-llama/llama-4-maverick-17b-128e-instruct-fp8-turbo"
    static let scope = "Sonnet 4.5 and Opus 4.1"

    private struct Dice {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        /// SplitMix64.
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }

        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }

        mutating func unit() -> Double {
            Double(next() >> 11) / Double(1 << 53)
        }
    }

    private static let tools: [(source: Source, provider: String, model: String, weight: Int)] = [
        (.opencode, "openrouter", longModel, 5),
        (.claudeCode, "anthropic", "claude-opus-5-5", 4),
        (.claudeCode, "anthropic", "claude-sonnet-5-5-20261104", 3),
        (.codex, "openai", "gpt-6.1-sol", 3),
        (.grok, "xai", "grok-4.3", 2),
        (.pi, "anthropic", "claude-haiku-5-5", 1),
    ]

    /// 120 days of use up to `now`, busy in its last half hour, with every request timed for the Speed page.
    static func events(now: Date, calendar: Calendar) -> [UsageEvent] {
        var dice = Dice(seed: 820)
        var events: [UsageEvent] = []
        let pool = tools.flatMap { Array(repeating: $0, count: $0.weight) }
        let today = calendar.startOfDay(for: now)
        func add(at time: Date, live: Bool = false) {
            let tool = pool[dice.int(0...(pool.count - 1))]
            let output = dice.int(200...2_400)
            events.append(UsageEvent(
                source: tool.source,
                client: "cli",
                dedupKey: "layout:\(events.count)",
                sessionId: "layout-\(events.count / 25)",
                project: ["/Users/demo/Code/demo-app", "/Users/demo/Code/notes-api", "/Users/demo/Code/pixel-garden"][dice.int(0...2)],
                isSubagent: !live && dice.unit() < 0.15,
                provider: tool.provider,
                model: tool.model,
                time: time,
                startTime: time.addingTimeInterval(-Double(output) / Double(dice.int(40...140)) - 1),
                tokens: TokenCounts(
                    input: dice.int(40...900),
                    output: output,
                    reasoning: tool.source == .codex ? output / 3 : 0,
                    cacheRead: dice.int(20_000...150_000),
                    cacheWrite5m: dice.int(600...6_000),
                    cacheWrite1h: dice.unit() < 0.2 ? dice.int(500...4_000) : 0
                )
            ))
        }
        for offset in (1...120).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today), dice.unit() > 0.1 else { continue }
            for _ in 0..<dice.int(15...45) {
                add(at: day.addingTimeInterval(Double(dice.int(8 * 3_600...23 * 3_600))))
            }
        }
        // Today, from the small hours, so that a late or early run has a day to draw.
        var time = today.addingTimeInterval(600)
        while time < now.addingTimeInterval(-20) {
            add(at: time, live: now.timeIntervalSince(time) < 1_800)
            time.addTimeInterval(Double(dice.int(60...900)))
        }
        return events
    }

    /// Each limit's readings, the windows before them included, so that every limit has a record and a forecast.
    static func snapshots(now: Date) -> [QuotaSnapshot] {
        func readings(_ provider: QuotaProvider, _ window: QuotaWindow, scope: String? = nil, resets: Date, peak: Double, step: TimeInterval) -> [QuotaSnapshot] {
            let opened = resets.addingTimeInterval(-window.length)
            let end = min(now.addingTimeInterval(-60), resets)
            let span = end.timeIntervalSince(opened)
            guard span > 0 else { return [] }
            return (Array(stride(from: step, to: span, by: step)) + [span]).map { elapsed in
                QuotaSnapshot(
                    provider: provider, window: window, scope: scope, usedPercent: (peak * elapsed * elapsed / (span * span)).rounded(),
                    resetsAt: resets, observedAt: opened.addingTimeInterval(elapsed), origin: provider == .openai ? .codexLog : .claudeCache
                )
            }
        }
        var snapshots: [QuotaSnapshot] = []
        let weekResets = now.addingTimeInterval(3 * 86_400 + 4 * 3_600)
        for (index, peak) in [58.0, 71, 64, 92, 66, 74, 100, 69].enumerated() {
            snapshots += readings(.anthropic, .weekly, resets: weekResets.addingTimeInterval(-Double(8 - index) * 7 * 86_400), peak: peak, step: 6 * 3_600)
        }
        snapshots += readings(.anthropic, .weekly, resets: weekResets, peak: 55, step: 3_600)
        snapshots += readings(.anthropic, .weekly, scope: scope, resets: weekResets, peak: 31, step: 3_600)
        snapshots += readings(.anthropic, .fiveHour, resets: now.addingTimeInterval(2.4 * 3_600), peak: 78, step: 600)
        snapshots += readings(.openai, .weekly, resets: now.addingTimeInterval(5 * 86_400), peak: 22, step: 3_600)
        snapshots += readings(.openai, .fiveHour, resets: now.addingTimeInterval(3.1 * 3_600), peak: 14, step: 600)
        return snapshots
    }

    /// A model that has read the samples to the end, in a sandbox that reads nothing else.
    @MainActor static func startedModel(_ sandbox: Sandbox, now: Date = Date()) async throws -> AppModel {
        try sandbox.seed {
            $0.askedAboutSources = true
            $0.askedAboutAnthropicQuery = true
            $0.enabledSources = Set(Source.allCases)
        }
        let support = sandbox.home.appendingPathComponent("Library/Application Support/Tacho", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let store = try EventStore(url: support.appendingPathComponent("tacho.sqlite"))
        try store.upsert(events(now: now, calendar: .current))
        try store.record(snapshots(now: now))
        let model = try ReadmeScreenshots.startedModel(sandbox)
        _ = await Tests.eventually(within: .seconds(60)) { model.dashboard?.progress.phase == .live }
        return model
    }
}
