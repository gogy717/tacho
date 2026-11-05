import SwiftUI
import TachoKit

/// A range page's figures, already worded, so that every state draws with no engine behind it.
struct RangeState: Equatable {
    var stats: [Stat] = []
    /// nil for a range with nothing in it.
    var chart: ColumnSeries?
    /// Nothing happened in this range: said in place of the chart.
    var isEmpty = false
    /// What the figures leave out.
    var note: String?
    var highlights: [String] = []
    /// Cost by token type.
    var byType: [SplitBar.Part] = []
    var byTypeLegend: [SwatchLine] = []
    /// Tokens by type, with thinking where it is recorded.
    var byTypeRows: [FigureRow] = []
    var bySource: [FigureRow] = []
    var byModel: [FigureRow] = []
}

extension RangeState {
    /// - Parameters:
    ///   - rate: the cost rate now, for Cost's Day.
    ///   - isReading: older logs are still coming in, so no day can be called missing.
    ///   - today: rules H, for rule D1, which is Cost today's sentence.
    init(
        figures: DetailFigures,
        kind: RangePage.Kind,
        metric: TokensMetric,
        rate: String? = nil,
        isReading: Bool = false,
        today: TodayRule? = nil,
        grouping: DetailGrouping? = nil,
        colours: LayerColours? = nil,
        calendar: Calendar = .current
    ) {
        let isCost = kind == .cost
        let isOutput = !isCost && metric == .output
        let bands = isCost ? figures.usualCost : (isOutput ? figures.usualOutput : figures.usualTokens)
        let stats = Self.stats(figures, kind: kind, isOutput: isOutput, bands: bands, rate: rate, isReading: isReading)
        let highlights = Self.highlights(figures.highlights, kind: kind, isOutput: isOutput, today: today)
        // Lists hide with nothing in the range, and what the engine says about it does not.
        guard figures.totals.tokens.total > 0 else {
            self.init(stats: stats, isEmpty: true, highlights: highlights)
            return
        }
        let figure: (BreakdownRow) -> String = { isCost ? Labels.figure($0.cost) : TokenFormat.compact($0.tokens.total) }
        self.init(
            stats: stats,
            chart: Self.chart(figures, isCost: isCost, isOutput: isOutput, bands: bands, stack: Self.stack(figures, grouping, colours, isCost: isCost, isOutput: isOutput), calendar: calendar),
            note: isCost ? Labels.notCounted(figures.totals.cost) : nil,
            highlights: highlights,
            byType: isCost ? Self.costShares(figures.totals.costByCategory) : [],
            byTypeLegend: isCost ? Self.costLegend(figures.totals.costByCategory) : [],
            byTypeRows: isCost ? [] : Self.tokenRows(figures.totals.tokens),
            bySource: Self.rows(figures.bySource, isCost: isCost, figure: figure, clients: figures.clientsBySource),
            byModel: Self.rows(figures.byModel, isCost: isCost, figure: figure, clients: [:]) { Labels.model($0) }
        )
    }

    /// Rules D for Cost; for Tokens rules W on the metric shown, then rules T.
    private static func highlights(_ highlights: DetailHighlights, kind: RangePage.Kind, isOutput: Bool, today: TodayRule?) -> [String] {
        switch kind {
        case .cost:
            return highlights.cost.compactMap { WindowLabels.sentence($0, today: today) }
        case .tokens:
            let week = (isOutput ? highlights.weekOutput : highlights.weekTokens).map(WindowLabels.sentence)
            return [week].compactMap { $0 } + highlights.tokens.map(WindowLabels.sentence)
        }
    }

    /// A chart's layers by model or CLI.
    private struct Stack {
        var layers: [ColumnSeries.Layer]
        var values: [[Double]]
    }

    /// nil for the Type view, and while the figures shown are still the last choice's: the read for this one has not come back.
    private static func stack(_ figures: DetailFigures, _ grouping: DetailGrouping?, _ colours: LayerColours?, isCost: Bool, isOutput: Bool) -> Stack? {
        guard let grouping, let colours, figures.grouping == grouping else { return nil }
        let layers = figures.layers(of: isCost ? .cost : (isOutput ? .output : .allTokens))
        let slots = colours.slots(for: layers.compactMap(\.key))
        return Stack(
            layers: layers.map { layer in
                guard let key = layer.key else {
                    return ColumnSeries.Layer(name: String(localized: "chart.other", bundle: .tacho), color: Theme.seriesOther)
                }
                return ColumnSeries.Layer(name: grouping == .model ? Labels.model(key) : key, color: Theme.series[slots[key] ?? 0])
            },
            values: figures.columns.indices.map { index in layers.map { $0.values[index] } }
        )
    }

