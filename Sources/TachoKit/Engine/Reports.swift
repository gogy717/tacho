import Foundation

/// What a page reads: `Engine.detail`, `speed`, `limitHistory` and `logSummary`. A value holding only what those need, so its work runs
/// off the engine's actor. Only an open page asks, never the 1 s tick. Sections 12 and 13.1 of `docs/design/direction-b-spec.md`.
struct Reports: Sendable {
    private static let keptWindows = 24

    let store: EventStore
    let prices: PriceTable
    let sources: Set<Source>
    let phase: IngestProgress.Phase

    private var enabled: EventFilter { EventFilter(sources: sources) }

    // MARK: Detail

    /// `curves` are the kept days, oldest first. With a `grouping` the columns and totals come from the rows that `series` does, so that they
    /// add up to each other however the store moves while a page reads.
    func detail(range: DetailRange, grouping: DetailGrouping? = nil, curves: [DayCurve], now: Date, calendar: Calendar) async throws -> DetailFigures {
        let shown = Columns(range, now: now, calendar: calendar)
        let thresholds = prices.longContextThresholds
        let sourced = try grouping.map { _ in try store.quarterHourGroupsBySource(in: shown.range, filter: enabled, thresholds: thresholds) }
        let groups = try sourced?.map(\.group) ?? store.quarterHourGroups(in: shown.range, filter: enabled, thresholds: thresholds)
        let pricing = groups.map(\.group)
        let columns = detailColumns(shown, groups: groups)
        let totals = try totals(of: groups, in: shown.range, calendar: calendar)

        var previousColumns: [DetailColumn] = []
        var previous: PeriodTotals?
        var previousIsFull = false
        if range == .week || range == .month {
            let before = shown.daysBefore(now: now, calendar: calendar)
            let groups = try store.quarterHourGroups(in: before.range, filter: enabled, thresholds: thresholds)
            let totals = try self.totals(of: groups, in: before.range, calendar: calendar)
            previousColumns = detailColumns(before, groups: groups)
            previous = totals
            previousIsFull = try isFull(before, totals: totals)
        }

        let bySource = try store.breakdown(in: shown.range, by: .source, thresholds: thresholds).filter { isEnabled($0.key) }
        let clients = try store.clientBreakdown(in: shown.range, thresholds: thresholds).filter { isEnabled($0.key) }
        var figures = DetailFigures(
            range: range,
            columns: columns,
            totals: totals,
            previousColumns: previousColumns,
            previous: previous,
            bySource: rows(bySource, name: Self.sourceName),
            byModel: rows(Dictionary(grouping: pricing) { $0.model ?? "" }),
            clientsBySource: Dictionary(uniqueKeysWithValues: clients.map { (Self.sourceName($0.key), rows($0.value)) }),
            cacheSaving: prices.cacheSaving(of: pricing),
            daysOfUse: curves.count,
            usualCost: Self.bands(\.cost, curves: curves, now: now, calendar: calendar),
            usualTokens: Self.bands(\.tokens, curves: curves, now: now, calendar: calendar),
            usualOutput: Self.bands(\.output, curves: curves, now: now, calendar: calendar),
            previousIsFull: previousIsFull,
            currentColumn: range == .year ? nil : shown.index(of: now)
        )
        figures.medianCost = Self.medianCost(of: figures)
        figures.highlights = Insights.highlights(of: figures, phase: phase)
        if let grouping, let sourced {
            figures.grouping = grouping
            figures.series = series(sourced, by: grouping, columns: shown)
        }
        return figures
    }

    /// In the order of their keys, so that a read says the same thing twice.
    private func series(_ groups: [(source: String, group: QuarterHourGroup)], by grouping: DetailGrouping, columns: Columns) -> [DetailSeries] {
        var cells: [String: [[PricingGroup]]] = [:]
        for (source, group) in groups {
            guard let index = columns.index(of: group.start) else { continue }
            let key = grouping == .model ? group.group.model ?? "" : Self.sourceName(source)
            cells[key, default: Array(repeating: [], count: columns.starts.count)][index].append(group.group)
        }
        return cells.sorted { $0.key < $1.key }.map { key, cells in
            DetailSeries(key: key, tokens: cells.map { $0.reduce(.zero) { $0 + $1.tokens } }, cost: cells.map(prices.cost(of:)))
        }
    }

    private func isEnabled(_ rawSource: String) -> Bool {
        Source(rawValue: rawSource).map(sources.contains) ?? false
    }

    private static func sourceName(_ raw: String) -> String {
        Source(rawValue: raw)?.displayName ?? raw
    }

