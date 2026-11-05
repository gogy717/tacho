import Foundation

// The rules behind the highlight sentences of direction B: `docs/design/direction-b-spec.md`, sections 8 and 11.
//
// Pure and deterministic: no database, no clock, no I/O. Everything here says which rule fired and with what numbers; the words are
// `Labels`'s. Case names are the spec's rule ids, so that the table and the code can be read side by side.

/// Where a value usually sits at this time of day: spec section 8.1.
public struct UsualRange: Equatable, Sendable {
    /// Days of use below this have no range.
    public static let minimumDays = 7
    /// How many of the newest days of use the range is taken over.
    public static let keptDays = 14

    public var p25: Double
    public var median: Double
    public var p75: Double

    public init(p25: Double, median: Double, p75: Double) {
        self.p25 = p25
        self.median = median
        self.p75 = p75
    }

    public enum Position: Equatable, Sendable { case below, inside, above }

    /// `values` are one figure per day, oldest first: only the newest `keptDays` count. nil under `minimumDays`.
    public static func of(_ values: [Double]) -> UsualRange? {
        let sorted = values.suffix(keptDays).sorted()
        guard sorted.count >= minimumDays else { return nil }
        return UsualRange(p25: quantile(sorted, 0.25), median: quantile(sorted, 0.5), p75: quantile(sorted, 0.75))
    }

    public func position(of value: Double) -> Position {
        if value > p75 { return .above }
        return value < p25 ? .below : .inside
    }

    /// The median of `values`, whatever their order. nil with none.
    static func median(of values: [Double]) -> Double? {
        values.isEmpty ? nil : quantile(values.sorted(), 0.5)
    }

    /// Linear interpolation, at position `(n − 1) × p`.
    fileprivate static func quantile(_ sorted: [Double], _ p: Double) -> Double {
        let position = Double(sorted.count - 1) * p
        let lower = Int(position)
        guard lower + 1 < sorted.count else { return sorted[lower] }
        return sorted[lower] + (sorted[lower + 1] - sorted[lower]) * (position - Double(lower))
    }
}

extension IngestProgress.Phase {
    /// Older days may still arrive until `.live`, so nothing may say days are missing.
    public var isReading: Bool { self != .live }

    /// The newest days are the ones being read, so today is not yet what it will be: nothing is compared with it.
    public var isReadingNewest: Bool { self == .idle || self == .recent }
}

/// What `Insights.compute` reads. Lane TE fills it; what is not known yet stays at its default.
public struct InsightInputs: Equatable, Sendable {
    /// A day with use before today, as it stood at this time of day: cumulative, priced tokens only for `cost`.
    public struct UsualDay: Equatable, Sendable {
        public var cost: Double
        public var output: Double

        public init(cost: Double, output: Double) {
            self.cost = cost
            self.output = output
        }
    }

    /// A model in the last 24 hours: for the card, the model with the most samples there.
    public struct Speed: Equatable, Sendable {
        public var model: String
        /// Its median tok/s today.
        public var today: Double
        /// Its median tok/s for each local day before today with at least 5 samples, oldest first, up to 90 calendar days back.
        public var dailyMedians: [Double]

        public init(model: String, today: Double, dailyMedians: [Double]) {
            self.model = model
            self.today = today
            self.dailyMedians = dailyMedians
        }
    }

    /// A CLI's share of today.
    public struct SourceToday: Equatable, Sendable {
        public var source: Source
        /// Priced tokens only.
        public var cost: Double
        public var tokens: Int
        /// The part of `tokens` that `cost` leaves out, as `CostSummary.unpricedTokens`.
        public var unpricedTokens: Int

        public init(source: Source, cost: Double, tokens: Int, unpricedTokens: Int = 0) {
            self.source = source
            self.cost = cost
            self.tokens = tokens
            self.unpricedTokens = unpricedTokens
        }
    }

    public var phase: IngestProgress.Phase
    public var todayTokens: TokenCounts
    public var todayCost: CostSummary
    /// The days with use before today, oldest first. Their number is `daysOfUse`, and only the newest 14 count.
    public var usualDays: [UsualDay]
    /// Output of the last 7 local days, today so far last: the Week columns Summary draws beside the sentence.
    public var outputLastSevenDays: Int
    /// Output of the 7 local days before those, the last cut at the time of day it is now. With all of that day in it, steady use would
    /// read about 14% down every morning.
    public var outputSevenDaysBefore: Int
    /// Every limit with a snapshot, `hasRecentData` or not.
    public var limits: [Projection]
    public var anthropicQueryEnabled: Bool
    /// Claude Code is one of the enabled sources, so the quota query has something to ask about.
    public var watchesClaude: Bool
    /// What today's cache reads kept off the bill: `usd` for the priced models, `unpricedTokens` the cache reads of the others.
    public var cacheSaving: CostSummary
    public var speed: Speed?
    /// Today, by enabled source.
    public var sources: [SourceToday]
    /// As `Heatmaps.hourOfWeek`: 7 rows of 24, row 0 being the calendar's first weekday.
    public var hourOfWeek: [[Int]]

