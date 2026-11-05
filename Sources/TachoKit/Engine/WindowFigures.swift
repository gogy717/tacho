import Foundation

// What the main window's pages read: direction B, section 16. Enabled sources only, so that a page agrees with the panel. Nothing
// here runs on the 1 s tick: a page calls when it opens, and when its range changes.

/// The range picker of a detail page: section 12.1.
public enum DetailRange: String, CaseIterable, Sendable {
    /// The 24 local hours of today.
    case day
    /// The last 7 local days, today so far the last of them.
    case week
    /// The last 30 local days, today so far the last of them.
    case month
    /// The last 12 calendar months, this month last.
    case year
}

/// What a detail chart can stack by, other than the kinds of token.
public enum DetailGrouping: String, CaseIterable, Sendable {
    case model
    /// By CLI.
    case source
}

/// The figure a chart draws, and so what a model or CLI ranks by there.
public enum DetailMeasure: CaseIterable, Sendable {
    case cost
    case allTokens
    case output
}

/// One model or CLI through a page's columns.
public struct DetailSeries: Equatable, Sendable {
    /// As `DetailFigures.byModel` and `bySource` have it: the model's id, "" for requests that name none, or the CLI's name.
    public var key: String
    /// One for each of `DetailFigures.columns`.
    public var tokens: [TokenCounts]
    /// One for each of `DetailFigures.columns`.
    public var cost: [CostSummary]

    public init(key: String, tokens: [TokenCounts], cost: [CostSummary]) {
        self.key = key
        self.tokens = tokens
        self.cost = cost
    }

    func values(of measure: DetailMeasure) -> [Double] {
        switch measure {
        case .cost: cost.map(\.usd)
        case .allTokens: tokens.map { Double($0.total) }
        case .output: tokens.map { Double($0.output) }
        }
    }
}

/// One layer of a stacked column.
public struct DetailLayer: Equatable, Sendable {
    /// nil for Other: what is left after the largest.
    public var key: String?
    /// One for each of `DetailFigures.columns`.
    public var values: [Double]

    public init(key: String?, values: [Double]) {
        self.key = key
        self.values = values
    }
}

/// One column of a detail chart: an hour, a day or a month by the range.
public struct DetailColumn: Equatable, Sendable {
    /// Where the column starts, local.
    public var start: Date
    public var tokens: TokenCounts
    public var cost: CostSummary
    /// `cost.usd` by the chart's layers.
    public var costByCategory: CategoryCost
    /// At least one event, as section 8.1 counts a day of use: an event can have no tokens.
    public var hasUse: Bool

    /// `hasUse` left out goes by the tokens.
    public init(start: Date, tokens: TokenCounts = .zero, cost: CostSummary = .zero, costByCategory: CategoryCost = .zero, hasUse: Bool? = nil) {
        self.start = start
        self.tokens = tokens
        self.cost = cost
        self.costByCategory = costByCategory
        self.hasUse = hasUse ?? (tokens.total > 0)
    }
}

/// A period added up.
public struct PeriodTotals: Equatable, Sendable {
    public var tokens: TokenCounts
    public var cost: CostSummary
    public var costByCategory: CategoryCost
    public var requests: Int
    /// How many of `requests` a sub-agent made.
    public var subagentRequests: Int
    public var daysWithUse: Int

    public init(
        tokens: TokenCounts = .zero,
        cost: CostSummary = .zero,
        costByCategory: CategoryCost = .zero,
        requests: Int = 0,
        subagentRequests: Int = 0,
        daysWithUse: Int = 0
    ) {
        self.tokens = tokens
        self.cost = cost
        self.costByCategory = costByCategory
        self.requests = requests
        self.subagentRequests = subagentRequests
        self.daysWithUse = daysWithUse
    }
}

/// Where a figure usually stands: what a detail chart draws behind its bars, and the `stat.usual` text. All empty under 7 days of use.
public struct UsualBands: Equatable, Sendable {
    /// Each local hour's own value across the kept days, 24 entries: the Day band.
    public var hourly: [UsualRange]
    /// Daily totals across the kept days: the Week and Month band.
    public var daily: UsualRange?
    /// The cumulative figure at this time of day.
    public var now: UsualRange?