    private func detailColumns(_ columns: Columns, groups: [QuarterHourGroup]) -> [DetailColumn] {
        var buckets = [[PricingGroup]](repeating: [], count: columns.starts.count)
        for group in groups {
            if let index = columns.index(of: group.start) { buckets[index].append(group.group) }
        }
        return zip(columns.starts, buckets).map { start, groups in
            DetailColumn(
                start: start,
                tokens: groups.reduce(.zero) { $0 + $1.tokens },
                cost: prices.cost(of: groups),
                costByCategory: prices.usdByCategory(of: groups),
                hasUse: !groups.isEmpty
            )
        }
    }

    private func totals(of groups: [QuarterHourGroup], in range: TimeRange, calendar: Calendar) throws -> PeriodTotals {
        let pricing = groups.map(\.group)
        let requests = try store.requestCounts(in: range, filter: enabled)
        return PeriodTotals(
            tokens: pricing.reduce(.zero) { $0 + $1.tokens },
            cost: prices.cost(of: pricing),
            costByCategory: prices.usdByCategory(of: pricing),
            requests: requests.all,
            subagentRequests: requests.subagent,
            daysWithUse: Set(groups.map { calendar.startOfDay(for: $0.start) }).count
        )
    }

    /// Some use in the period, and history reaching back to its first day: someone 10 days in has no week before this one to compare with.
    private func isFull(_ previous: Columns, totals: PeriodTotals) throws -> Bool {
        guard totals.daysWithUse > 0 else { return false }
        return try !store.logPage(filter: enabled, before: previous.starts[1], limit: 1).isEmpty
    }

    private func rows(_ breakdown: [String: [PricingGroup]], name: (String) -> String = { $0 }) -> [BreakdownRow] {
        breakdown
            .map { key, groups in
                BreakdownRow(key: name(key), tokens: groups.reduce(.zero) { $0 + $1.tokens }, cost: prices.cost(of: groups))
            }
            .sorted { ($1.tokens.total, $0.key) < ($0.tokens.total, $1.key) }
    }

    private static func bands(_ figure: KeyPath<DayCurve, [Double]>, curves: [DayCurve], now: Date, calendar: Calendar) -> UsualBands {
        let days = curves.map { $0[keyPath: figure] }
        let fraction = DayCurve.fraction(of: now, calendar: calendar)
        return UsualBands(
            hourly: (0..<24).compactMap { hour in UsualRange.of(days.map { added(in: hour, to: $0) }) },
            daily: UsualRange.of(days.map { $0.last ?? 0 }),
            now: UsualRange.of(days.map { DayCurve.value(of: $0, at: fraction) })
        )
    }

    /// What `hour` added to a cumulative day.
    private static func added(in hour: Int, to day: [Double]) -> Double {
        let quarters = DayCurve.quarterHours / 24
        let last = (hour + 1) * quarters - 1
        return day[last] - (hour > 0 ? day[last - quarters] : 0)
    }

    /// Of the days or months with use, while the cost of those it goes on counts as known. Week and Month leave out today: under way, it
    /// is not yet a day to take the middle of.
    private static func medianCost(of figures: DetailFigures) -> Double? {
        let periods: [DetailColumn]
        switch figures.range {
        case .day: return nil
        case .week, .month: periods = figures.finishedDays
        case .year: periods = figures.columns
        }
        guard Insights.isCostKnown(periods) else { return nil }
        return UsualRange.median(of: periods.filter(\.hasUse).map(\.cost.usd))
    }

    /// The output rules W compare, read as the Week page reads it, so that the panel's sentence speaks of the days Summary draws beside it.
    /// By the quarter hour and output alone, as the walk reads past days: a damaged row's other counts must not stop the panel.
    func weekOutput(now: Date, calendar: Calendar) throws -> (last: Int, before: Int) {
        let week = Columns(.week, now: now, calendar: calendar)
        func output(_ columns: Columns) throws -> Int {
            try store.quarterHourGroups(in: columns.range, filter: enabled, thresholds: prices.longContextThresholds).reduce(0) { $0 + $1.group.tokens.output }
        }
        return (try output(week), try output(week.daysBefore(now: now, calendar: calendar)))
    }

    // MARK: Speed

    /// `medians` are each model's on its speed days, oldest first: the kept history's, the walk being far too much for every load.
    func speed(range: DetailRange, model: String?, medians: [String: [Double]], now: Date, calendar: Calendar) async throws -> SpeedFigures {
        let shown = Columns(range, now: now, calendar: calendar)
        let samples = try store.speedSamples(in: shown.range, filter: enabled)
        let models = GenerationSpeed.medians(samples).map { speed in
            let days = medians[speed.model] ?? []
            return SpeedFigures.Model(speed: speed, usual: UsualRange.of(days), speedDays: min(days.count, UsualRange.keptDays))
        }
        let chosen = model ?? models.first?.speed.model

        var buckets = [[SpeedSample]](repeating: [], count: shown.starts.count)
        for sample in samples where sample.model == chosen {
            if let index = shown.index(of: sample.time) { buckets[index].append(sample) }
        }
        let columns = zip(shown.starts, buckets).map { start, samples in
            let speed = GenerationSpeed.medians(samples).first
            return SpeedFigures.Column(start: start, tokensPerSecond: speed?.tokensPerSecond, samples: speed?.samples ?? 0)
        }
        var figures = SpeedFigures(range: range, models: models, columns: columns)
        figures.todayHasUse = try store.tokens(in: Columns(.day, now: now, calendar: calendar).range, filter: enabled).total > 0
        return figures
    }