    public init(
        phase: IngestProgress.Phase,
        todayTokens: TokenCounts = .zero,
        todayCost: CostSummary = .zero,
        usualDays: [UsualDay] = [],
        outputLastSevenDays: Int = 0,
        outputSevenDaysBefore: Int = 0,
        limits: [Projection] = [],
        anthropicQueryEnabled: Bool = false,
        watchesClaude: Bool = true,
        cacheSaving: CostSummary = .zero,
        speed: Speed? = nil,
        sources: [SourceToday] = [],
        hourOfWeek: [[Int]] = []
    ) {
        self.phase = phase
        self.todayTokens = todayTokens
        self.todayCost = todayCost
        self.usualDays = usualDays
        self.outputLastSevenDays = outputLastSevenDays
        self.outputSevenDaysBefore = outputSevenDaysBefore
        self.limits = limits
        self.anthropicQueryEnabled = anthropicQueryEnabled
        self.watchesClaude = watchesClaude
        self.cacheSaving = cacheSaving
        self.speed = speed
        self.sources = sources
        self.hourOfWeek = hourOfWeek
    }
}

/// Rules H: today against usual, section 8.2.
public enum TodayRule: Equatable, Sendable {
    /// Reading logs; today's figure is still rising.
    case h1
    /// Reading older logs; a usual range may follow.
    case h1h
    /// Under 7 days of use, `soFar` of them.
    case h2(soFar: Int)
    /// No tokens today.
    case h3
    /// `times` × usual, to one decimal.
    case h4(times: Double)
    /// `percent` above usual.
    case h5(percent: Int)
    /// Just above the range.
    case h5s
    /// Above, with a median too small for a percent to mean anything.
    case h6
    /// `percent` below usual, at most 99.
    case h7(percent: Int)
    /// Just below the range.
    case h7s
    /// Below, with a median too small for a percent to mean anything.
    case h7f
    /// Inside the range.
    case h8
    /// Some of today has no price, so it cannot be called inside or below.
    case h9
}

public struct TodayInsight: Equatable, Sendable {
    /// `M` of section 8.2.
    public enum Metric: Equatable, Sendable { case cost, output }
    /// How the Cost card draws: section 4.4. `none` is no comparison to show.
    public enum Verdict: Equatable, Sendable { case none, above, inside, below }

    public var rule: TodayRule
    public var metric: Metric
    /// Today so far, in `metric`.
    public var value: Double
    /// In `metric`, at this time of day. nil under 7 days of use, and while the newest logs are read.
    public var range: UsualRange?
    public var verdict: Verdict

    public init(rule: TodayRule, metric: Metric, value: Double, range: UsualRange?, verdict: Verdict) {
        self.rule = rule
        self.metric = metric
        self.value = value
        self.range = range
        self.verdict = verdict
    }
}

/// Rules L: the limits, section 8.3.
public enum LimitRule: Equatable, Sendable {
    /// Used up.
    case l1
    /// At 90% or more, not running out.
    case l2
    /// Runs out before it resets.
    case l3
    /// Every limit clear for now.
    case l4
    /// No limit looks at risk from the figures there are.
    case l5
    /// Snapshots exist, none current.
    case l6
    /// No snapshots, query off.
    case l7
    /// No snapshots, query on.
    case l8
    /// No snapshots, and no CLI here whose quota can be asked for.
    case l9
}

public struct LimitsInsight: Equatable, Sendable {
    public var rule: LimitRule
    /// The limit to name: the one the rule picked, or with nothing at risk the highest estimate (Summary's card). nil from L6 on.
    public var limit: Projection?

    public init(rule: LimitRule, limit: Projection?) {
        self.rule = rule
        self.limit = limit
    }
}

/// Rules WL: the sentence on Summary's limit card, section 11.1.
public enum SummaryLimitRule: Equatable, Sendable {
    /// Used up.
    case wl1
    /// At 90% or more, not running out.
    case wl2
    /// Runs out before it resets.
    case wl3
    /// Lasts until the reset.
    case wl4
    /// Not in use.
    case wl5
    /// No forecast.
    case wl6
}

/// Rules WC: the centre of the row under that card's chart.
public enum SummaryLimitCentre: Equatable, Sendable {
    /// The reset, and how long after the limit runs out.
    case wc1
    /// The reset.
    case wc2
}

extension LimitsInsight {
    /// nil with no limit to name: Summary then shows L6, L7 or L8 and no chart.
    public var summarySay: SummaryLimitRule? {
        guard let limit else { return nil }
        if Insights.isUsedUp(limit) { return .wl1 }
        if Insights.runOut(of: limit) != nil { return .wl3 }
        if Insights.isHigh(limit) { return .wl2 }
        switch limit.outcome {
        case .lastsUntilReset, .runsOut: return .wl4
        case .idle: return .wl5
        case .unknown: return .wl6
        }
    }

    public var summaryCentre: SummaryLimitCentre? {
        limit.map { Insights.runOut(of: $0) != nil ? .wc1 : .wc2 }
    }
}

/// Rules W: output this week, section 11.1.
public enum WeekRule: Equatable, Sendable {
    case w1(percent: Int)
    case w2(percent: Int)
    /// About the same.
    case w3
    /// Under 14 days of use, `soFar` of them.
    case w4(soFar: Int)
    /// Nothing in the 7 days before.
    case w5
    /// Still reading logs, in any phase before `.live`; the comparison may follow.
    case w6
}

