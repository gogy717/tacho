import Charts
import SwiftUI
import TachoKit

/// The Cache page, already worded.
struct CacheState: Equatable {
    struct Point: Equatable {
        var label: String
        /// What the axis says here, if anything.
        var axis: String?
        /// nil with no prompt tokens: the column keeps its place on the axis, with nothing to plot.
        var hitRate: Double?
    }

    /// The same range counted two ways: tokens and cost.
    struct TwoWays: Equatable {
        var tokensTotal: String
        var costTotal: String
        var byTokens: [SplitBar.Part]
        var byCost: [SplitBar.Part]
        /// `Cache read: 97% of tokens, 46% of cost`, with its colour.
        var legend: [SwatchLine]
    }

    var stats: [Stat] = []
    /// nil for a range with nothing in it.
    var trend: [Point]?
    /// Nothing happened in this range: said in place of the chart.
    var isEmpty = false
    var twoWays: TwoWays?
    var highlights: [String] = []
    var byCLI: [FigureRow] = []
}

extension CacheState {
    init(figures: DetailFigures, calendar: Calendar = .current) {
        let totals = figures.totals
        let highlights = figures.highlights.cache.map(WindowLabels.sentence)
        guard totals.tokens.total > 0 else {
            self.init(isEmpty: true, highlights: highlights)
            return
        }
        var stats: [Stat] = []
        if let hit = totals.tokens.cacheHitRate {
            stats.append(Stat(label: String(localized: "stat.hitRate", bundle: .tacho), value: Self.percent(hit)))
        }
        stats.append(Stat(label: String(localized: "stat.kept", bundle: .tacho), value: Self.kept(figures.cacheSaving)))
        stats.append(Stat(label: String(localized: "stat.writes", bundle: .tacho), value: totals.cost.usd > 0 ? TokenFormat.usdFigure(totals.costByCategory.cacheWrite) : String(localized: "cost.noPrice", bundle: .tacho)))
        self.init(
            stats: stats,
            trend: figures.columns.enumerated().map { index, column in
                Point(
                    label: WindowLabels.columnLabel(column.start, range: figures.range, calendar: calendar),
                    axis: WindowLabels.axisLabel(column.start, index: index, range: figures.range, calendar: calendar),
                    hitRate: column.tokens.cacheHitRate.map { $0 * 100 }
                )
            },
            twoWays: Self.twoWays(totals),
            highlights: highlights,
            byCLI: figures.bySource.compactMap { row in
                row.tokens.cacheHitRate.map { FigureRow(name: row.key, figure: Self.percent($0), fraction: $0) }
            }
        )
    }

    private static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    /// "no price" when nothing is priced; a `+` when some is left out.
    private static func kept(_ saving: CostSummary) -> String {
        let figure = Labels.figure(saving)
        return saving.usd > 0 ? String(format: String(localized: "stat.keptValue", bundle: .tacho), figure) : figure
    }

    private static func twoWays(_ totals: PeriodTotals) -> TwoWays? {
        let tokens = totals.tokens
        let cost = totals.costByCategory
        guard tokens.total > 0, cost.total > 0 else { return nil }
        let byTokens = Theme.stackOrder.map { Double($0.tokens(in: tokens)) / Double(tokens.total) }
        let byCost = Theme.stackOrder.map { $0.cost(in: cost) / cost.total }
        return TwoWays(
            tokensTotal: TokenFormat.compact(tokens.total),
            costTotal: Labels.figure(totals.cost),
            byTokens: zip(Theme.stackOrder, byTokens).map { .init(share: $1, color: $0.color) },
            byCost: zip(Theme.stackOrder, byCost).map { .init(share: $1, color: $0.color) },
            legend: Theme.stackOrder.indices.map { index in
                let category = Theme.stackOrder[index]
                return SwatchLine(color: category.color, text: String(
                    format: String(localized: "cache.share", bundle: .tacho),
                    category.name,
                    Int((byTokens[index] * 100).rounded()),
                    Int((byCost[index] * 100).rounded())
                ))
            }
        )
    }
}

/// What the cache does for the bill: spec section 12.4.
struct CachePage: View {
    private static let refreshInterval: Duration = .seconds(60)

    let model: AppModel
    var read: DetailRead?

    @State private var range = DetailRange.week
    @State private var figures: Loaded<DetailFigures> = .loading

