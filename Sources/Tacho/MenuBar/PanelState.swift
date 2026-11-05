import Foundation
import TachoKit

/// The panel, already worded. The views below only lay it out, so that every state can be drawn and measured with no engine behind it.
struct PanelState: Equatable {
    struct Reading: Equatable, Identifiable {
        var mode: RateMode
        /// `Output · 11.2k/min`.
        var title: String

        var id: RateMode { mode }
    }

    struct Rate: Equatable {
        enum Headline: Equatable {
            case live(figure: String)
            case idle(lastSeen: String?)
            /// The recent logs are still being read, so saying idle could be false.
            case reading
        }

        var headline: Headline
        var mode: RateMode
        var modeName: String
        /// The menu's rows, one for each mode.
        var readings: [Reading]
        /// Something the figure leaves out.
        var note: String?
        /// The last hour, oldest first, one entry a minute with a value for each of `layers`.
        var series: [[Double]]
        /// Bottom first.
        var layers: [TokenCategory]
        /// What an empty chart says.
        var emptyText = String(localized: "chart.empty", bundle: .tacho)
        /// In Cost mode, the tokens with no price in each minute of `series`.
        var unpricedTokens: [Int] = []

        /// What a minute of `series` comes to, under the pointer.
        func figure(ofMinute index: Int) -> String? {
            guard series.indices.contains(index) else { return nil }
            let unpriced = unpricedTokens.indices.contains(index) ? unpricedTokens[index] : 0
            return Labels.chartValue(series[index].reduce(0, +), mode: mode, unpricedTokens: unpriced)
        }

        /// What VoiceOver reads for the headline, whose label says only what it does.
        var spoken: String {
            switch headline {
            case .live(let figure): "\(figure), \(modeName)"
            case .idle(let lastSeen): [String(localized: "rate.idle", bundle: .tacho), lastSeen].compactMap(\.self).joined(separator: ", ")
            case .reading: String(localized: "rate.reading", bundle: .tacho)
            }
        }
    }

    struct Today: Equatable {
        var title: String
        var sentence: String
        var series: UsualRangeSeries
        var value: String
        var usual: String?
        var note: String?
        /// The card has fallen back to output, which is the one case it takes a category's colour.
        var isOutput = false
        /// Why it has.
        var help: String?
        var route = Route(page: .cost, range: .day)
    }

    struct LimitCell: Equatable, Identifiable {
        var label: String
        var percent: String
        var value: Double
        /// Where use would be at an even pace.
        var pace: Double?
        var level: Meter.Level
        var caption: String

        var id: String { label }
    }

    struct LimitRow: Equatable, Identifiable {
        enum Content: Equatable {
            case cells([LimitCell])
            /// No figure to show: "No recent quota data". It wraps, since its end is the age.
            case message(String)
            /// A list that can run on, and may be cut short: `OpenCode ≈ $0.20/h · pi ≈ $0.10/h`.
            case line(String)
        }

        var name: String
        var content: Content

        /// A provider can have a row of figures and a line saying some limit has none.
        var id: String {
            switch content {
            case .cells: name
            case .message(let text), .line(let text): name + text
            }
        }
    }

    struct Limits: Equatable {
        /// "updated 2 min ago".
        var age: String?
        var say: String?
        var tone: Tone
        var rows: [LimitRow]
        var route = Route(page: .limits)
    }

    struct Tile: Equatable, Identifiable {
        enum Mark: Equatable {
            case none
            case needle(value: Double, p25: Double, p75: Double)
            case spark([Double])
            case shares([Double])
            /// One row in `Theme.stackOrder`, as fractions.
            case layers([Double])
        }

        var id: String
        var title: String
        /// nil for a card that says everything in `say`.
        var value: String?
        var say: String?
        var mark: Mark
        /// Where a click goes.
        var route: Route
    }

    struct Progress: Equatable {
        var text: String
        /// nil until there is a total to measure against.
        var fraction: Double?
    }

    var rate: Rate
    var today: Today
    var limits: Limits
    var tiles: [Tile]
    var progress: Progress?
}