/// Rules P1 to P4: the Output card, section 8.4.
public enum OutputRule: Equatable, Sendable {
    case p1
    case p2
    case p3
    /// Needs `daysLeft` more days of use, 2 or more.
    case p4(daysLeft: Int)
    /// Needs 1 more day of use.
    case p4s
    /// `reading.logs`: in place of P4 until the phase is `.live`, and of P1 to P3 too in `.idle` and `.recent`.
    case readingLogs
}

public struct OutputInsight: Equatable, Sendable {
    public var rule: OutputRule
    /// Output today so far.
    public var value: Double
    /// At this time of day. nil under 7 days of use, and while the newest logs are read: a needle would draw what the sentence holds back.
    public var range: UsualRange?

    public init(rule: OutputRule, value: Double, range: UsualRange?) {
        self.rule = rule
        self.value = value
        self.range = range
    }
}

/// Rules P5 to P7: the Cache card.
public enum CacheRule: Equatable, Sendable {
    /// `usd` kept off the bill.
    case p5(usd: Double)
    /// At least `usd`: some cache reads have no price.
    case p6(usd: Double)
    /// Nothing priced.
    case p7
}

/// Rules P4 and P8 to P10: the Speed card.
public enum SpeedRule: Equatable, Sendable {
    /// Needs `daysLeft` more days, 2 or more.
    case p4(daysLeft: Int)
    /// Needs 1 more day.
    case p4s
    /// Inside usual.
    case p8
    /// Above.
    case p9
    /// Below.
    case p10
    /// `reading.logs`: as `OutputRule.readingLogs`.
    case readingLogs
}

public struct SpeedInsight: Equatable, Sendable {
    public var rule: SpeedRule
    public var model: String
    /// Today's median tok/s.
    public var value: Double
    /// Of the model's daily medians. nil under 7 such days, and while the newest logs are read.
    public var range: UsualRange?

    public init(rule: SpeedRule, model: String, value: Double, range: UsualRange?) {
        self.rule = rule
        self.model = model
        self.value = value
        self.range = range
    }
}

/// Rule P12: the top CLI.
public struct CLIShareInsight: Equatable, Sendable {
    /// Cost share, or token share when any of today has no price.
    public enum Basis: Equatable, Sendable { case cost, tokens }

    public var source: Source
    public var percent: Int
    public var basis: Basis

    public init(source: Source, percent: Int, basis: Basis) {
        self.source = source
        self.percent = percent
        self.basis = basis
    }
}

/// Rule P14: the When you work card.
public enum WhenRule: Equatable, Sendable {
    /// `weekdayRow` is a row of `hourOfWeek`; `fromHour` to `toHour` the busiest 3 hours, `toHour` being `fromHour + 3` modulo 24.
    case p14(weekdayRow: Int, fromHour: Int, toHour: Int)
    /// Needs `daysLeft` more days of use, 1 or more.
    case needsDays(daysLeft: Int)
    /// `reading.logs`: until the phase is `.live`, as the grid is every log there is.
    case readingLogs
}

/// What `Insights.compute` returns. A nil rule has nothing to say: no cache reads, no speed samples, no use. Whether the card then has a
/// value of its own to show is the interface's call: with no cache reads, for one, the Cache card can still read 0% hit.
public struct InsightResults: Equatable, Sendable {
    public var today: TodayInsight
    public var limits: LimitsInsight
    public var week: WeekRule
    public var output: OutputInsight
    public var cache: CacheRule?
    public var speed: SpeedInsight?
    public var clis: CLIShareInsight?
    /// Rule P13: the percent of today's tokens that are cache reads.
    public var cacheReadPercent: Int?
    public var when: WhenRule?

    public init(
        today: TodayInsight,
        limits: LimitsInsight,
        week: WeekRule,
        output: OutputInsight,
        cache: CacheRule?,
        speed: SpeedInsight?,
        clis: CLIShareInsight?,
        cacheReadPercent: Int?,
        when: WhenRule?
    ) {
        self.today = today
        self.limits = limits
        self.week = week
        self.output = output
        self.cache = cache
        self.speed = speed
        self.clis = clis
        self.cacheReadPercent = cacheReadPercent
        self.when = when
    }
}

/// Rules D: the Cost page, section 12.2. A cost carries its `CostSummary`, so a figure with models left out can say so.
public enum CostHighlight: Equatable, Sendable {
    /// The sentence from rules H: the panel's `today`.
    case d1
    /// The current hour is the costliest of today.
    case d2(cost: CostSummary)
    /// Cache reads as shares of tokens and of cost.
    case d3(tokensPercent: Int, costPercent: Int)
    /// Up on the previous 7 days.
    case d4(percent: Int)
    /// Down on the previous 7 days.
    case d5(percent: Int)
    /// About the same as the previous 7 days.
    case d6
    /// The top `days` days, 1 or 2, carried `percent` of the week.
    case d7(days: Int, percent: Int)
    /// Output's share of cost moved.
    case d8(fromPercent: Int, toPercent: Int)
    /// Up on the previous 30 days.
    case d9(percent: Int)
    /// Down on the previous 30 days.
    case d10(percent: Int)
    /// About the same as the previous 30 days.
    case d11
    /// `days` days above the usual range.
    case d12(days: Int)
    /// `days` days with no use.
    case d13(days: Int)
    /// `month` is the start of the busiest month.
    case d14(month: Date, cost: CostSummary)
    /// `days` days with use.
    case d15(days: Int)
}

