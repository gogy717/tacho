import Foundation

/// One client of a source: a terminal, a desktop app, an editor.
public struct ClientRow: Equatable, Sendable {
    public var client: String
    public var perMinute: Int
    public var today: Int

    public init(client: String, perMinute: Int, today: Int) {
        self.client = client
        self.perMinute = perMinute
        self.today = today
    }
}

public struct SourceRow: Equatable, Sendable {
    public var source: Source
    public var clients: [ClientRow]
    public var perMinute: Int
    public var today: TokenCounts
    public var todayCost: CostSummary
    public var lastActivity: Date?
    public var isActive: Bool
    /// API-equivalent cost of (now − 3600, now].
    public var costLastHour: CostSummary
    /// Some event of this source today maps (`QuotaAttribution`) to a provider with a latest snapshot.
    public var hasQuota: Bool

    public init(
        source: Source,
        clients: [ClientRow],
        perMinute: Int,
        today: TokenCounts,
        todayCost: CostSummary,
        lastActivity: Date?,
        isActive: Bool,
        costLastHour: CostSummary,
        hasQuota: Bool
    ) {
        self.source = source
        self.clients = clients
        self.perMinute = perMinute
        self.today = today
        self.todayCost = todayCost
        self.lastActivity = lastActivity
        self.isActive = isActive
        self.costLastHour = costLastHour
        self.hasQuota = hasQuota
    }
}

public struct TodaySummary: Equatable, Sendable {
    public var tokens: TokenCounts
    public var cost: CostSummary
    public var speeds: [ModelSpeed]

    public init(tokens: TokenCounts, cost: CostSummary, speeds: [ModelSpeed]) {
        self.tokens = tokens
        self.cost = cost
        self.speeds = speeds
    }
}

extension IngestProgress {
    /// The newest logs are still being read, so today's figures are still rising. Reading older logs leaves today as it is.
    public var isReadingNewest: Bool {
        phase.isReadingNewest
    }
}

/// Everything the menu bar and the popover show.
public struct Dashboard: Equatable, Sendable {
    /// Every token of the rate window, per minute.
    public var perMinute: Int
    public var perSecond: Double
    /// No event in the rate window. Not the same as a `perMinute` of 0: a few tokens over the window round to that.
    public var isIdle: Bool
    /// The tokens of the rate window by category, each per minute.
    public var lastMinute: TokenCounts
    public var series: [TokenCounts]
    public var sources: [SourceRow]
    public var quotas: [Projection]
    public var today: TodaySummary
    public var alert: AlertLevel
    public var progress: IngestProgress
    /// The output of the rate window per minute, thinking included.
    public var outputPerMinute: Int
    /// What the rate window's tokens would cost at API prices, per minute, by the effective table.
    public var costPerMinute: CostSummary
    /// `series` in USD by layer, one entry a minute, oldest first. Priced tokens only: `series` still holds the others.
    public var costSeries: [CategoryCost]
    /// The latest request of any enabled source. nil with none yet.
    public var latestRequest: Date?
    /// The newest event on this machine, even one stamped after now, which `latestRequest` leaves out. nil with none yet.
    public var newestEvent: Date?

    /// How many models `costPerMinute` leaves out for having no price. A request that names no model is no model to count: it is
    /// only in `unpricedTokens`.
    public var unpricedModelsInRate: Int { costPerMinute.unpricedModels.count }

    public init(
        perMinute: Int,
        perSecond: Double,
        isIdle: Bool,
        lastMinute: TokenCounts,
        series: [TokenCounts],
        sources: [SourceRow],
        quotas: [Projection],
        today: TodaySummary,
        alert: AlertLevel,
        progress: IngestProgress,
        outputPerMinute: Int = 0,
        costPerMinute: CostSummary = .zero,
        costSeries: [CategoryCost] = [],
        latestRequest: Date? = nil,
        newestEvent: Date? = nil
    ) {
        self.perMinute = perMinute
        self.perSecond = perSecond
        self.isIdle = isIdle
        self.lastMinute = lastMinute
        self.series = series
        self.sources = sources
        self.quotas = quotas
        self.today = today
        self.alert = alert
        self.progress = progress
        self.outputPerMinute = outputPerMinute
        self.costPerMinute = costPerMinute
        self.costSeries = costSeries
        self.latestRequest = latestRequest
        self.newestEvent = newestEvent
    }
}

public struct BreakdownRow: Equatable, Sendable {
    public var key: String
    public var tokens: TokenCounts
    public var cost: CostSummary

    public init(key: String, tokens: TokenCounts, cost: CostSummary) {
        self.key = key
        self.tokens = tokens
        self.cost = cost
    }
}

public struct Overview: Equatable, Sendable {
    public var tokens: TokenCounts
    public var cost: CostSummary
    public var bySource, byModel, byProject: [BreakdownRow]
    public var speeds: [ModelSpeed]
    /// The named clients of each source, under the key that source has in `bySource`, biggest first; each row's key is the raw client.
    /// Events that name no client have no row, so a source that never does has no entry.
    public var clientsBySource: [String: [BreakdownRow]]

    public init(
        tokens: TokenCounts,
        cost: CostSummary,
        bySource: [BreakdownRow],
        byModel: [BreakdownRow],
        byProject: [BreakdownRow],
        speeds: [ModelSpeed],
        clientsBySource: [String: [BreakdownRow]] = [:]
    ) {
        self.tokens = tokens
        self.cost = cost
        self.bySource = bySource
        self.byModel = byModel
        self.byProject = byProject
        self.speeds = speeds
        self.clientsBySource = clientsBySource
    }
}

public struct LogRow: Equatable, Sendable {
    public var event: UsageEvent
    public var costUSD: Double?
    public var tokensPerSecond: Double?
    public var approximateSpeed: Bool

    public init(event: UsageEvent, costUSD: Double?, tokensPerSecond: Double?, approximateSpeed: Bool) {
        self.event = event
        self.costUSD = costUSD
        self.tokensPerSecond = tokensPerSecond
        self.approximateSpeed = approximateSpeed
    }
}

public struct DayCell: Equatable, Sendable {
    public var day: Date
    public var tokens: Int
    public var costUSD: Double

    public init(day: Date, tokens: Int, costUSD: Double) {
        self.day = day
        self.tokens = tokens
        self.costUSD = costUSD
    }
}

public struct Heatmaps: Equatable, Sendable {
    /// 365 local days ending today.
    public var days: [DayCell]
    public var hourOfWeek: [[Int]]

    public init(days: [DayCell], hourOfWeek: [[Int]]) {
        self.days = days
        self.hourOfWeek = hourOfWeek
    }
}