extension PanelState.Limits {
    /// - Parameters:
    ///   - insight: which rule fires. With no answer yet there is no sentence.
    ///   - sources: for the row of CLIs that have no quota to show.
    init(quotas: [Projection], insight: LimitsInsight? = nil, sources: [SourceRow] = [], now: Date) {
        let current = quotas.filter(\.hasRecentData)
        let newest = current.filter { !$0.isStale }.map(\.snapshot.observedAt).max()
        let (say, tone) = insight.map { Labels.limitSay($0, now: now) } ?? (nil, .plain)
        self.init(
            age: newest.map { Labels.updated(now.timeIntervalSince($0)) },
            say: say,
            tone: tone,
            rows: QuotaProvider.allCases.flatMap { provider in
                Self.rows(of: quotas.filter { $0.snapshot.provider == provider }, provider: provider, now: now)
            } + Self.noQuotaRow(sources),
            route: Route(page: .limits, limit: insight?.limit.map { LimitKey($0.snapshot) })
        )
    }

    /// CLIs in use with no limit to watch still cost something: `OpenCode ≈ $0.20/h · pi ≈ $0.10/h`.
    private static func noQuotaRow(_ sources: [SourceRow]) -> [PanelState.LimitRow] {
        let lines = sources.filter { !$0.hasQuota && $0.isActive && $0.today.total > 0 }.map { "\($0.source.displayName) \(Labels.hourlyCost($0.costLastHour))" }
        guard !lines.isEmpty else { return [] }
        return [PanelState.LimitRow(name: String(localized: "limits.noQuotaShort", bundle: .tacho), content: .line(lines.joined(separator: " · ")))]
    }

    /// A row of figures for what is recent, and one line for what is not. The line names no limit, so however many it stands for it
    /// gives the newest figure's age.
    private static func rows(of quotas: [Projection], provider: QuotaProvider, now: Date) -> [PanelState.LimitRow] {
        let name = Labels.provider(provider)
        var rows: [PanelState.LimitRow] = []
        let recent = quotas.filter(\.hasRecentData)
        if !recent.isEmpty {
            rows.append(PanelState.LimitRow(name: name, content: .cells(recent.map { cell($0, now: now) })))
        }
        if let newest = quotas.filter({ !$0.hasRecentData }).map(\.snapshot.observedAt).max() {
            let age = Labels.ageShort(now.timeIntervalSince(newest))
            rows.append(PanelState.LimitRow(name: name, content: .message(String(format: String(localized: "limit.noRecent", bundle: .tacho), age))))
        }
        return rows
    }

    private static func cell(_ quota: Projection, now: Date) -> PanelState.LimitCell {
        PanelState.LimitCell(
            label: quota.snapshot.scope ?? String(localized: quota.snapshot.window == .fiveHour ? "limit.short.fiveHour" : "limit.short.week", bundle: .tacho),
            percent: Labels.percent(quota) ?? "",
            value: quota.estimatedPercent / 100,
            pace: quota.isStale ? nil : quota.paceFraction(at: now),
            level: level(quota),
            caption: quota.isStale
                ? String(format: String(localized: "limit.age", bundle: .tacho), Labels.ageShort(now.timeIntervalSince(quota.snapshot.observedAt)))
                : Labels.reset(quota.resetsAt, now: now)
        )
    }

    /// The engine's own warning for this one limit, so that a bar never disagrees with the icon.
    private static func level(_ quota: Projection) -> Meter.Level {
        switch ProjectionEngine.alert([quota]) {
        case .red: .critical
        case .amber: .warning
        case .none: quota.isStale ? .stale : .normal
        }
    }
}