/// Rules T: the Tokens page, section 12.3.
public enum TokenHighlight: Equatable, Sendable {
    /// Thinking's share of the output of the sources that record it.
    case t1(percent: Int)
    /// Sub-agents' share of requests.
    case t2(percent: Int)
}

/// Rules K: the Cache page, section 12.4. Hit rates are percents, to one decimal.
public enum CacheHighlight: Equatable, Sendable {
    case k1(from: Double, to: Double)
    case k2(rate: Double)
    /// Cache reads as shares of tokens and of cost.
    case k3(tokensPercent: Int, costPercent: Int)
    /// Cache writes: their cost, and their shares of tokens and of the bill.
    case k4(usd: Double, tokensPercent: Int, costPercent: Int)
}

/// What a detail page says beside its figures. Until the phase is `.live` a page's figures are still arriving, so only D1 and W6 speak.
public struct DetailHighlights: Equatable, Sendable {
    /// In order, at most three.
    public var cost: [CostHighlight]
    public var tokens: [TokenHighlight]
    public var cache: [CacheHighlight]
    /// Rules W on output and on all tokens, for Tokens' Week. nil for any other range.
    public var weekOutput: WeekRule?
    public var weekTokens: WeekRule?

    public init(
        cost: [CostHighlight] = [],
        tokens: [TokenHighlight] = [],
        cache: [CacheHighlight] = [],
        weekOutput: WeekRule? = nil,
        weekTokens: WeekRule? = nil
    ) {
        self.cost = cost
        self.tokens = tokens
        self.cache = cache
        self.weekOutput = weekOutput
        self.weekTokens = weekTokens
    }
}

/// Rules LH: the Limits page, section 12.5. Paces are percents an hour, to one decimal.
public enum LimitHighlight: Equatable, Sendable {
    /// Running ahead of its average.
    case lh1(recent: Double, average: Double)
    /// Slower than its average.
    case lh2(recent: Double, average: Double)
    /// The median peak of the windows before this one.
    case lh3(medianPercent: Int)
    /// Past most of those peaks.
    case lh4
}

extension LimitHistory {
    /// The Limits page's rules for `limit`, whose record this is.
    public func highlights(for limit: Projection) -> [LimitHighlight] {
        Insights.limitHighlights(limit, history: self)
    }
}

public enum Insights {
    /// Which rule fires for each sentence, with its numbers.
    public static func compute(_ inputs: InsightInputs) -> InsightResults {
        InsightResults(
            today: today(inputs),
            limits: limits(inputs),
            week: week(inputs),
            output: output(inputs),
            cache: cache(inputs),
            speed: speed(inputs.speed, phase: inputs.phase, todayHasUse: inputs.todayTokens.total > 0),
            clis: clis(inputs),
            cacheReadPercent: cacheReadPercent(inputs),
            when: when(inputs)
        )
    }

    /// Below these a percent means nothing: `floor` of section 8.2.
    private static let costFloor = 0.50
    private static let outputFloor = 1_000.0
    /// How far from the median counts as a percent worth saying, and from where the figure reads better as a multiple.
    private static let smallestPercent = 5
    private static let multiplePercent = 300
    /// The share of a period's tokens that may have no price with its cost still counting as known, for D3 to D12, K3, K4 and `medianCost`.
    /// A cost with models left out is a lower bound, and moving to a model with no price must not read as a large fall. But a local model will
    /// never have a price, so with no tolerance a sliver would silence the page for good, and `cost.uncounted` already names what is left out.
    static let unpricedTolerance = 0.02
    private static let outputSharePoints = 3
    /// Half a point.
    private static let hitRateTenthsMoved = 5
    private static let peaksToSpeakOf = 5
    /// At or above this a limit warns.
    private static let highPercent = 90.0
    /// `when` needs this many days of use, as does a week against the one before.
    private static let fortnight = UsualRange.keptDays

    // MARK: Days of use

    /// The finished days, and today once it has any use: a card showing tokens must not say none have been seen. The usual range is
    /// still taken over finished days, so this can reach what a sentence asks for a day before the figure arrives.
    private static func daysSoFar(_ finished: Int, todayHasUse: Bool) -> Int {
        finished + (todayHasUse ? 1 : 0)
    }

    /// How many more days `needed` takes. Never under 1: the last day, under way, is still one more.
    public static func daysLeft(of needed: Int, finished: Int, todayHasUse: Bool) -> Int {
        max(1, needed - daysSoFar(finished, todayHasUse: todayHasUse))
    }

    // MARK: Rules H

    private static func today(_ inputs: InsightInputs) -> TodayInsight {
        let tokens = inputs.todayTokens.total
        let cost = inputs.todayCost
        let nothingPriced = tokens > 0 && cost.unpricedTokens > 0 && cost.usd == 0
        let metric: TodayInsight.Metric = nothingPriced ? .output : .cost
        let value = metric == .cost ? cost.usd : Double(inputs.todayTokens.output)
        let range = inputs.phase.isReadingNewest ? nil : UsualRange.of(inputs.usualDays.map { metric == .cost ? $0.cost : $0.output })
        func insight(_ rule: TodayRule, _ verdict: TodayInsight.Verdict = .none) -> TodayInsight {
            TodayInsight(rule: rule, metric: metric, value: value, range: range, verdict: verdict)
        }

        if inputs.phase.isReadingNewest { return insight(.h1) }
        guard let range else {
            return insight(inputs.phase == .history ? .h1h : .h2(soFar: daysSoFar(inputs.usualDays.count, todayHasUse: tokens > 0)))
        }
        guard tokens > 0 else { return insight(.h3) }

        let floor = metric == .cost ? costFloor : outputFloor
        if value > range.p75 {
            return insight(aboveRule(value, median: range.median, floor: floor), .above)
        }
        if metric == .cost, !cost.unpricedModels.isEmpty || cost.unpricedTokens > 0 { return insight(.h9) }
        if value < range.p25 {
            return insight(belowRule(value, median: range.median, floor: floor), .below)
        }
        return insight(.h8, .inside)
    }