    /// The usual band is a range of what the Type view draws, so a stack goes without it. The page's stat still says it in words.
    private static func chart(_ figures: DetailFigures, isCost: Bool, isOutput: Bool, bands: UsualBands, stack: Stack?, calendar: Calendar) -> ColumnSeries {
        let categories = isOutput ? [TokenCategory.output] : Theme.stackOrder
        let value: (DetailColumn, TokenCategory) -> Double = { column, category in
            isCost ? category.cost(in: column.costByCategory) : Double(category.tokens(in: column.tokens))
        }
        return ColumnSeries(
            layers: stack?.layers ?? categories.map { ColumnSeries.Layer(name: $0.name, color: $0.color) },
            columns: figures.columns.enumerated().map { index, column in
                let label = WindowLabels.columnLabel(column.start, range: figures.range, calendar: calendar)
                let values = stack?.values[index] ?? categories.map { value(column, $0) }
                let total = values.reduce(0, +)
                return ColumnSeries.Column(
                    id: String(index),
                    axis: WindowLabels.axisLabel(column.start, index: index, range: figures.range, calendar: calendar),
                    readout: String(format: String(localized: "rate.menu.item", bundle: .tacho), label, isCost ? Labels.figure(column.cost) : TokenFormat.compact(Int(total))),
                    values: values,
                    usual: stack == nil && figures.range == .day && bands.hourly.indices.contains(index) ? bands.hourly[index].closed : nil
                )
            },
            usual: stack == nil && (figures.range == .week || figures.range == .month) ? bands.daily?.closed : nil,
            isMoney: isCost
        )
    }

    private static func stats(_ figures: DetailFigures, kind: RangePage.Kind, isOutput: Bool, bands: UsualBands, rate: String?, isReading: Bool) -> [Stat] {
        let totals = figures.totals
        let total: String = switch kind {
        case .cost: Labels.figure(totals.cost)
        case .tokens: TokenFormat.compact(isOutput ? totals.tokens.output : totals.tokens.total)
        }
        var stats = [Stat(label: WindowLabels.totalLabel(figures.range), value: total)]
        switch kind {
        case .cost:
            if figures.range == .day, let rate {
                stats.append(Stat(label: String(localized: "stat.now", bundle: .tacho), value: rate))
            }
            if let median = figures.medianCost {
                let label: String.LocalizationValue = figures.range == .year ? "stat.medianMonth" : "stat.medianDay"
                stats.append(Stat(label: String(localized: label, bundle: .tacho), value: TokenFormat.usdFigure(median)))
            }
        case .tokens:
            stats.append(Stat(
                label: String(localized: isOutput ? "stat.allTokens" : "stat.output", bundle: .tacho),
                value: TokenFormat.compact(isOutput ? totals.tokens.total : totals.tokens.output)
            ))
        }
        if figures.range != .year {
            stats.append(Stat(
                label: String(localized: "stat.usual", bundle: .tacho),
                value: WindowLabels.usual(bands, range: figures.range, isCost: kind == .cost, daysOfUse: figures.daysOfUse, todayHasUse: figures.todayHasUse, isReading: isReading)
            ))
        }
        return stats
    }

    private static func costShares(_ cost: CategoryCost) -> [SplitBar.Part] {
        guard cost.total > 0 else { return [] }
        return Theme.stackOrder.map { SplitBar.Part(share: $0.cost(in: cost) / cost.total, color: $0.color) }
    }

    private static func costLegend(_ cost: CategoryCost) -> [SwatchLine] {
        guard cost.total > 0 else { return [] }
        return Theme.stackOrder.map { SwatchLine(color: $0.color, text: "\($0.name) \(Int(($0.cost(in: cost) / cost.total * 100).rounded()))%") }
    }

    private static func tokenRows(_ tokens: TokenCounts) -> [FigureRow] {
        func row(_ name: String, _ count: Int, under: [FigureRow] = []) -> FigureRow {
            FigureRow(name: name, figure: TokenFormat.compact(count), fraction: nil, clients: under)
        }
        let thinking = tokens.reasoning > 0 ? [row(String(localized: "tokens.thinking", bundle: .tacho), tokens.reasoning)] : []
        return [
            row(TokenCategory.input.name, tokens.input),
            row(TokenCategory.output.name, tokens.output, under: thinking),
            row(TokenCategory.cacheRead.name, tokens.cacheRead),
            row(String(localized: "prices.cacheWrite5m", bundle: .tacho), tokens.cacheWrite5m),
            row(String(localized: "prices.cacheWrite1h", bundle: .tacho), tokens.cacheWrite1h),
        ]
    }

