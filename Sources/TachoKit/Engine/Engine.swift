import Foundation
import GRDB
import os

/// Tacho's core: it keeps the store up with the logs and the quotas, and answers everything the interface asks.
public actor Engine {
    /// The window every rate is measured over. This is the one place to change it: the figures come out per minute at any length.
    private static let rateWindow: TimeInterval = 300
    private static let minutesInRateWindow = rateWindow / 60
    /// A source that wrote this recently counts as active.
    private static let activeWindow: TimeInterval = 300
    private static let hour: TimeInterval = 3_600
    private static let day: TimeInterval = 86_400
    private static let heatmapDays = 365
    /// How far back days of use are looked for, in calendar days: it bounds the query.
    private static let usualLookback = 90
    /// A model's day counts towards its usual speed from this many samples.
    private static let speedDaySamples = 5
    /// The days the When card's hour grid covers.
    private static let hourGridDays = 30
    /// The days of a trend, today being the last.
    private static let trendDays = 7
    /// Insights stand this long: they are for when the panel opens, and never for the 1 s tick.
    private static let insightsMaxAge: TimeInterval = 60
    /// How often `progress` is copied from the ingestor while it backfills.
    private static let progressInterval: Duration = .milliseconds(250)

    /// A pass over the quota windows costs far more than a tick can afford, and the dashboard asks every second. So weights are kept,
    /// and computed again this long after the last time if anything changed, or else after `weightsMaxAge`: `recent` slides with the clock.
    private static let weightsRefresh: TimeInterval = 15
    private static let weightsMaxAge: TimeInterval = 60

    /// The bundled prices with the user's overrides.
    public private(set) var prices: PriceTable

    let poller: QuotaPoller
    private let store: EventStore
    /// This launch found an index it could not read, moved it aside and began a new one.
    public nonisolated let indexWasSetAside: Bool
    private let ingestor: Ingestor
    private let bundledPrices: PriceTable
    private let makeFetcher: @Sendable () -> AnthropicUsageFetcher
    /// Made at most once and kept while the query is off: a new one would forget a Retry-After back-off.
    private(set) var fetcher: AnthropicUsageFetcher?
    /// Whether the user allows the Anthropic request. The fetcher itself asks this, before the token and again before the request,
    /// so a "no" holds from the moment `apply` starts, even for a fetch already under way past every check the poller makes.
    private let consent: OSAllocatedUnfairLock<Bool>
    /// The latest change of roots or sources, which the next one waits for so that they land in order.
    private var settling: Task<Void, Never>?
    private var preferences: Preferences
    private var started = false
    /// A copy of the ingestor's, because `dashboard` cannot wait for another actor.
    private var progress = IngestProgress(phase: .idle, filesDone: 0, filesTotal: 0)
    private var cachedWeights: [Limit: CachedWeights] = [:]
    private var keptFigures: KeptFigures?
    private var keptRate: Sliding<RateAnswer>?
    private var keptHour: Sliding<[String: [PricingGroup]]>?
    private var keptSeries: Sliding<SeriesAnswer>?
    private var keptHistory: History?
    /// How many times past days have been read.
    private(set) var pastDayWalks = 0
    /// How many passes over a quota window's rows have been made.
    private(set) var weightPasses = 0
    private var keptInsights: KeptInsights?

    /// One quota: what `latestSnapshots` returns one snapshot for.
    private struct Limit: Hashable {
        var provider: QuotaProvider
        var window: QuotaWindow
        var scope: String?

        init(_ snapshot: QuotaSnapshot) {
            provider = snapshot.provider
            window = snapshot.window
            scope = snapshot.scope
        }
    }

    /// Weights with the snapshot they were computed for. They stay together: weights are only right for their own snapshot.
    private struct CachedWeights {
        var snapshot: QuotaSnapshot
        var weights: WindowWeights
        var computedAt: Date
        /// The store's generation when they were computed.
        var generation: Int

        func isDue(latest: QuotaSnapshot, generation: Int, now: Date) -> Bool {
            let age = now.timeIntervalSince(computedAt)
            if age >= Engine.weightsMaxAge || age < 0 { return true }
            // Across a reset the window they describe is over, whatever else has or has not changed.
            if ProjectionEngine.nextReset(of: snapshot, after: computedAt) <= now { return true }
            return age >= Engine.weightsRefresh && (latest != snapshot || generation != self.generation)
        }
    }

    /// The answer to a query over a window that slides with the clock. It stands until rows change, or until the moment the clock
    /// alone would change it: the next event to leave the window, or the next to enter it.
    private struct Sliding<Value> {
        var value: Value
        var generation: Int
        var computedAt: Date
        var expires: Date?

        func holds(generation: Int, now: Date) -> Bool {
            generation == self.generation && now >= computedAt && now < expires ?? .distantFuture
        }
    }

    /// What today is compared with. Read once a local day, when preferences change, when the logs finish, and when past days turn
    /// out to have changed: a walk back over 90 days is far too much for any more often than that.
    private struct History {
        var day: Date
        var calendar: Calendar
        var isLive: Bool
        /// The store's generation when past days were last found as read here.
        var generation: Int
        /// What past days added up to when read. nil when that could not be told.
        var fingerprint: RowsFingerprint?
        /// The newest days with use, oldest first.
        var curves: [DayCurve]
        /// Every day with use in the walk.
        var tokens: [Date: TokenCounts]
        /// Each model's median on its days with enough samples, oldest first.
        var speedMedians: [String: [Double]]
        var hourOfWeek: [[Int]]

        func holds(day: Date, calendar: Calendar, isLive: Bool) -> Bool {
            day == self.day && calendar == self.calendar && isLive == self.isLive
        }
    }

    private struct KeptInsights {
        var value: PanelInsights
        var computedAt: Date
        var day: Date
        var calendar: Calendar
        var phase: IngestProgress.Phase

        func holds(day: Date, calendar: Calendar, phase: IngestProgress.Phase, now: Date) -> Bool {
            let age = now.timeIntervalSince(computedAt)
            return age >= 0 && age < Engine.insightsMaxAge && day == self.day && calendar == self.calendar && phase == self.phase
        }
    }

    /// Everything a read of the insights goes on.
    private struct Reading {
        var history: History
        var today: DayCurve
        var todayGroups: [PricingGroup]
        var dashboard: Dashboard
        var inputs: InsightInputs
    }

    /// The last 60 minutes, in tokens and in dollars. One query gives both, and they expire together.
    private struct SeriesAnswer {
        var tokens: [TokenCounts]
        var cost: [CategoryCost]
    }

    /// What the rate window holds. Kept as one because the two expire together.
    private struct RateAnswer {
        var tokens: [SourceClientTokens]
        var groups: [String: [PricingGroup]]
    }

    /// What a dashboard needs that only rows can change, and the calendar. Reading it is most of a tick's cost, and on most ticks no
    /// row has changed.
    private struct KeptFigures {
        var generation: Int
        var day: Date
        var computedAt: Date
        /// The first event stamped after `computedAt`: a clock ahead of ours wrote it, and it counts once ours gets there.
        var nextEvent: Date?
        var snapshots: [QuotaSnapshot]
        var todayTokens: [SourceClientTokens]
        var todayGroups: [String: [PricingGroup]]
        var lastActivity: [Source: Date]
        /// On this machine, and with no `end`: unlike `lastActivity`, this can be ahead of the clock.
        var newestEvent: Date?
        var sourcesWithQuota: Set<Source>
        /// Oldest first, so that those leaving the last 24 hours are at the front.
        var samples: [SpeedSample]
        var speeds: [ModelSpeed]

        func isCurrent(generation: Int, day: Date, now: Date) -> Bool {
            generation == self.generation && day == self.day && now >= computedAt && now < nextEvent ?? .distantFuture
        }

        /// The 24 hours slide even when nothing is written: a median moves when one of its samples leaves. What leaves is gone from
        /// here, so these figures now hold only from `now` on: a clock set back behind it has to read them again.
        mutating func dropSamples(before start: Date, now: Date) {
            guard let oldest = samples.first, oldest.time < start else { return }
            samples.removeAll { $0.time < start }
            speeds = GenerationSpeed.medians(samples)
            computedAt = now
        }
    }

    public init(databaseURL: URL, home: URL, preferences: Preferences, readers: [any SourceReader] = Ingestor.defaultReaders()) throws {
        let opened = try Self.openReplacingUnusableIndex(at: databaseURL)
        try self.init(
            store: opened.store,
            home: home,
            preferences: preferences,
            readers: readers,
            token: AnthropicUsageFetcher.keychainToken,
            send: AnthropicUsageFetcher.send,
            indexWasSetAside: opened.wasSetAside
        )
    }

    /// The index at `url`, or a fresh one when that file is not a database this version can read. The old file is moved aside, once.
    /// A file that cannot be opened or moved, a lock, or a full disk is left where it is: those are not a damaged index.
    private static func openReplacingUnusableIndex(at url: URL) throws -> (store: EventStore, wasSetAside: Bool) {
        do {
            return (try readableIndex(at: url), false)
        } catch let failure {
            guard isUnusableIndex(failure) else { throw failure }
            do {
                try setAsideUnusableIndex(at: url)
            } catch {
                throw failure
            }
            return (try readableIndex(at: url), true)
        }
    }

    /// Opens `url` and checks the columns the readers write. The check lives only here: a later query must not be able to discard the index.
    private static func readableIndex(at url: URL) throws -> EventStore {
        let store = try EventStore(url: url)
        try store.reader.read { db in
            _ = try Row.fetchAll(db, sql: "SELECT dedupKey, isSubagent, cacheWrite1h, machine FROM event LIMIT 0")
            _ = try Row.fetchAll(db, sql: "SELECT json FROM cursor LIMIT 0")
            _ = try Row.fetchAll(db, sql: #"SELECT usedPercent, "window" FROM quotaSnapshot LIMIT 0"#)
        }
        return store
    }

    /// Whether `error` means the file is not an index this version can read. Permissions, locks and I/O faults are not that.
    private static func isUnusableIndex(_ error: Error) -> Bool {
        if error is MissingMachineId { return true }
        guard let error = error as? DatabaseError else { return false }
        switch error.resultCode {
        case .SQLITE_NOTADB, .SQLITE_CORRUPT, .SQLITE_MISMATCH:
            return true
        case .SQLITE_ERROR:
            let message = (error.message ?? "").lowercased()
            return message.contains("no such column") || message.contains("no such table") || message.contains("already exists")
        default:
            return false
        }
    }

    /// Moves `url` and its WAL sidecars to one sibling name. A move that does not finish is put back, so a failed recovery leaves the file.
    private static func setAsideUnusableIndex(at url: URL) throws {
        let held = url.deletingLastPathComponent().appendingPathComponent("tacho.sqlite.unusable-\(UUID().uuidString)")
        var moved: [(URL, URL)] = []
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.moveItem(at: url, to: held)
                moved.append((held, url))
            }
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: url.path + suffix)
                guard FileManager.default.fileExists(atPath: side.path) else { continue }
                let destination = URL(fileURLWithPath: held.path + suffix)
                try FileManager.default.moveItem(at: side, to: destination)
                moved.append((destination, side))
            }
        } catch {
            for (from, back) in moved.reversed() {
                try? FileManager.default.moveItem(at: from, to: back)
            }
            throw error
        }
    }

    init(
        store: EventStore,
        home: URL,
        preferences: Preferences,
        readers: [any SourceReader],
        token: @escaping @Sendable () throws -> ClaudeToken?,
        send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
        indexWasSetAside: Bool = false
    ) throws {
        self.indexWasSetAside = indexWasSetAside
        let consent = OSAllocatedUnfairLock(initialState: preferences.anthropicQueryEnabled)
        let makeFetcher = { @Sendable in
            AnthropicUsageFetcher(
                token: { consent.withLock { $0 } ? try token() : nil },
                send: { request in
                    guard consent.withLock({ $0 }) else { throw CancellationError() }
                    return try await send(request)
                }
            )
        }
        self.consent = consent
        bundledPrices = try PriceTable.bundled()
        prices = bundledPrices.applying(overrides: preferences.priceOverrides)
        fetcher = preferences.anthropicQueryEnabled ? makeFetcher() : nil
        self.store = store
        self.preferences = preferences
        self.makeFetcher = makeFetcher
        ingestor = Ingestor(store: store, readers: readers, roots: preferences.roots, enabled: preferences.enabledSources)
        poller = QuotaPoller(store: store, home: home, fetcher: fetcher, enabled: preferences.enabledSources)
    }

    /// Backfills in a child task, starts watching, and starts the `QuotaPoller`.
    public func start() async {
        guard !started else { return }
        started = true
        Task { await backfill() }
        await ingestor.startWatching()
        await poller.start()
    }

    public func dashboard(now: Date, calendar: Calendar = .current) throws -> Dashboard {
        let thresholds = prices.longContextThresholds
        let rateRange = Self.range(endingAt: now, seconds: Self.rateWindow)
        let lastHour = Self.range(endingAt: now, seconds: Self.hour)
        let kept = try figures(now: now, day: calendar.startOfDay(for: now), end: rateRange.end)

        // This machine only. The same two queries as before, with one equality: nothing else is added to the tick.
        // Totals, cost, heatmaps and groupings keep reading every machine.
        let local = EventFilter(machine: store.machineId)
        let rate = try sliding(&keptRate, over: rateRange, length: Self.rateWindow, kept: kept, now: now) {
            RateAnswer(
                tokens: try store.tokensBySourceAndClient(in: rateRange, filter: local),
                groups: try store.breakdown(in: rateRange, by: .source, thresholds: thresholds, filter: local)
            )
        }
        let rateTokens = rate.tokens.filter { isEnabled($0.source) }
        let hourGroups = try sliding(&keptHour, over: lastHour, length: Self.hour, kept: kept, now: now) {
            try store.breakdown(in: lastHour, by: .source, thresholds: thresholds)
        }

        let enabled = Source.allCases.filter(isEnabled)
        let sources = enabled.compactMap { source -> SourceRow? in
            guard let lastActivity = kept.lastActivity[source] else { return nil }
            let rateRows = rateTokens.filter { $0.source == source }
            let todayRows = kept.todayTokens.filter { $0.source == source }
            return SourceRow(
                source: source,
                clients: clients(rate: rateRows, today: todayRows),
                perMinute: perMinute(rateRows.reduce(0) { $0 + $1.tokens.total }),
                today: todayRows.reduce(.zero) { $0 + $1.tokens },
                todayCost: prices.cost(of: kept.todayGroups[source.rawValue] ?? []),
                lastActivity: lastActivity,
                isActive: now.timeIntervalSince(lastActivity) <= Self.activeWindow,
                costLastHour: prices.cost(of: hourGroups[source.rawValue] ?? []),
                hasQuota: kept.sourcesWithQuota.contains(source)
            )
        }

        let windowTokens = rateTokens.reduce(.zero) { $0 + $1.tokens }
        let lastMinute = perMinute(windowTokens)
        let quotas = try projections(of: kept.snapshots, generation: kept.generation, now: now)
        let series = try series(kept: kept, now: now)
        return Dashboard(
            perMinute: perMinute(windowTokens.total),
            perSecond: Double(windowTokens.total) / Self.rateWindow,
            isIdle: rateTokens.isEmpty,
            lastMinute: lastMinute,
            series: series.tokens,
            sources: sources.sorted(by: Self.displayOrder),
            quotas: quotas,
            today: TodaySummary(
                tokens: kept.todayTokens.reduce(.zero) { $0 + $1.tokens },
                cost: prices.cost(of: enabled.flatMap { kept.todayGroups[$0.rawValue] ?? [] }),
                speeds: kept.speeds
            ),
            alert: ProjectionEngine.alert(quotas),
            progress: progress,
            outputPerMinute: lastMinute.output,
            costPerMinute: perMinute(prices.cost(of: enabled.flatMap { rate.groups[$0.rawValue] ?? [] })),
            costSeries: series.cost,
            latestRequest: kept.lastActivity.values.max(),
            newestEvent: kept.newestEvent
        )
    }

    /// `amount`, counted over the rate window, per minute.
    private func perMinute(_ amount: Int) -> Int {
        Int((Double(amount) / Self.minutesInRateWindow).rounded())
    }

    private func perMinute(_ tokens: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: perMinute(tokens.input),
            output: perMinute(tokens.output),
            reasoning: perMinute(tokens.reasoning),
            cacheRead: perMinute(tokens.cacheRead),
            cacheWrite5m: perMinute(tokens.cacheWrite5m),
            cacheWrite1h: perMinute(tokens.cacheWrite1h)
        )
    }

    /// Tokens left out never round down to none: "no price" and the note on what is not counted both rest on there being some.
    private func perMinute(_ cost: CostSummary) -> CostSummary {
        CostSummary(
            usd: cost.usd / Self.minutesInRateWindow,
            unpricedModels: cost.unpricedModels,
            unpricedTokens: cost.unpricedTokens > 0 ? max(1, perMinute(cost.unpricedTokens)) : 0
        )
    }

    /// What the panel shows beyond the tick. Call it when the panel opens and at most once a minute, never on the 1 s tick: a call
    /// sooner gets the last answer.
    public func insights(now: Date, calendar: Calendar = .current) async throws -> PanelInsights {
        let today = calendar.startOfDay(for: now)
        if let keptInsights, keptInsights.holds(day: today, calendar: calendar, phase: progress.phase, now: now) {
            return keptInsights.value
        }
        let reading = try reading(now: now, calendar: calendar)
        let results = Insights.compute(reading.inputs)
        let fraction = DayCurve.fraction(of: now, calendar: calendar)
        let history = reading.history
        let value = PanelInsights(
            results: results,
            daysOfUse: history.curves.count,
            cost: Self.usualCurve(\.cost, days: history.curves, today: reading.today, fraction: fraction),
            output: Self.usualCurve(\.output, days: history.curves, today: reading.today, fraction: fraction),
            tokens: Self.usualCurve(\.tokens, days: history.curves, today: reading.today, fraction: fraction),
            cache: cacheFigures(reading),
            clis: Self.cliFigures(reading, top: results.clis),
            hourOfWeek: history.hourOfWeek
        )
        keptInsights = KeptInsights(value: value, computedAt: now, day: today, calendar: calendar, phase: progress.phase)
        return value
    }

    /// The days a usual range goes on, oldest first: the newest `UsualRange.keptDays` local days with use before today.
    func dayCurves(now: Date, calendar: Calendar = .current) throws -> [DayCurve] {
        try history(now: now, calendar: calendar).curves
    }

    func insightInputs(now: Date, calendar: Calendar = .current) throws -> InsightInputs {
        try reading(now: now, calendar: calendar).inputs
    }

    private func reading(now: Date, calendar: Calendar) throws -> Reading {
        let history = try history(now: now, calendar: calendar)
        let dashboard = try dashboard(now: now, calendar: calendar)
        let day = calendar.startOfDay(for: now)
        let enabled = EventFilter(sources: preferences.enabledSources)
        let quarters = try store.quarterHourGroups(
            in: TimeRange(start: day, end: Self.range(endingAt: now, seconds: 0).end),
            filter: enabled,
            thresholds: prices.longContextThresholds
        )
        let empty = [[PricingGroup]](repeating: [], count: DayCurve.quarterHours)
        let today = DayCurve(day: day, quarterHours: LocalBuckets.quarterHours(quarters, calendar: calendar)[day] ?? empty, prices: prices)
        let todayGroups = quarters.map(\.group)
        let fraction = DayCurve.fraction(of: now, calendar: calendar)
        let weeks = try reports.weekOutput(now: now, calendar: calendar)
        let inputs = InsightInputs(
            phase: progress.phase,
            todayTokens: dashboard.today.tokens,
            todayCost: dashboard.today.cost,
            usualDays: history.curves.map {
                InsightInputs.UsualDay(cost: DayCurve.value(of: $0.cost, at: fraction), output: DayCurve.value(of: $0.output, at: fraction))
            },
            outputLastSevenDays: weeks.last,
            outputSevenDaysBefore: weeks.before,
            limits: dashboard.quotas,
            anthropicQueryEnabled: preferences.anthropicQueryEnabled,
            watchesClaude: preferences.enabledSources.contains(.claudeCode),
            cacheSaving: prices.cacheSaving(of: todayGroups),
            speed: try speed(now: now, history: history),
            sources: dashboard.sources.filter { $0.today.total > 0 }.map {
                InsightInputs.SourceToday(source: $0.source, cost: $0.todayCost.usd, tokens: $0.today.total, unpricedTokens: $0.todayCost.unpricedTokens)
            },
            hourOfWeek: history.hourOfWeek
        )
        return Reading(history: history, today: today, todayGroups: todayGroups, dashboard: dashboard, inputs: inputs)
    }

    private func history(now: Date, calendar: Calendar) throws -> History {
        let today = calendar.startOfDay(for: now)
        let isLive = progress.phase == .live
        let walk = TimeRange(start: Self.day(Self.usualLookback, before: today, calendar: calendar), end: today)
        // Before any query, as in `figures`: a write that lands during them is then seen as new on the next read.
        let generation = store.generation
        var fingerprint: RowsFingerprint?
        if var kept = keptHistory, kept.holds(day: today, calendar: calendar, isLive: isLive) {
            // A rescan can bring a root's old logs at any time, with no change of preferences. Nearly every write is today's, though,
            // so past days are read again only if they changed. While the logs are read they change all the time, and nothing yet
            // says that days are missing: the end of that reads them anyway.
            //
            // This does not wait for a rescan to end, which nothing here can see: each read compares, so a long rescan can cost several
            // walks. That is the ruling: right figures matter more, the walks are off the tick, and they happen only while past days
            // are changing.
            guard isLive, generation != kept.generation else { return kept }
            // It only says whether to read, so it must never be what stops one. Losing it means rows changed, and is read as that,
            // once: after that nil is what was read, so a damaged row does not cost a walk at every read.
            let current = try? store.fingerprint(of: walk)
            guard current != kept.fingerprint else {
                kept.generation = generation
                keptHistory = kept
                return kept
            }
            fingerprint = current
        }

        pastDayWalks += 1
        let read = fingerprint ?? (try? store.fingerprint(of: walk))
        let thresholds = prices.longContextThresholds
        let enabled = EventFilter(sources: preferences.enabledSources)
        let groups = try store.quarterHourGroups(in: walk, filter: enabled, thresholds: thresholds)
        let quarters = LocalBuckets.quarterHours(groups, calendar: calendar)
        let curves = quarters.keys.sorted().suffix(UsualRange.keptDays).compactMap { day in
            quarters[day].map { DayCurve(day: day, quarterHours: $0, prices: prices) }
        }

        var speedMedians: [String: [Double]] = [:]
        let samples = Dictionary(grouping: try store.speedSamples(in: walk, filter: enabled)) { calendar.startOfDay(for: $0.time) }
        for day in samples.keys.sorted() {
            for speed in GenerationSpeed.medians(samples[day] ?? []) where speed.samples >= Self.speedDaySamples {
                speedMedians[speed.model, default: []].append(speed.tokensPerSecond)
            }
        }

        // Every source: the When card leads to the Calendar, and like it keeps the whole picture.
        let grid = TimeRange(start: Self.day(Self.hourGridDays, before: today, calendar: calendar), end: today)
        let history = History(
            day: today,
            calendar: calendar,
            isLive: isLive,
            generation: generation,
            fingerprint: read,
            curves: curves,
            tokens: LocalBuckets.days(groups, calendar: calendar).mapValues { $0.reduce(.zero) { $0 + $1.tokens } },
            speedMedians: speedMedians,
            hourOfWeek: LocalBuckets.hourOfWeek(try store.quarterHourGroups(in: grid, thresholds: thresholds), calendar: calendar)
        )
        keptHistory = history
        return history
    }

    /// `model` in the last 24 hours, or with nil the model with the most samples there, enabled sources only. Reads a day of samples, so
    /// never on the tick.
    private func speed(now: Date, history: History, model: String? = nil) throws -> InsightInputs.Speed? {
        let lastDay = Self.range(endingAt: now, seconds: Self.day)
        let samples = try store.speedSamples(in: lastDay, filter: EventFilter(sources: preferences.enabledSources))
        let speeds = GenerationSpeed.medians(samples)
        let speed = if let model { speeds.first { $0.model == model } } else { speeds.first }
        return speed.map {
            InsightInputs.Speed(model: $0.model, today: $0.tokensPerSecond, dailyMedians: history.speedMedians[$0.model] ?? [])
        }
    }

    private func cacheFigures(_ reading: Reading) -> CacheFigures {
        let today = reading.dashboard.today.tokens
        let days = reading.history.tokens.keys.sorted().compactMap { reading.history.tokens[$0] } + [today]
        return CacheFigures(
            hitRate: today.cacheHitRate,
            dailyHitRates: days.compactMap(\.cacheHitRate).suffix(Self.trendDays),
            saving: reading.inputs.cacheSaving
        )
    }

    /// Shares go by the same basis as the sentence beside them, or the bar and the words would disagree.
    private static func cliFigures(_ reading: Reading, top: CLIShareInsight?) -> CLIFigures {
        let sources = reading.inputs.sources
        let basis = top?.basis ?? .tokens
        func amount(_ source: InsightInputs.SourceToday) -> Double {
            basis == .cost ? source.cost : Double(source.tokens)
        }
        func share(of source: Source, in sources: [InsightInputs.SourceToday]) -> Double {
            let total = sources.reduce(0) { $0 + amount($1) }
            guard total > 0, let row = sources.first(where: { $0.source == source }) else { return 0 }
            return amount(row) / total
        }
        let shares = sources
            .map { CLIFigures.Share(source: $0.source, fraction: share(of: $0.source, in: sources)) }
            .sorted { ($1.fraction, $0.source.rawValue) < ($0.fraction, $1.source.rawValue) }
        return CLIFigures(shares: shares)
    }

    private static func usualCurve(_ figure: KeyPath<DayCurve, [Double]>, days: [DayCurve], today: DayCurve, fraction: Double) -> UsualCurve {
        let band = (0..<DayCurve.quarterHours).compactMap { slot in
            UsualRange.of(days.map { $0[keyPath: figure][slot] }).map {
                UsualCurve.Band(fraction: Double(slot + 1) / Double(DayCurve.quarterHours), low: $0.p25, median: $0.median, high: $0.p75)
            }
        }
        // Its last step, not the one at the clock: in the second pass of a repeated hour the clock is behind what has already happened.
        let values = today[keyPath: figure]
        let slots = Double(DayCurve.quarterHours)
        let current = min(Int(fraction * slots), DayCurve.quarterHours - 1)
        let line = [UsualCurve.Point(fraction: 0, value: 0)]
            + (0..<current).map { UsualCurve.Point(fraction: Double($0 + 1) / slots, value: values[$0]) }
            + [UsualCurve.Point(fraction: fraction, value: values.last ?? 0)]
        return UsualCurve(
            band: band,
            today: line,
            usualNow: UsualRange.of(days.map { DayCurve.value(of: $0[keyPath: figure], at: fraction) })?.median
        )
    }

    /// The start of the local day `days` before `today`.
    private static func day(_ days: Int, before today: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: -days, to: today) ?? today)
    }

    /// What the Cost, Tokens and Cache pages read.
    public func detail(range: DetailRange, grouping: DetailGrouping? = nil, now: Date, calendar: Calendar = .current) async throws -> DetailFigures {
        try await reports.detail(range: range, grouping: grouping, curves: dayCurves(now: now, calendar: calendar), now: now, calendar: calendar)
    }

    /// What the Speed page reads, its columns being `model`'s, or with nil the model with the most samples.
    public func speed(range: DetailRange, model: String?, now: Date, calendar: Calendar = .current) async throws -> SpeedFigures {
        try await reports.speed(range: range, model: model, medians: history(now: now, calendar: calendar).speedMedians, now: now, calendar: calendar)
    }

    /// Rule P for the model the Speed page shows, as the Speed card has it for its own, which nil asks for: that model's last 24 hours
    /// against its usual range. nil when it has no request there that counts. The page asks as it refreshes, never the tick.
    public func speedInsight(model: String?, now: Date, calendar: Calendar = .current) async throws -> SpeedInsight? {
        Insights.speed(
            try speed(now: now, history: history(now: now, calendar: calendar), model: model),
            phase: progress.phase,
            todayHasUse: try dashboard(now: now, calendar: calendar).today.tokens.total > 0
        )
    }

    /// The record of the limit `snapshot` belongs to: its provider, window and scope.
    public func limitHistory(of snapshot: QuotaSnapshot, now: Date) async throws -> LimitHistory {
        try await reports.limitHistory(of: snapshot, now: now)
    }

    /// The Activity log's summary strip.
    public func logSummary(filter: EventFilter) async throws -> LogSummary {
        try await reports.logSummary(filter: filter)
    }

    /// The pages' reads, whose queries leave this actor. What they take from the kept history is read here, as the panel's is.
    private var reports: Reports {
        Reports(store: store, prices: prices, sources: preferences.enabledSources, phase: progress.phase)
    }

    public func overview(range: TimeRange, calendar: Calendar = .current) throws -> Overview {
        let thresholds = prices.longContextThresholds
        let sourceName = { (raw: String) in Source(rawValue: raw)?.displayName ?? raw }
        return Overview(
            tokens: try store.tokens(in: range),
            cost: prices.cost(of: try store.pricingGroups(in: range, thresholds: thresholds)),
            bySource: rows(try store.breakdown(in: range, by: .source, thresholds: thresholds), name: sourceName),
            byModel: rows(try store.breakdown(in: range, by: .model, thresholds: thresholds)),
            byProject: rows(try store.breakdown(in: range, by: .project, thresholds: thresholds)),
            speeds: GenerationSpeed.medians(try store.speedSamples(in: range)),
            clientsBySource: Dictionary(
                uniqueKeysWithValues: try store.clientBreakdown(in: range, thresholds: thresholds).map { (sourceName($0.key), rows($0.value)) }
            )
        )
    }

    public func log(filter: EventFilter, before: Date?, limit: Int) throws -> [LogRow] {
        try store.logPage(filter: filter, before: before, limit: limit).map { event in
            let speed = GenerationSpeed.rate(
                SpeedSample(
                    model: event.model ?? "",
                    output: event.tokens.output,
                    generationMs: event.generationMs,
                    startTime: event.startTime,
                    time: event.time
                )
            )
            return LogRow(
                event: event,
                costUSD: usd(of: event),
                tokensPerSecond: speed?.tokensPerSecond,
                approximateSpeed: speed?.approximate ?? false
            )
        }
    }

    /// `days` is always the last year; `range` is for the hour-of-week grid alone.
    public func heatmaps(now: Date, range: TimeRange, calendar: Calendar = .current) throws -> Heatmaps {
        let thresholds = prices.longContextThresholds
        let today = calendar.startOfDay(for: now)
        let days = (1 - Self.heatmapDays...0).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: today).map { calendar.startOfDay(for: $0) }
        }
        let year = TimeRange(start: days.first ?? today, end: Self.range(endingAt: now, seconds: 0).end)
        let groups = LocalBuckets.days(try store.quarterHourGroups(in: year, thresholds: thresholds), calendar: calendar)
        return Heatmaps(
            days: days.map { day in
                let groups = groups[day] ?? []
                return DayCell(day: day, tokens: groups.reduce(0) { $0 + $1.tokens.total }, costUSD: prices.cost(of: groups).usd)
            },
            hourOfWeek: LocalBuckets.hourOfWeek(try store.quarterHourGroups(in: range, thresholds: thresholds), calendar: calendar)
        )
    }

    public func statuses() async -> [SourceStatus] {
        await ingestor.statuses()
    }

    /// Applies roots, enabled sources, price overrides, and turns the Anthropic fetcher on or off.
    ///
    /// Returns without waiting for the rescan a change of roots brings. The app saves settings in order, so otherwise the next `apply`
    /// would queue behind it, and the next one could be the user withdrawing consent: that has to hold at once.
    public func apply(_ preferences: Preferences) async {
        consent.withLock { $0 = preferences.anthropicQueryEnabled }
        self.preferences = preferences
        prices = bundledPrices.applying(overrides: preferences.priceOverrides)
        cachedWeights.removeAll()
        keptFigures = nil
        keptRate = nil
        keptHour = nil
        keptSeries = nil
        forgetPastDays()
        if preferences.anthropicQueryEnabled, fetcher == nil {
            fetcher = makeFetcher()
        }
        await poller.setFetcher(preferences.anthropicQueryEnabled ? fetcher : nil)
        await poller.setEnabled(preferences.enabledSources)
        let previous = settling
        settling = Task { [ingestor, weak self] in
            await previous?.value
            await ingestor.update(roots: preferences.roots, enabled: preferences.enabledSources)
            // That rescan brings a source's old logs in with the phase at `.live` throughout. Read during it, past days would say a
            // source has no history until midnight, with all of it in the store.
            await self?.forgetPastDays()
        }
    }

    public func rebuildIndex() async throws {
        let tracking = trackProgress()
        defer { tracking.cancel() }
        try await ingestor.rebuildIndex()
        tracking.cancel()
        await finishReading()
    }

    // MARK: Progress

    private func backfill() async {
        let tracking = trackProgress()
        await ingestor.backfill()
        tracking.cancel()
        await finishReading()
    }

    /// Keeps `progress` current until cancelled. Only ever runs during a backfill: an idle engine has nothing to wake up for.
    private func trackProgress() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                let latest = await ingestor.progress
                // Cancelled during that wait, this copy is older than the last one. Back on the actor, nothing can come between
                // this check and the write.
                guard !Task.isCancelled else { return }
                progress = latest
                try? await Task.sleep(for: Self.progressInterval)
            }
        }
    }

    /// The last word after a read of everything. Whoever is calling may have been cancelled by now; this has to happen regardless.
    private func finishReading() async {
        progress = await ingestor.progress
        // Reading the history adds old events, which the check for new data cannot see. A rebuild can take rows away as well, and it
        // runs with the panel shut: nothing need read past days while the phase is away from `.live`, so only this can say so.
        cachedWeights.removeAll()
        forgetPastDays()
    }

    private func forgetPastDays() {
        keptHistory = nil
        keptInsights = nil
    }

    // MARK: Dashboard parts

    private func isEnabled(_ source: Source) -> Bool {
        preferences.enabledSources.contains(source)
    }

    /// The kept figures, read again if a row changed, the day turned or an event's time came. `end` is just past `now`.
    private func figures(now: Date, day: Date, end: Date) throws -> KeptFigures {
        // Before any query: a write that lands during them is then seen as new on the next tick, at the cost of reading again.
        let generation = store.generation
        let speedWindow = Self.range(endingAt: now, seconds: Self.day)
        if var kept = keptFigures, kept.isCurrent(generation: generation, day: day, now: now) {
            kept.dropSamples(before: speedWindow.start, now: now)
            keptFigures = kept
            return kept
        }

        let today = TimeRange(start: day, end: end)
        let snapshots = try store.latestSnapshots()
        let quotaProviders = Set(snapshots.map(\.provider))
        let todayTokens = try store.tokensBySourceAndClient(in: today).filter { isEnabled($0.source) }
        var lastActivity: [Source: Date] = [:]
        var sourcesWithQuota: Set<Source> = []
        for source in Source.allCases.filter(isEnabled) {
            // `end` is just past `now`, so an event still to come is not the last activity.
            lastActivity[source] = try store.logPage(filter: EventFilter(sources: [source]), before: end, limit: 1).first?.time
            let isUsedToday = todayTokens.contains { $0.source == source }
            let hasQuota = try isUsedToday && quotaProviders.contains { provider in
                try store.tokens(in: today, filter: EventFilter(sources: [source], quotaProvider: provider)).total > 0
            }
            if hasQuota { sourcesWithQuota.insert(source) }
        }
        let samples = try store.speedSamples(in: speedWindow, filter: EventFilter(sources: preferences.enabledSources)).sorted { $0.time < $1.time }
        let kept = KeptFigures(
            generation: generation,
            day: day,
            computedAt: now,
            nextEvent: try store.firstEventTime(from: end),
            snapshots: snapshots,
            todayTokens: todayTokens,
            todayGroups: try store.breakdown(in: today, by: .source, thresholds: prices.longContextThresholds),
            lastActivity: lastActivity,
            newestEvent: try store.logPage(filter: EventFilter(sources: preferences.enabledSources, machine: store.machineId), before: nil, limit: 1).first?.time,
            sourcesWithQuota: sourcesWithQuota,
            samples: samples,
            speeds: GenerationSpeed.medians(samples)
        )
        keptFigures = kept
        return kept
    }

    /// The answer in `answer`, or `read`'s if it no longer stands. `kept` says when rows last changed and the next event to enter.
    private func sliding<Value>(
        _ answer: inout Sliding<Value>?,
        over window: TimeRange,
        length: TimeInterval,
        kept: KeptFigures,
        now: Date,
        read: () throws -> Value
    ) throws -> Value {
        if let answer, answer.holds(generation: kept.generation, now: now) { return answer.value }
        let value = try read()
        // One step early rather than late: reading again changes nothing, and a figure left a tick too long would be wrong.
        let leaving = try store.firstEventTime(from: window.start).map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 + length).nextDown) }
        answer = Sliding(
            value: value,
            generation: kept.generation,
            computedAt: now,
            expires: [leaving, kept.nextEvent].compactMap { $0 }.min()
        )
        return value
    }

    /// The minute buckets, which move on with the wall clock rather than with any event.
    private func series(kept: KeptFigures, now: Date) throws -> SeriesAnswer {
        if let answer = keptSeries, answer.holds(generation: kept.generation, now: now) { return answer.value }
        let minutes = try store.minuteGroups(
            endingAt: now,
            filter: EventFilter(sources: preferences.enabledSources),
            thresholds: prices.longContextThresholds
        )
        let value = SeriesAnswer(
            tokens: minutes.map { $0.reduce(.zero) { $0 + $1.tokens } },
            cost: minutes.map { prices.usdByCategory(of: $0) }
        )
        let nextMinute = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 / 60).rounded(.down) + 1) * 60)
        keptSeries = Sliding(
            value: value,
            generation: kept.generation,
            computedAt: now,
            expires: [nextMinute, kept.nextEvent].compactMap { $0 }.min()
        )
        return value
    }

    /// `(now − seconds, now]` as the half-open range the store takes: both ends one step on, in the unix seconds it compares.
    private static func range(endingAt now: Date, seconds: TimeInterval) -> TimeRange {
        let end = now.timeIntervalSince1970
        return TimeRange(start: Date(timeIntervalSince1970: (end - seconds).nextUp), end: Date(timeIntervalSince1970: end.nextUp))
    }

    /// The named clients seen today or in the rate window, busiest first. Events that name no client have no row of their own.
    private func clients(rate: [SourceClientTokens], today: [SourceClientTokens]) -> [ClientRow] {
        Set((rate + today).compactMap(\.client))
            .map { client in
                ClientRow(
                    client: client,
                    perMinute: perMinute(rate.first { $0.client == client }?.tokens.total ?? 0),
                    today: today.first { $0.client == client }?.tokens.total ?? 0
                )
            }
            .sorted { ($1.today, $0.client) < ($0.today, $1.client) }
    }

    /// Active first, by rate; then by how recently they were used.
    private static func displayOrder(_ l: SourceRow, _ r: SourceRow) -> Bool {
        if l.isActive != r.isActive { return l.isActive }
        if l.perMinute != r.perMinute { return l.perMinute > r.perMinute }
        return (l.lastActivity ?? .distantPast) > (r.lastActivity ?? .distantPast)
    }

    /// A projection for each snapshot: anthropic, openai, xai, each by five-hour, weekly, then model-scoped limits.
    private func projections(of snapshots: [QuotaSnapshot], generation: Int, now: Date) throws -> [Projection] {
        var kept: [Limit: CachedWeights] = [:]
        let projections = try snapshots.sorted(by: Self.displayOrder).map { snapshot in
            let limit = Limit(snapshot)
            var entry = cachedWeights[limit]
            if entry == nil || entry?.isDue(latest: snapshot, generation: generation, now: now) == true {
                let weights = try weights(of: snapshot, now: now)
                entry = CachedWeights(snapshot: snapshot, weights: weights, computedAt: now, generation: generation)
            }
            kept[limit] = entry
            return entry.map { ProjectionEngine.project($0.snapshot, weights: $0.weights, now: now) }
        }
        cachedWeights = kept
        return projections.compactMap { $0 }
    }

    private func weights(of snapshot: QuotaSnapshot, now: Date) throws -> WindowWeights {
        // Nothing would read them, and this would be the longest pass of all, back to where the window opened.
        if ProjectionEngine.isLongOver(snapshot, at: now) { return WindowWeights(calibration: 0, afterSnapshot: 0, recent: 0) }
        weightPasses += 1
        return try QuotaWeights.compute(
            store: store,
            prices: prices,
            snapshot: snapshot,
            includedSources: preferences.quotaSources.intersection(preferences.enabledSources),
            now: now
        )
    }

    private static func displayOrder(_ l: QuotaSnapshot, _ r: QuotaSnapshot) -> Bool {
        func key(_ s: QuotaSnapshot) -> (Int, Int, Int, String) {
            (
                QuotaProvider.allCases.firstIndex(of: s.provider) ?? 0,
                s.window == .fiveHour ? 0 : 1,
                s.scope == nil ? 0 : 1,
                s.scope ?? ""
            )
        }
        return key(l) < key(r)
    }

    // MARK: Overview and log parts

    /// Biggest first. `name` turns a key into what is shown; "" is left for the app, which has the words in both languages.
    private func rows(_ breakdown: [String: [PricingGroup]], name: (String) -> String = { $0 }) -> [BreakdownRow] {
        breakdown
            .map { key, groups in
                BreakdownRow(key: name(key), tokens: groups.reduce(.zero) { $0 + $1.tokens }, cost: prices.cost(of: groups))
            }
            .sorted { ($1.tokens.total, $0.key) < ($0.tokens.total, $1.key) }
    }

    /// What one event costs, or nil when it has no price.
    private func usd(of event: UsageEvent) -> Double? {
        let band = prices.longContextThresholds.lastIndex { event.tokens.prompt > $0 }.map { $0 + 1 } ?? 0
        return prices.usd(PricingGroup(model: event.model, speed: event.speed, geo: event.geo, promptBand: band, tokens: event.tokens))
    }
}