    private static func aboveRule(_ value: Double, median: Double, floor: Double) -> TodayRule {
        guard median >= floor else { return .h6 }
        let percent = percent(value, from: median)
        if percent >= multiplePercent { return .h4(times: (value / median * 10).rounded() / 10) }
        return percent >= smallestPercent ? .h5(percent: percent) : .h5s
    }

    private static func belowRule(_ value: Double, median: Double, floor: Double) -> TodayRule {
        guard median >= floor else { return .h7f }
        let percent = percent(value, from: median)
        return percent >= smallestPercent ? .h7(percent: min(percent, 99)) : .h7s
    }

    /// `round(abs(value − base) ÷ base × 100)`. `base` is above 0: no rule gets here without a floor or a check of it.
    private static func percent(_ value: Double, from base: Double) -> Int {
        let percent = (abs(value - base) / base * 100).rounded()
        return percent < Double(Int.max / 2) ? Int(percent) : Int.max / 2
    }

    // MARK: Rules L

    private static func limits(_ inputs: InsightInputs) -> LimitsInsight {
        guard !inputs.limits.isEmpty else {
            guard inputs.watchesClaude else { return LimitsInsight(rule: .l9, limit: nil) }
            return LimitsInsight(rule: inputs.anthropicQueryEnabled ? .l8 : .l7, limit: nil)
        }
        let current = inputs.limits.filter(\.hasRecentData)
        guard !current.isEmpty else { return LimitsInsight(rule: .l6, limit: nil) }

        if let limit = best(current.filter(isUsedUp), by: { $0.resetsAt.timeIntervalSince1970 }) {
            return LimitsInsight(rule: .l1, limit: limit)
        }
        if let limit = best(current.filter { isHigh($0) && runOut(of: $0) == nil }, by: \.estimatedPercent) {
            return LimitsInsight(rule: .l2, limit: limit)
        }
        if let limit = best(current.filter { runOut(of: $0) != nil }, by: { -(runOut(of: $0)?.timeIntervalSince1970 ?? 0) }) {
            return LimitsInsight(rule: .l3, limit: limit)
        }
        // All of them, not only the current: "every limit" beside one with no recent data would not be true.
        let isClear = inputs.limits.allSatisfy {
            $0.hasRecentData && !$0.isStale && ($0.outcome == .lastsUntilReset || $0.outcome == .idle)
        }
        return LimitsInsight(rule: isClear ? .l4 : .l5, limit: best(current, by: \.estimatedPercent))
    }

    public static func isUsedUp(_ limit: Projection) -> Bool {
        limit.estimatedPercent.rounded() >= 100
    }

    fileprivate static func isHigh(_ limit: Projection) -> Bool {
        limit.estimatedPercent >= highPercent
    }

    fileprivate static func runOut(of limit: Projection) -> Date? {
        guard case .runsOut(let at, _) = limit.outcome else { return nil }
        return at
    }

    /// The first of `limits` with the largest `key`.
    private static func best(_ limits: [Projection], by key: (Projection) -> Double) -> Projection? {
        limits.reduce(nil) { best, limit in
            guard let best, key(limit) <= key(best) else { return limit }
            return best
        }
    }

    // MARK: Rules W

    private static func week(_ inputs: InsightInputs) -> WeekRule {
        // Both weeks have to be read in full, and `.history` is still reading the one before.
        guard !inputs.phase.isReading else { return .w6 }
        return week(last: Double(inputs.outputLastSevenDays), before: Double(inputs.outputSevenDaysBefore), days: inputs.usualDays.count, todayHasUse: inputs.todayTokens.total > 0)
    }

    /// `days` are the days with use before today.
    private static func week(last: Double, before: Double, days: Int, todayHasUse: Bool) -> WeekRule {
        guard days >= fortnight else { return .w4(soFar: daysSoFar(days, todayHasUse: todayHasUse)) }
        guard before > 0 else { return .w5 }
        let percent = percent(last, from: before)
        guard percent >= smallestPercent else { return .w3 }
        if last > before { return .w1(percent: percent) }
        // Some use is not 100% down, as in H7.
        return .w2(percent: last > 0 ? min(percent, 99) : percent)
    }

    // MARK: Rules D, T and K