    public init(hourly: [UsualRange] = [], daily: UsualRange? = nil, now: UsualRange? = nil) {
        self.hourly = hourly
        self.daily = daily
        self.now = now
    }
}

/// What the Cost, Tokens and Cache pages read. They share it: each draws its own part of the same columns.
public struct DetailFigures: Equatable, Sendable {
    public var range: DetailRange
    public var columns: [DetailColumn]
    public var totals: PeriodTotals
    /// As many days just before: Week and Month, the last of them cut at the time of day it is now, so that a period with today under way
    /// is set against as much of the one before. Empty for Day and Year.
    public var previousColumns: [DetailColumn]
    /// nil for Day and Year.
    public var previous: PeriodTotals?
    public var bySource: [BreakdownRow]
    public var byModel: [BreakdownRow]
    /// The named clients of each source, under the key that source has in `bySource`.
    public var clientsBySource: [String: [BreakdownRow]]
    /// What the range's cache reads kept off the bill: `usd` for the priced models, `unpricedTokens` the cache reads of the others.
    public var cacheSaving: CostSummary
    /// Days with use before today, up to 14.
    public var daysOfUse: Int
    public var usualCost: UsualBands
    public var usualTokens: UsualBands
    public var usualOutput: UsualBands
    /// The median day of Week and Month over the days before today with use, today being under way, and the median month of Year over
    /// those with use. nil for Day, with no use, or when the cost of what it goes on does not count as known: `Insights.unpricedTolerance`.
    public var medianCost: Double?
    /// Whether `previous` is a full period to compare with: history reaches its first day, and it had use.
    public var previousIsFull: Bool
    /// The column under way: Day's current hour, and today on Week and Month. nil for Year.
    public var currentColumn: Int?
    /// The page rules for these figures.
    public var highlights: DetailHighlights
    /// What the read asked `series` to be by, so that a page never draws one grouping under the name of another.
    public var grouping: DetailGrouping?
    /// Every model or CLI of the range, when the read asked for a grouping. Empty otherwise.
    public var series: [DetailSeries] = []

    public init(
        range: DetailRange,
        columns: [DetailColumn] = [],
        totals: PeriodTotals = PeriodTotals(),
        previousColumns: [DetailColumn] = [],
        previous: PeriodTotals? = nil,
        bySource: [BreakdownRow] = [],
        byModel: [BreakdownRow] = [],
        clientsBySource: [String: [BreakdownRow]] = [:],
        cacheSaving: CostSummary = .zero,
        daysOfUse: Int = 0,
        usualCost: UsualBands = UsualBands(),
        usualTokens: UsualBands = UsualBands(),
        usualOutput: UsualBands = UsualBands(),
        medianCost: Double? = nil,
        previousIsFull: Bool = false,
        currentColumn: Int? = nil,
        highlights: DetailHighlights = DetailHighlights()
    ) {
        self.range = range
        self.columns = columns
        self.totals = totals
        self.previousColumns = previousColumns
        self.previous = previous
        self.bySource = bySource
        self.byModel = byModel
        self.clientsBySource = clientsBySource
        self.cacheSaving = cacheSaving
        self.daysOfUse = daysOfUse
        self.usualCost = usualCost
        self.usualTokens = usualTokens
        self.usualOutput = usualOutput
        self.medianCost = medianCost
        self.previousIsFull = previousIsFull
        self.currentColumn = currentColumn
        self.highlights = highlights
    }
}

extension DetailFigures {
    /// Every column but `currentColumn`. On Week and Month these are the days before today, which is under way and so not yet what it
    /// will be: a median, and the rules that count days, go on these alone, though today's column is still drawn.
    var finishedDays: [DetailColumn] {
        columns.indices.filter { $0 != currentColumn }.map { columns[$0] }
    }
}

/// What the Speed page reads: section 12.6.
public struct SpeedFigures: Equatable, Sendable {
    /// A model with samples in the range.
    public struct Model: Equatable, Sendable {
        /// Its median over the range.
        public var speed: ModelSpeed
        /// Of its daily medians: section 8.1. nil under 7 such days.
        public var usual: UsualRange?
        /// Local days with at least 5 samples, of its newest 14 in 90 calendar days.
        public var speedDays: Int

        public init(speed: ModelSpeed, usual: UsualRange? = nil, speedDays: Int = 0) {
            self.speed = speed
            self.usual = usual
            self.speedDays = speedDays
        }
    }