    var body: some View {
        // A container, not a `Group`: a `Group` hands its modifiers to each branch, so the toolbar would go and come back with the figures.
        VStack(spacing: 0) {
            PageControls {
                RangePicker(selection: $range)
            }
            switch figures {
            case .loading: HeldPlaceholder(kind: .detail)
            case .failed: ProblemNote(model: model)
            case .ready(let figures):
                FigureFade(value: figures) {
                    CacheContent(state: CacheState(figures: figures))
                }
                .preference(
                    key: ShownAskKey.self,
                    value: ShownAsk(page: .cache, range: figures.range.rawValue, marker: "\(Int(figures.totals.cost.usd.rounded()))")
                )
            }
        }
            .onChange(of: model.pendingRoute, initial: true) {
                if let route = model.takeRoute(for: .cache), let asked = route.range { range = asked }
            }
            .task(id: Load(range: range, epoch: model.figuresEpoch)) {
                // A miss shows nothing of the previous range. A hit shows that range's own last answer, and the read below replaces it quietly.
                let ask = FigureAsk(page: .cache, range: range)
                if case .detail(let cached) = model.remembered(ask), cached.range == range {
                    figures = .ready(cached)
                } else {
                    figures = .loading
                }
                await model.whileShowing(.cache, every: Self.refreshInterval) { await load() }
            }
    }

    private struct Load: Equatable {
        var range: DetailRange
        var epoch: Int
    }

    private func load() async {
        let asked = range
        let latest = try? await model.detail(asked, via: read)
        guard !Task.isCancelled, range == asked else { return }
        guard let latest, latest.range == asked else {
            figures = .failed
            return
        }
        model.remember(.detail(latest), for: FigureAsk(page: .cache, range: asked))
        if case .ready(let old) = figures, old == latest { return }
        figures = .ready(latest)
    }
}

struct CacheContent: View {
    private static let hitAxis = String(localized: "stat.hitRate", bundle: .tacho)
    private static let timeAxis = String(localized: "chart.hour", bundle: .tacho)

    @State private var selection: String?

    let state: CacheState

    /// The legend, or under the pointer what that column holds.
    private var legend: String {
        guard let point = state.trend?.first(where: { $0.label == selection }), let rate = point.hitRate else {
            return String(localized: "cache.legend", bundle: .tacho)
        }
        return String(format: String(localized: "rate.menu.item", bundle: .tacho), point.label, String(format: "%.1f%%", rate))
    }

    var body: some View {
        PageBody {
            TwoColumns(weight: 1.75) {
                VStack(alignment: .leading, spacing: 8) {
                    StatRow(stats: state.stats)
                    if state.isEmpty {
                        EmptyRangeNote(height: 200)
                    } else if let trend = state.trend {
                        chart(trend)
                        Text(legend)
                            .font(Theme.Style.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let twoWays = state.twoWays {
                        twoWaysBlock(twoWays)
                    }
                }
            } right: {
                VStack(alignment: .leading, spacing: 14) {
                    HighlightList(sentences: state.highlights)
                    FigureList(title: String(localized: "overview.byCLI", bundle: .tacho), rows: state.byCLI, color: Theme.cacheRead)
                    AboutBox(text: String(localized: "about.cache", bundle: .tacho))
                }
            }
        }
    }

    private func chart(_ trend: [CacheState.Point]) -> some View {
        let plotted = trend.compactMap { point in point.hitRate.map { (label: point.label, rate: $0) } }
        let lowest = (plotted.map(\.rate).min() ?? 0) - 1
        return Chart {
            ForEach(plotted.indices, id: \.self) { index in
                LineMark(x: .value(Self.timeAxis, plotted[index].label), y: .value(Self.hitAxis, plotted[index].rate))
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Theme.cacheRead)
            }
            if let last = plotted.last {
                PointMark(x: .value(Self.timeAxis, last.label), y: .value(Self.hitAxis, last.rate))
                    .symbolSize(36)
                    .foregroundStyle(Theme.cacheRead)
            }
        }
        .chartXSelection(value: $selection)
        .chartXScale(domain: trend.map(\.label))
        .chartYScale(domain: max(0, lowest)...100)
        .chartXAxis {
            AxisMarks(values: trend.filter { $0.axis != nil }.map(\.label)) { value in
                AxisValueLabel {
                    Text(trend.first { $0.label == value.as(String.self) }?.axis ?? "")
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartLegend(.hidden)
        .frame(height: 200)
    }

    private func twoWaysBlock(_ twoWays: CacheState.TwoWays) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeading(String(localized: "cache.twoWays", bundle: .tacho))
            bar(String(localized: "cache.byTokens", bundle: .tacho), total: twoWays.tokensTotal, parts: twoWays.byTokens)
            bar(String(localized: "cache.byCost", bundle: .tacho), total: twoWays.costTotal, parts: twoWays.byCost)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(twoWays.legend) { line in
                    HStack(spacing: 4) {
                        Swatch(color: line.color)
                        Text(line.text)
                            .monospacedDigit()
                    }
                }
            }
            .font(Theme.Style.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }

    private func bar(_ label: String, total: String, parts: [SplitBar.Part]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text(total)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(Theme.Style.small)
            SplitBar(parts: parts, height: 14)
        }
    }
}
