import Foundation

/// What a skeleton method throws until the work behind it is done.
struct EngineNotImplemented: Error {}

/// USD by the chart's four layers, for one minute of `Dashboard.costSeries`.
public struct CategoryCost: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    /// Both cache lives together, as the chart draws them.
    public var cacheWrite: Double
    /// Tokens in none of the four, for want of a price.
    public var unpricedTokens: Int

    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0, unpricedTokens: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.unpricedTokens = unpricedTokens
    }

    public static let zero = CategoryCost()

    public var total: Double { input + output + cacheRead + cacheWrite }
}

/// A figure over the local day against where it usually stands: what a usual-range chart draws. Direction B, sections 3.3 and 8.1.
public struct UsualCurve: Equatable, Sendable {
    /// Where the figure usually stands at the end of one quarter hour.
    public struct Band: Equatable, Sendable {
        /// How far through the local day, 0 to 1.
        public var fraction: Double
        /// The 25th percentile.
        public var low: Double
        public var median: Double
        /// The 75th percentile.
        public var high: Double

        public init(fraction: Double, low: Double, median: Double, high: Double) {
            self.fraction = fraction
            self.low = low
            self.median = median
            self.high = high
        }

        /// Hours since local midnight, 0 to 24.
        public var hour: Double { fraction * 24 }
    }

    /// Today's cumulative figure at one moment.
    public struct Point: Equatable, Sendable {
        /// How far through the local day, 0 to 1.
        public var fraction: Double
        public var value: Double

        public init(fraction: Double, value: Double) {
            self.fraction = fraction
            self.value = value
        }

        /// Hours since local midnight, 0 to 24.
        public var hour: Double { fraction * 24 }
    }

    /// The 96 quarter hours of the day. Empty under 7 days of use.
    public var band: [Band]
    /// Today so far, ending at now.
    public var today: [Point]
    /// The median at this moment. nil under 7 days of use.
    public var usualNow: Double?

    public init(band: [Band] = [], today: [Point] = [], usualNow: Double? = nil) {
        self.band = band
        self.today = today
        self.usualNow = usualNow
    }
}

/// The figures of the Cache card that `InsightResults` does not hold.
public struct CacheFigures: Equatable, Sendable {
    /// Today's `cacheRead ÷ prompt`, 0 to 1. nil with no prompt tokens today.
    public var hitRate: Double?
    /// The daily hit rate of the last 7 days with use, oldest first.
    public var dailyHitRates: [Double]
    /// What today's cache reads kept off the bill: `usd` for the priced models, `unpricedTokens` the cache reads of the others.
    public var saving: CostSummary

    public init(hitRate: Double? = nil, dailyHitRates: [Double] = [], saving: CostSummary = .zero) {
        self.hitRate = hitRate
        self.dailyHitRates = dailyHitRates
        self.saving = saving
    }
}

/// The figures of the CLIs card that `InsightResults` does not hold.
public struct CLIFigures: Equatable, Sendable {
    /// A CLI's part of today.
    public struct Share: Equatable, Sendable {
        public var source: Source
        /// 0 to 1: of the cost, or of the tokens when anything today has no price. The basis of `CLIShareInsight`, so that the bar
        /// and the sentence beside it agree.
        public var fraction: Double

        public init(source: Source, fraction: Double) {
            self.source = source
            self.fraction = fraction
        }
    }

    /// Every CLI used today, largest first.
    public var shares: [Share]

    public init(shares: [Share] = []) {
        self.shares = shares
    }
}

/// Everything the panel shows that does not change second by second. See `Engine.insights`.
public struct PanelInsights: Equatable, Sendable {
    /// Which rule fires for each sentence, with its numbers. The needle of the Output and Speed cards comes from here too: each
    /// holds its `value` and its `range`.
    public var results: InsightResults
    /// Days with use before today, up to 14. A range exists from 7.
    public var daysOfUse: Int
    /// Priced tokens only, on both sides.
    public var cost: UsualCurve
    public var output: UsualCurve
    /// Every token: the scale on Summary.
    public var tokens: UsualCurve
    public var cache: CacheFigures
    public var clis: CLIFigures
    /// As `Heatmaps.hourOfWeek`: 7 rows of 24, row 0 being the calendar's first weekday. The 30 days before today, whatever is enabled.
    public var hourOfWeek: [[Int]]

    public init(
        results: InsightResults,
        daysOfUse: Int = 0,
        cost: UsualCurve = UsualCurve(),
        output: UsualCurve = UsualCurve(),
        tokens: UsualCurve = UsualCurve(),
        cache: CacheFigures = CacheFigures(),
        clis: CLIFigures = CLIFigures(),
        hourOfWeek: [[Int]] = []
    ) {
        self.results = results
        self.daysOfUse = daysOfUse
        self.cost = cost
        self.output = output
        self.tokens = tokens
        self.cache = cache
        self.clis = clis
        self.hourOfWeek = hourOfWeek
    }
}