    /// The page rules for `figures`. Until `.live` the older days are still arriving, so nothing here can be trusted but D1, which is rules H.
    static func highlights(of figures: DetailFigures, phase: IngestProgress.Phase) -> DetailHighlights {
        let isWeek = figures.range == .week
        guard !phase.isReading else {
            return DetailHighlights(cost: figures.range == .day ? [.d1] : [], weekOutput: isWeek ? .w6 : nil, weekTokens: isWeek ? .w6 : nil)
        }
        let before = figures.previous?.tokens ?? .zero
        let todayHasUse = figures.todayHasUse
        return DetailHighlights(
            cost: Array(costRules(figures).prefix(3)),
            tokens: [thinking(figures), subagents(figures)].compactMap { $0 },
            cache: cacheRules(figures),
            weekOutput: isWeek ? week(last: Double(figures.totals.tokens.output), before: Double(before.output), days: figures.daysOfUse, todayHasUse: todayHasUse) : nil,
            weekTokens: isWeek ? week(last: Double(figures.totals.tokens.total), before: Double(before.total), days: figures.daysOfUse, todayHasUse: todayHasUse) : nil
        )
    }

    private static func costRules(_ figures: DetailFigures) -> [CostHighlight] {
        let reads = cacheReadShares(figures.totals).map { CostHighlight.d3(tokensPercent: $0.tokens, costPercent: $0.cost) }
        let moved = costMovement(figures)
        let rules: [CostHighlight?]
        switch figures.range {
        case .day:
            rules = [.d1, currentHourLeads(figures), reads]
        case .week:
            rules = [reads, moved.map { $0.rule(up: CostHighlight.d4, down: CostHighlight.d5, same: .d6) }, topDays(figures), outputShare(figures)]
        case .month:
            rules = [reads, moved.map { $0.rule(up: CostHighlight.d9, down: CostHighlight.d10, same: .d11) }, daysAboveUsual(figures), daysWithNoUse(figures)]
        case .year:
            rules = [reads, busiestMonth(figures), figures.totals.daysWithUse > 0 ? .d15(days: figures.totals.daysWithUse) : nil]
        }
        return rules.compactMap { $0 }
    }

    /// Whether the cost of `totals` counts as known: see `unpricedTolerance`.
    static func isCostKnown(_ totals: PeriodTotals) -> Bool {
        isCostKnown(unpriced: totals.cost.unpricedTokens, of: totals.tokens.total)
    }

    /// Whether the cost of `columns` counts as known, for a figure that goes on them alone.
    static func isCostKnown(_ columns: [DetailColumn]) -> Bool {
        isCostKnown(unpriced: columns.reduce(0) { $0 + $1.cost.unpricedTokens }, of: columns.reduce(0) { $0 + $1.tokens.total })
    }

    private static func isCostKnown(unpriced: Int, of tokens: Int) -> Bool {
        unpriced == 0 || Double(unpriced) < Double(tokens) * unpricedTolerance
    }

    /// The previous period, when both it and this one can be compared on cost.
    private static func comparablePrevious(_ figures: DetailFigures) -> PeriodTotals? {
        guard figures.previousIsFull, let previous = figures.previous, previous.cost.usd > 0,
              isCostKnown(previous), isCostKnown(figures.totals) else { return nil }
        return previous
    }

    private enum Movement {
        case up(Int), down(Int), same

        func rule(up: (Int) -> CostHighlight, down: (Int) -> CostHighlight, same: CostHighlight) -> CostHighlight {
            switch self {
            case .up(let percent): up(percent)
            case .down(let percent): down(percent)
            case .same: same
            }
        }
    }

    private static func costMovement(_ figures: DetailFigures) -> Movement? {
        guard let previous = comparablePrevious(figures) else { return nil }
        let last = figures.totals.cost.usd
        let percent = percent(last, from: previous.cost.usd)
        guard percent >= smallestPercent else { return .same }
        if last > previous.cost.usd { return .up(percent) }
        // Some use is not 100% down, as in H7.
        return .down(last > 0 ? min(percent, 99) : percent)
    }

    /// Cache reads as shares of tokens and of cost, for D3 and K3: reads of nothing, or at no known cost, say nothing.
    private static func cacheReadShares(_ totals: PeriodTotals) -> (tokens: Int, cost: Int)? {
        guard totals.tokens.cacheRead > 0, totals.cost.usd > 0, isCostKnown(totals) else { return nil }
        return (share(Double(totals.tokens.cacheRead), of: Double(totals.tokens.total)), share(totals.costByCategory.cacheRead, of: totals.cost.usd))
    }

    private static func currentHourLeads(_ figures: DetailFigures) -> CostHighlight? {
        let columns = figures.columns
        guard let current = figures.currentColumn, columns.indices.contains(current), figures.totals.cost.unpricedTokens == 0,
              columns.filter(\.hasUse).count >= 2,
              columns.indices.allSatisfy({ $0 == current || columns[$0].cost.usd < columns[current].cost.usd })
        else { return nil }
        return .d2(cost: columns[current].cost)
    }

    /// Today is under way, so it is not one of the days that carried the week, though what it has cost so far is part of the week.
    private static func topDays(_ figures: DetailFigures) -> CostHighlight? {
        // Of the columns, not `totals`, and both in the same order: summed otherwise they can differ in the last place, and then all of
        // it would read 99%.
        let week = figures.columns.map(\.cost.usd).filter { $0 > 0 }.sorted(by: >).reduce(0, +)
        let top = figures.finishedDays.map(\.cost.usd).filter { $0 > 0 }.sorted(by: >).prefix(2)
        let held = top.reduce(0, +)
        guard week > 0, isCostKnown(figures.totals), held * 2 >= week else { return nil }
        return .d7(days: top.count, percent: share(held, of: week))
    }