    // MARK: Limits

    func limitHistory(of snapshot: QuotaSnapshot, now: Date) async throws -> LimitHistory {
        var windows: [[(time: Date, percent: Double, resetsAt: Date)]] = []
        let readings = try store.limitReadings(of: snapshot, upTo: now, windows: Self.keptWindows)
        for reading in readings.sorted(by: { $0.resetsAt < $1.resetsAt }) {
            if let first = windows.last?.first, reading.resetsAt.timeIntervalSince(first.resetsAt) <= LimitHistory.sameWindow {
                windows[windows.count - 1].append(reading)
            } else {
                windows.append([reading])
            }
        }
        // The newest reading's reset, so the current window names the same reset as `snapshot`.
        let summaries = windows.compactMap { window -> LimitHistory.Window? in
            guard let newest = window.max(by: { $0.time < $1.time }), let peak = window.map(\.percent).max() else { return nil }
            return LimitHistory.Window(resetsAt: newest.resetsAt, peak: peak)
        }
        let current = windows.last { window in
            window.contains { abs($0.resetsAt.timeIntervalSince(snapshot.resetsAt)) <= LimitHistory.sameWindow }
        }
        return LimitHistory(
            readings: (current ?? []).sorted { $0.time < $1.time }.map { LimitHistory.Reading(time: $0.time, percent: $0.percent) },
            windows: Array(summaries.suffix(Self.keptWindows)),
            isFullyRead: !phase.isReading
        )
    }

    // MARK: Log

    /// Everything `filter` lets through, as the table below it shows: a source turned off is still in the log.
    func logSummary(filter: EventFilter) async throws -> LogSummary {
        let always = TimeRange(start: .distantPast, end: .distantFuture)
        let groups = try store.pricingGroups(in: always, filter: filter, thresholds: prices.longContextThresholds)
        let tokens = groups.reduce(TokenCounts.zero) { $0 + $1.tokens }
        let requests = try store.requestCounts(in: always, filter: filter)
        return LogSummary(
            requests: requests.all,
            cost: prices.cost(of: groups),
            output: tokens.output,
            cacheHitRate: tokens.cacheHitRate,
            subagentShare: requests.all > 0 ? Double(requests.subagent) / Double(requests.all) : nil
        )
    }
}

/// Where a range's columns start, and where the last one ends: section 12.1.
private struct Columns {
    var starts: [Date]
    var end: Date

    var range: TimeRange { TimeRange(start: starts[0], end: end) }

    init(starts: [Date], end: Date) {
        self.starts = starts
        self.end = end
    }

    init(_ range: DetailRange, now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        switch range {
        case .day:
            let hours = (0..<24).map { calendar.date(bySettingHour: $0, minute: 0, second: 0, of: today) ?? today }
            self.init(starts: hours, end: Self.day(-1, before: today, calendar: calendar))
        case .week:
            self = Self.days(7, endingWith: today, calendar: calendar)
        case .month:
            self = Self.days(30, endingWith: today, calendar: calendar)
        case .year:
            let month = calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: today, duration: 0)
            let months = (0..<12).reversed().map { calendar.date(byAdding: .month, value: -$0, to: month.start) ?? month.start }
            self.init(starts: months, end: month.end)
        }
    }

    /// As many days just before these, the last of them cut at the time of day it is at `now`, by the clock: a period with today under
    /// way is set against as much of the one before, so that a morning does not read as a fall.
    func daysBefore(now: Date, calendar: Calendar) -> Columns {
        let count = starts.count
        let cut = calendar.date(byAdding: .day, value: -count, to: now) ?? starts[0]
        return Columns(starts: (1...count).reversed().map { Self.day($0, before: starts[0], calendar: calendar) }, end: cut)
    }

    /// `count` local days, `last` the last of them, to its end.
    private static func days(_ count: Int, endingWith last: Date, calendar: Calendar) -> Columns {
        Columns(starts: (0..<count).reversed().map { day($0, before: last, calendar: calendar) }, end: day(-1, before: last, calendar: calendar))
    }

    /// The start of the local day `days` before `day`.
    private static func day(_ days: Int, before day: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: -days, to: day) ?? day)
    }

    /// The last column started by `date`. When a clock change gives two columns one start the first stays empty, as a skipped hour should,
    /// and a repeated hour falls short of the next start, so it adds to its own column.
    func index(of date: Date) -> Int? {
        starts.lastIndex { $0 <= date }
    }
}