extension PanelState.Today {
    /// - Parameter insight: nil until the first answer arrives, and then no comparison is made.
    init(dashboard: Dashboard, insights: PanelInsights?, now: Date) {
        let insight = insights?.results.today
        let isOutput = insight?.metric == .output
        let cost = dashboard.today.cost
        let figure = isOutput ? TokenFormat.compact(dashboard.today.tokens.output) : Labels.figure(cost)
        // "no price so far" would promise one. Until the answer turns the card to output, there is just none.
        let hasNoPrice = !isOutput && cost.usd == 0 && cost.unpricedTokens > 0
        self.init(
            title: String(localized: isOutput ? "card.outputToday" : "card.costToday", bundle: .tacho),
            sentence: insight.map { Labels.sentence($0.rule) } ?? (dashboard.progress.isReadingNewest ? String(localized: "highlight.h1", bundle: .tacho) : " "),
            series: insights.map(Self.series) ?? UsualRangeSeries(),
            value: hasNoPrice ? figure : String(format: String(localized: "today.soFar", bundle: .tacho), figure),
            usual: insight.flatMap { Labels.usual($0, now: now) },
            note: Labels.clockBehind(newestEvent: dashboard.newestEvent, now: now) ?? Labels.notCounted(dashboard.today.cost),
            isOutput: isOutput,
            help: isOutput ? String(localized: "today.outputHelp", bundle: .tacho) : nil
        )
    }
}

extension PanelState.Today {
    /// What the card draws: spec §4.4. While logs are being read there is no band to trust, and with no use today no line to draw.
    private static func series(_ insights: PanelInsights) -> UsualRangeSeries {
        let today = insights.results.today
        let curve = today.metric == .output ? insights.output : insights.cost
        let isReading = today.rule == .h1 || today.rule == .h1h
        return UsualRangeSeries(
            band: isReading ? [] : curve.band.map { .init(hour: $0.hour, low: $0.low, high: $0.high) },
            line: today.rule == .h3 ? [] : curve.today.map { .init(hour: $0.hour, value: $0.value) }
        )
    }
}

extension PanelState {
    /// - Parameters:
    ///   - insights: which rules fire, once the first answer is in.
    ///   - now: what relative times are told from: when the figures were read, or for a window page, the clock's last minute.
    init(dashboard: Dashboard, preferences: Preferences, insights: PanelInsights? = nil, now: Date) {
        let mode = preferences.rateMode
        let modeName = Labels.rateMode(mode)
        let lastSeen = dashboard.latestRequest.map {
            String(format: String(localized: "rate.lastRequest", bundle: .tacho), Labels.duration(now.timeIntervalSince($0)))
        }
        let headline: Rate.Headline = if dashboard.progress.isReadingNewest {
            .reading
        } else if dashboard.isIdle {
            .idle(lastSeen: lastSeen)
        } else {
            .live(figure: Labels.rate(dashboard, mode: mode, unit: preferences.rateUnit))
        }
        let layers = mode == .output ? [TokenCategory.output] : Theme.stackOrder
        let hasNoPrice = mode == .cost && dashboard.series.contains { $0.total > 0 } && !dashboard.costSeries.contains { $0.total > 0 }
        self.init(
            rate: Rate(
                headline: headline,
                mode: mode,
                modeName: modeName,
                readings: [RateMode.output, .allTokens, .cost].map { each in
                    Reading(mode: each, title: String(
                        format: String(localized: "rate.menu.item", bundle: .tacho),
                        Labels.rateMode(each),
                        Labels.rate(dashboard, mode: each, unit: preferences.rateUnit)
                    ))
                },
                note: mode == .cost ? Labels.rateNote(dashboard.costPerMinute) : nil,
                series: mode == .cost
                    ? dashboard.costSeries.map { minute in layers.map { $0.usd(in: minute) } }
                    : dashboard.series.map { counts in layers.map { Double($0.tokens(in: counts)) } },
                layers: layers,
                emptyText: String(localized: hasNoPrice ? "chart.noPrice" : "chart.empty", bundle: .tacho),
                unpricedTokens: mode == .cost ? dashboard.costSeries.map(\.unpricedTokens) : []
            ),
            today: Today(dashboard: dashboard, insights: insights, now: now),
            limits: Limits(quotas: dashboard.quotas, insight: insights?.results.limits, sources: dashboard.sources, now: now),
            tiles: Tile.pinned(preferences.pinnedCards, dashboard: dashboard, insights: insights),
            progress: Labels.progress(dashboard.progress).map {
                Progress(text: $0, fraction: dashboard.progress.filesTotal > 0 ? Double(dashboard.progress.filesDone) / Double(dashboard.progress.filesTotal) : nil)
            }
        )
    }
}
