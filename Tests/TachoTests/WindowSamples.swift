import Foundation
@testable import Tacho
import TachoKit

/// Invented figures for the window's pages.
enum WindowSamples {
    static let now = Date(timeIntervalSince1970: 1_793_900_000)

    static func projection(
        provider: QuotaProvider = .anthropic,
        window: QuotaWindow = .fiveHour,
        scope: String? = nil,
        percent: Double,
        outcome: Projection.Outcome = .lastsUntilReset,
        method: Projection.Method = .calibrated,
        isStale: Bool = false,
        hasRecentData: Bool = true,
        recentPerHour: Double? = nil,
        windowPerHour: Double? = nil
    ) -> Projection {
        let resetsAt = now.addingTimeInterval(9_300)
        return Projection(
            snapshot: QuotaSnapshot(
                provider: provider,
                window: window,
                scope: scope,
                usedPercent: percent,
                resetsAt: resetsAt,
                observedAt: now.addingTimeInterval(-120),
                origin: .anthropicAPI
            ),
            estimatedPercent: percent,
            isEstimate: false,
            method: method,
            outcome: outcome,
            isStale: isStale,
            resetsAt: resetsAt,
            hasRecentData: hasRecentData,
            recentPercentPerHour: recentPerHour,
            windowPercentPerHour: windowPerHour
        )
    }

    /// A limit running out, as the engine says it: `beforeReset` is always what lies between the two.
    static func projection(empties: Date, resets: Date) -> Projection {
        var quota = projection(percent: 64, outcome: .runsOut(at: empties, beforeReset: resets.timeIntervalSince(empties)))
        quota.resetsAt = resets
        return quota
    }

    /// The turn of a minute, a little after `now`.
    static let turn = Date(timeIntervalSinceReferenceDate: 60 * 13_593_220)

    /// Two moments around a minute's turn, and what their printed times subtract to, where the moments alone round to something else.
    static let gaps: [(empties: Date, resets: Date, short: String)] = [
        (turn + 3, turn + 92 * 60 + 59, "1 h 32 min"), // 92:56 apart, which rounds up
        (turn + 58, turn + 93 * 60 + 1, "1 h 33 min"), // 92:03 apart, which rounds down
        (turn + 10, turn + 50, "under a minute"), // 40 s apart, in one minute
        (turn + 59, turn + 61, "1 min"), // 2 s apart, in two minutes
        (turn + 59, turn + 26 * 3_600 + 1, "1 d 2 h"), // a day out, where a time gets its weekday
    ]

    static func source(_ source: Source, today: TokenCounts = .zero, usd: Double = 0, hasQuota: Bool = false) -> SourceRow {
        SourceRow(
            source: source,
            clients: [],
            perMinute: 0,
            today: today,
            todayCost: CostSummary(usd: usd, unpricedModels: [], unpricedTokens: 0),
            lastActivity: now,
            isActive: true,
            costLastHour: CostSummary(usd: usd / 4, unpricedModels: [], unpricedTokens: 0),
            hasQuota: hasQuota
        )
    }

    static func dashboard(quotas: [Projection] = [], sources: [SourceRow] = [], today: TokenCounts = .zero, usd: Double = 0) -> Dashboard {
        Dashboard(
            perMinute: 0,
            perSecond: 0,
            isIdle: true,
            lastMinute: .zero,
            series: [],
            sources: sources,
            quotas: quotas,
            today: TodaySummary(tokens: today, cost: CostSummary(usd: usd, unpricedModels: [], unpricedTokens: 0), speeds: []),
            alert: .none,
            progress: IngestProgress(phase: .live, filesDone: 1, filesTotal: 1),
            outputPerMinute: 0,
            costPerMinute: .zero
        )
    }

    static let tokens = TokenCounts(input: 100, output: 1_000, reasoning: 0, cacheRead: 97_000, cacheWrite5m: 1_900)

    static func usd(_ usd: Double) -> CostSummary {
        CostSummary(usd: usd, unpricedModels: [], unpricedTokens: 0)
    }

    static func figures(
        range: DetailRange,
        tokens: TokenCounts = WindowSamples.tokens,
        usd: Double = 100,
        columns: Int = 7,
        bySource: [BreakdownRow] = [],
        byModel: [BreakdownRow] = [],
        clients: [String: [BreakdownRow]] = [:],
        daysOfUse: Int = 14,
        bands: UsualBands = UsualBands()
    ) -> DetailFigures {
        DetailFigures(
            range: range,
            columns: (0..<columns).map {
                DetailColumn(
                    start: now.addingTimeInterval(Double($0 - columns) * 86_400),
                    tokens: tokens,
                    cost: Self.usd(usd),
                    costByCategory: CategoryCost(input: 1, output: 28, cacheRead: 46, cacheWrite: 25)
                )
            },
            totals: PeriodTotals(tokens: tokens, cost: Self.usd(usd), costByCategory: CategoryCost(input: 1, output: 28, cacheRead: 46, cacheWrite: 25)),
            bySource: bySource,
            byModel: byModel,
            clientsBySource: clients,
            cacheSaving: Self.usd(864),
            daysOfUse: daysOfUse,
            usualCost: bands,
            usualTokens: bands,
            usualOutput: bands
        )
    }
}