    /// Goes by the rounded shares, which are what the sentence prints.
    private static func outputShare(_ figures: DetailFigures) -> CostHighlight? {
        guard let previous = comparablePrevious(figures), figures.totals.cost.usd > 0 else { return nil }
        let from = share(previous.costByCategory.output, of: previous.cost.usd)
        let to = share(figures.totals.costByCategory.output, of: figures.totals.cost.usd)
        return abs(to - from) >= outputSharePoints ? .d8(fromPercent: from, toPercent: to) : nil
    }

    /// Today so far is not yet what it will be, so it is neither above the range nor inside it, and the tolerance is of the days counted.
    private static func daysAboveUsual(_ figures: DetailFigures) -> CostHighlight? {
        let days = figures.finishedDays
        guard let usual = figures.usualCost.daily, isCostKnown(days) else { return nil }
        let above = days.filter { usual.position(of: $0.cost.usd) == .above }.count
        return above > 0 ? .d12(days: above) : nil
    }

    /// Today is under way: nothing in it yet does not make it a day with no use.
    private static func daysWithNoUse(_ figures: DetailFigures) -> CostHighlight? {
        let days = figures.finishedDays.filter { !$0.hasUse }.count
        return days > 0 ? .d13(days: days) : nil
    }

    private static func busiestMonth(_ figures: DetailFigures) -> CostHighlight? {
        guard let month = figures.columns.max(by: { $0.cost.usd < $1.cost.usd }), month.cost.usd > 0 else { return nil }
        return .d14(month: month.start, cost: month.cost)
    }

    private static func thinking(_ figures: DetailFigures) -> TokenHighlight? {
        let recording = figures.bySource.filter { $0.tokens.reasoning > 0 }
        guard !recording.isEmpty else { return nil }
        let reasoning = recording.reduce(0) { $0 + $1.tokens.reasoning }
        return .t1(percent: share(Double(reasoning), of: Double(recording.reduce(0) { $0 + $1.tokens.output })))
    }

    private static func subagents(_ figures: DetailFigures) -> TokenHighlight? {
        let totals = figures.totals
        return totals.requests > 0 ? .t2(percent: share(Double(totals.subagentRequests), of: Double(totals.requests))) : nil
    }

    private static func cacheRules(_ figures: DetailFigures) -> [CacheHighlight] {
        let totals = figures.totals
        let reads = cacheReadShares(totals).map { CacheHighlight.k3(tokensPercent: $0.tokens, costPercent: $0.cost) }
        var writes: CacheHighlight?
        if totals.tokens.cacheWrite > 0, totals.cost.usd > 0, isCostKnown(totals) {
            let usd = totals.costByCategory.cacheWrite
            writes = .k4(usd: usd, tokensPercent: share(Double(totals.tokens.cacheWrite), of: Double(totals.tokens.total)), costPercent: share(usd, of: totals.cost.usd))
        }
        return [hitRateMovement(figures), reads, writes].compactMap { $0 }
    }

    private static func hitRateMovement(_ figures: DetailFigures) -> CacheHighlight? {
        guard figures.range == .week, figures.previousIsFull, let previous = figures.previous,
              let now = hitRateTenths(figures.totals.tokens), let before = hitRateTenths(previous.tokens) else { return nil }
        let to = Double(now) / 10
        return abs(now - before) >= hitRateTenthsMoved ? .k1(from: Double(before) / 10, to: to) : .k2(rate: to)
    }

    /// In tenths of a percent, as the sentences print it, so what moved is what they show. nil with no prompt tokens.
    private static func hitRateTenths(_ tokens: TokenCounts) -> Int? {
        tokens.cacheHitRate.map { Int(($0 * 1_000).rounded()) }
    }

    // MARK: Rules LH

    /// A limit with no recent data has no pace, and no reading to set against its peaks. The window it is in, which ends at the forecast's
    /// reset, has not peaked, so it is not one of them; with no snapshot since the last reset, the snapshot's window has finished and is.
    /// Until the record is fully read, older windows may still arrive, so its peaks say nothing yet.
    static func limitHighlights(_ limit: Projection, history: LimitHistory) -> [LimitHighlight] {
        var rules = [limit.hasRecentData ? pace(limit) : nil].compactMap { $0 }
        let peaks = history.windows
            .filter { abs($0.resetsAt.timeIntervalSince(limit.resetsAt)) > LimitHistory.sameWindow }
            .map(\.peak)
            .sorted()
        guard history.isFullyRead, peaks.count >= peaksToSpeakOf else { return rules }
        rules.append(.lh3(medianPercent: Int(UsualRange.quantile(peaks, 0.5).rounded())))
        if limit.hasRecentData, limit.estimatedPercent > UsualRange.quantile(peaks, 0.75) { rules.append(.lh4) }
        return rules
    }

    /// The printed figures have to differ too: `0.3% against 0.3%` cannot read as running ahead.
    private static func pace(_ limit: Projection) -> LimitHighlight? {
        guard limit.method == .calibrated,
              let recent = limit.recentPercentPerHour, recent > 0,
              let average = limit.windowPercentPerHour, average > 0 else { return nil }
        let printedRecent = (recent * 10).rounded() / 10
        let printedAverage = (average * 10).rounded() / 10
        if recent >= average * 1.1, printedRecent > printedAverage { return .lh1(recent: printedRecent, average: printedAverage) }
        if recent <= average * 0.9, printedRecent < printedAverage { return .lh2(recent: printedRecent, average: printedAverage) }
        return nil
    }