    /// Largest first. The engine sorts by tokens, so cost re-sorts here, with what has no price last: spec section 12.2.
    private static func rows(
        _ rows: [BreakdownRow],
        isCost: Bool,
        figure: (BreakdownRow) -> String,
        clients: [String: [BreakdownRow]],
        name: (String) -> String = { $0 }
    ) -> [FigureRow] {
        let size: (BreakdownRow) -> Double = { isCost ? $0.cost.usd : Double($0.tokens.total) }
        let sorted = isCost ? rows.sorted { size($0) > size($1) } : rows
        let top = sorted.map(size).max() ?? 0
        return sorted.map { row in
            let source = Source.allCases.first { $0.displayName == row.key }
            let named = (clients[row.key] ?? []).sorted { isCost ? size($0) > size($1) : false }
            return FigureRow(
                name: name(row.key),
                figure: figure(row),
                fraction: top > 0 ? size(row) / top : nil,
                clients: named.count > 1 ? named.map { client in
                    FigureRow(name: source.map { Labels.client($0, client.key) } ?? client.key, figure: figure(client), fraction: nil)
                } : []
            )
        }
    }
}

extension UsualRange {
    /// As a chart's range. A band with no height still marks where usual is.
    var closed: ClosedRange<Double> {
        p25...max(p25, p75)
    }
}

extension TokenCategory {
    func cost(in cost: CategoryCost) -> Double {
        switch self {
        case .input: cost.input
        case .output: cost.output
        case .cacheRead: cost.cacheRead
        case .cacheWrite: cost.cacheWrite
        }
    }
}

/// Cost and Tokens: one figure over a range, with what it is made of. Spec sections 12.1 to 12.3.
struct RangePage: View {
    enum Kind {
        case cost, tokens

        var page: Page {
            switch self {
            case .cost: .cost
            case .tokens: .tokens
            }
        }

        var defaultRange: DetailRange {
            switch self {
            case .cost: .month
            case .tokens: .week
            }
        }

        var about: String {
            switch self {
            case .cost: String(localized: "about.cost", bundle: .tacho)
            case .tokens: String(localized: "about.tokens", bundle: .tacho)
            }
        }
    }

    private static let refreshInterval: Duration = .seconds(60)
    private static let lookInterval: Duration = .seconds(1)

    let model: AppModel
    let kind: Kind
    var read: DetailRead?

    @State private var range: DetailRange?
    @State private var metric = TokensMetric.allTokens
    @State private var figures: Loaded<DetailFigures> = .loading
    @State private var today: TodayRule?
    @State private var rate = RangeRate()

    private var shownRange: DetailRange {
        range ?? kind.defaultRange
    }

    private var grouping: DetailGrouping? {
        model.chart.grouping(on: kind.page)
    }

    /// Cost's rate, looked at from outside the body: as on Summary, a body that read the figures would lay the page out on most ticks.
    private func look() {
        rate.take(model.dashboard.map { Labels.rate($0, mode: .cost, unit: model.preferences.rateUnit) })
    }