    /// The chosen model in one hour, day or month.
    public struct Column: Equatable, Sendable {
        public var start: Date
        /// nil with no samples.
        public var tokensPerSecond: Double?
        public var samples: Int

        public init(start: Date, tokensPerSecond: Double? = nil, samples: Int = 0) {
            self.start = start
            self.tokensPerSecond = tokensPerSecond
            self.samples = samples
        }
    }

    public var range: DetailRange
    /// Most samples first.
    public var models: [Model]
    public var columns: [Column]
    /// Whether any model has been used today, which counts towards the days a usual range needs, as the panel's Speed card has it.
    public var todayHasUse = false

    public init(range: DetailRange, models: [Model] = [], columns: [Column] = []) {
        self.range = range
        self.models = models
        self.columns = columns
    }
}

/// What the Limits page reads beside its `Projection`: section 12.5.
public struct LimitHistory: Equatable, Sendable {
    /// Readings whose `resetsAt` are this close are one window.
    static let sameWindow: TimeInterval = 60

    /// One snapshot of a limit.
    public struct Reading: Equatable, Sendable {
        public var time: Date
        /// 0 to 100.
        public var percent: Double

        public init(time: Date, percent: Double) {
            self.time = time
            self.percent = percent
        }
    }

    /// A window of a limit, its snapshots grouped by `resetsAt` within 60 s.
    public struct Window: Equatable, Sendable {
        public var resetsAt: Date
        /// Its highest reading, 0 to 100.
        public var peak: Double

        public init(resetsAt: Date, peak: Double) {
            self.resetsAt = resetsAt
            self.peak = peak
        }

        public var reachedLimit: Bool { peak >= 100 }
    }

    /// Every snapshot of the current window, oldest first.
    public var readings: [Reading]
    /// The last 24 recorded windows, oldest first: the current one last once it has a snapshot.
    public var windows: [Window]
    /// False until the phase is `.live`: older windows may still arrive, so their peaks say nothing yet.
    public var isFullyRead: Bool

    public init(readings: [Reading] = [], windows: [Window] = [], isFullyRead: Bool = true) {
        self.readings = readings
        self.windows = windows
        self.isFullyRead = isFullyRead
    }
}

/// The Activity log's summary strip, for what a filter lets through: section 13.1.
public struct LogSummary: Equatable, Sendable {
    public var requests: Int
    public var cost: CostSummary
    public var output: Int
    /// `cacheRead ÷ prompt`, 0 to 1. nil with no prompt tokens.
    public var cacheHitRate: Double?
    /// 0 to 1. nil with no requests.
    public var subagentShare: Double?

    public init(requests: Int = 0, cost: CostSummary = .zero, output: Int = 0, cacheHitRate: Double? = nil, subagentShare: Double? = nil) {
        self.requests = requests
        self.cost = cost
        self.output = output
        self.cacheHitRate = cacheHitRate
        self.subagentShare = subagentShare
    }
}

extension DetailFigures {
    /// Whether today has any use yet: it counts towards the days a usual range needs. On Day the current column is an hour.
    public var todayHasUse: Bool {
        switch range {
        case .day: columns.contains(where: \.hasUse)
        case .week, .month: currentColumn.map { columns.indices.contains($0) && columns[$0].hasUse } ?? false
        case .year: false
        }
    }

    /// What `series` stacks into for `measure`: the `limit` largest over the period, largest first and a tie by key, then the rest as one layer.
    /// What has nothing to draw has no layer. For cost that takes in a model with no price, which has no amount: `totals.cost` goes on naming it.
    public func layers(of measure: DetailMeasure, limit: Int = 5) -> [DetailLayer] {
        let drawn = series
            .map { (layer: DetailLayer(key: $0.key, values: $0.values(of: measure)), key: $0.key, total: $0.values(of: measure).reduce(0, +)) }
            .filter { $0.total > 0 }
            .sorted { ($1.total, $0.key) < ($0.total, $1.key) }
            .map(\.layer)
        let rest = drawn.dropFirst(limit)
        guard !rest.isEmpty else { return drawn }
        return drawn.prefix(limit) + [DetailLayer(key: nil, values: columns.indices.map { index in rest.reduce(0) { $0 + $1.values[index] } })]
    }
}