    // MARK: Rules P

    private static func output(_ inputs: InsightInputs) -> OutputInsight {
        let value = Double(inputs.todayTokens.output)
        let range = inputs.phase.isReadingNewest ? nil : UsualRange.of(inputs.usualDays.map(\.output))
        let rule: OutputRule
        if let range {
            switch range.position(of: value) {
            case .above: rule = .p1
            case .inside: rule = .p2
            case .below: rule = .p3
            }
        } else if inputs.phase.isReading {
            rule = .readingLogs
        } else {
            let left = daysLeft(of: UsualRange.minimumDays, finished: inputs.usualDays.count, todayHasUse: inputs.todayTokens.total > 0)
            rule = left == 1 ? .p4s : .p4(daysLeft: left)
        }
        return OutputInsight(rule: rule, value: value, range: range)
    }

    private static func cache(_ inputs: InsightInputs) -> CacheRule? {
        let reads = inputs.todayTokens.cacheRead
        guard reads > 0 else { return nil }
        let saving = inputs.cacheSaving
        if saving.unpricedTokens >= reads { return .p7 }
        return saving.unpricedTokens > 0 || !saving.unpricedModels.isEmpty ? .p6(usd: saving.usd) : .p5(usd: saving.usd)
    }

    /// Rule P for `speed`: the card's model, or the one the Speed page shows.
    static func speed(_ speed: InsightInputs.Speed?, phase: IngestProgress.Phase, todayHasUse: Bool = false) -> SpeedInsight? {
        guard let speed else { return nil }
        let range = phase.isReadingNewest ? nil : UsualRange.of(speed.dailyMedians)
        let rule: SpeedRule
        if let range {
            switch range.position(of: speed.today) {
            case .above: rule = .p9
            case .inside: rule = .p8
            case .below: rule = .p10
            }
        } else if phase.isReading {
            rule = .readingLogs
        } else {
            let left = daysLeft(of: UsualRange.minimumDays, finished: speed.dailyMedians.count, todayHasUse: todayHasUse)
            rule = left == 1 ? .p4s : .p4(daysLeft: left)
        }
        return SpeedInsight(rule: rule, model: speed.model, value: speed.today, range: range)
    }

    private static func clis(_ inputs: InsightInputs) -> CLIShareInsight? {
        let totalCost = inputs.sources.reduce(0) { $0 + $1.cost }
        // With tokens left out of the cost, a share of it is a share of the part that has a price.
        let isFullyPriced = inputs.sources.allSatisfy { $0.unpricedTokens == 0 }
        let basis: CLIShareInsight.Basis = totalCost > 0 && isFullyPriced ? .cost : .tokens
        func amount(_ source: InsightInputs.SourceToday) -> Double {
            basis == .cost ? source.cost : Double(source.tokens)
        }
        let total = inputs.sources.reduce(0) { $0 + amount($1) }
        guard total > 0 else { return nil }
        let top = inputs.sources.reduce(inputs.sources[0]) { amount($1) > amount($0) ? $1 : $0 }
        return CLIShareInsight(source: top.source, percent: share(amount(top), of: total), basis: basis)
    }

    private static func cacheReadPercent(_ inputs: InsightInputs) -> Int? {
        let tokens = inputs.todayTokens
        guard tokens.total > 0 else { return nil }
        return share(Double(tokens.cacheRead), of: Double(tokens.total))
    }

    /// A rounded percent that makes no claim the figures do not: 100 only of all, and 0 only of none. `whole` is above 0.
    private static func share(_ part: Double, of whole: Double) -> Int {
        if part >= whole { return 100 }
        guard part > 0 else { return 0 }
        return min(max(Int((part / whole * 100).rounded()), 1), 99)
    }

    private static func when(_ inputs: InsightInputs) -> WhenRule? {
        // Sums of `Double`: a damaged figure must not trap on the way to a busiest day.
        let rows = inputs.hourOfWeek.prefix(7).map { $0.prefix(24).map(Double.init) }
        var hours = [Double](repeating: 0, count: 24)
        for row in rows {
            for (hour, tokens) in row.enumerated() { hours[hour] += tokens }
        }
        guard hours.contains(where: { $0 > 0 }) else { return nil }

        // The grid is every log there is, so it is not whole until they all are.
        guard !inputs.phase.isReading else { return .readingLogs }
        let days = inputs.usualDays.count
        guard days >= fortnight else {
            return .needsDays(daysLeft: daysLeft(of: fortnight, finished: days, todayHasUse: inputs.todayTokens.total > 0))
        }

        let totals = rows.map { $0.reduce(0, +) }
        let weekdayRow = totals.indices.reduce(0) { totals[$1] > totals[$0] ? $1 : $0 }
        func block(from hour: Int) -> Double {
            hours[hour] + hours[(hour + 1) % 24] + hours[(hour + 2) % 24]
        }
        let fromHour = hours.indices.reduce(0) { block(from: $1) > block(from: $0) ? $1 : $0 }
        return .p14(weekdayRow: weekdayRow, fromHour: fromHour, toHour: (fromHour + 3) % 24)
    }
}