    var body: some View {
        VStack(spacing: 0) {
            PageControls {
                RangePicker(selection: Binding(get: { shownRange }, set: { range = $0 }))
                if kind == .tokens {
                    Picker(String(localized: "stat.metric", bundle: .tacho), selection: $metric) {
                        Text(String(localized: "rate.mode.tokens", bundle: .tacho)).tag(TokensMetric.allTokens)
                        Text(String(localized: "rate.mode.output", bundle: .tacho)).tag(TokensMetric.output)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                GroupingPicker(selection: Binding(get: { grouping }, set: { model.chart.setGrouping($0, on: kind.page) }))
            }
            switch figures {
            case .loading: HeldPlaceholder(kind: .detail)
            case .failed: ProblemNote(model: model)
            case .ready(let figures):
                // Read here, in the page body. Inside the fade it would not subscribe, and the page would not redraw when the logs finish.
                ready(figures, isReading: model.isReadingLogs)
            }
        }
        .onChange(of: model.pendingRoute, initial: true) {
            guard let route = model.takeRoute(for: kind.page) else { return }
            if let asked = route.range { range = asked }
            if let asked = route.metric { metric = asked }
        }
        .task(id: Load(range: shownRange, grouping: grouping, epoch: model.figuresEpoch)) {
            // A miss shows nothing of the previous range. A hit shows that range's own last answer, and the read below replaces it quietly.
            let ask = FigureAsk(page: kind.page, range: shownRange, grouping: grouping)
            if case .detail(let cached) = model.remembered(ask), cached.range == shownRange {
                figures = .ready(cached)
            } else {
                figures = .loading
            }
            await model.whileShowing(kind.page, every: Self.refreshInterval) { await load() }
        }
        // A look stops with the window, and must not leave it coming back to an old rate.
        .onChange(of: model.mainWindowVisible) { if model.mainWindowVisible, kind == .cost { look() } }
        .task {
            guard kind == .cost else { return }
            await model.whileShowing(kind.page, every: Self.lookInterval) { look() }
        }
    }

    private func ready(_ figures: DetailFigures, isReading: Bool) -> some View {
        FigureFade(value: figures) {
            RangeContent(
                state: RangeState(
                    figures: figures,
                    kind: kind,
                    metric: metric,
                    rate: RangeRate.place,
                    isReading: isReading,
                    today: today,
                    grouping: grouping,
                    colours: grouping.map(model.chart.colours(for:))
                ),
                about: kind.about,
                rate: rate
            )
        }
        .preference(
            key: ShownAskKey.self,
            value: ShownAsk(page: kind.page, range: figures.range.rawValue, marker: "\(Int(figures.totals.cost.usd.rounded()))")
        )
    }

    private struct Load: Equatable {
        var range: DetailRange
        var grouping: DetailGrouping?
        var epoch: Int
    }

    private func load() async {
        let asked = shownRange
        let stacked = grouping
        do {
            guard let latest = try await model.detail(asked, grouping: stacked, via: read) else {
                if !Task.isCancelled { figures = .failed }
                return
            }
            guard !Task.isCancelled, shownRange == asked, grouping == stacked, latest.range == asked else { return }
            model.remember(.detail(latest), for: FigureAsk(page: kind.page, range: asked, grouping: stacked))
            if case .ready(let old) = figures, old == latest { return }
            figures = .ready(latest)
        } catch {
            if !Task.isCancelled { figures = .failed }
        }
        // Only rule D1 needs it, and the page has its figures either way.
        if kind == .cost { today = (try? await model.engine?.insights(now: Date()))?.results.today.rule }
    }
}

/// Cost's rate now, which moves on most ticks. Only `RangeStats` reads it, so nothing else is redrawn when it does.
@MainActor @Observable
final class RangeRate {
    /// Stands in `RangeState` for the words, which come here.
    static let place = ""

    private(set) var words: String?

    func take(_ latest: String?) {
        if latest != words { words = latest }
    }

    /// `stats` with the words in the rate's place, or without that place when there are none to give.
    func filling(_ stats: [Stat]) -> [Stat] {
        let label = String(localized: "stat.now", bundle: .tacho)
        return stats.compactMap { stat in
            guard stat.label == label else { return stat }
            guard let words else { return nil }
            var stat = stat
            stat.value = words
            return stat
        }
    }
}

/// The stats, as a view of their own for the rate to move in.
private struct RangeStats: View {
    let stats: [Stat]
    let rate: RangeRate?

    var body: some View {
        StatRow(stats: rate?.filling(stats) ?? stats)
    }
}

/// The figures of one `RangeState`.
struct RangeContent: View {
    let state: RangeState
    let about: String
    var rate: RangeRate?

    var body: some View {
        PageBody {
            TwoColumns(weight: 1.75) {
                VStack(alignment: .leading, spacing: 8) {
                    RangeStats(stats: state.stats, rate: rate)
                    if state.isEmpty {
                        EmptyRangeNote(height: 300)
                    } else if let chart = state.chart {
                        ColumnChart(series: chart)
                    }
                    if let note = state.note {
                        Say(note, tone: .warning)
                    }
                }
            } right: {
                VStack(alignment: .leading, spacing: 14) {
                    HighlightList(sentences: state.highlights)
                    if !state.byType.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            PageHeading(String(localized: "detail.byType", bundle: .tacho))
                            SplitBar(parts: state.byType, height: 10)
                            SwatchGrid(lines: state.byTypeLegend)
                        }
                    }
                    FigureList(title: String(localized: "detail.byType", bundle: .tacho), rows: state.byTypeRows)
                    FigureList(title: String(localized: "overview.byCLI", bundle: .tacho), rows: state.bySource)
                    FigureList(title: String(localized: "overview.byModel", bundle: .tacho), rows: state.byModel, shown: 5)
                    AboutBox(text: about)
                }
            }
        }
    }
}

/// Day, Week, Month, Year: first in the `PageControls` of every page with a range, so that it stays put between them. Never in the toolbar: a
/// control in the title bar answered on less of itself than it drew, about 20 pt short at each end, and only the real window showed it.
struct RangePicker: View {
    @Binding var selection: DetailRange

    var body: some View {
        Picker(String(localized: "overview.range", bundle: .tacho), selection: $selection) {
            ForEach(DetailRange.allCases, id: \.self) { Text(WindowLabels.range($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
