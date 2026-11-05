import Charts
import SwiftUI
import TachoKit

/// When the use happened: the last year by day, and a span by hour of the week.
struct HeatmapPage: View {
    private static let refreshInterval: Duration = .seconds(60)

    let model: AppModel

    @State private var range = RangeChoice.month
    /// The range `maps` answers, while a new one loads.
    @State private var shownRange = RangeChoice.month
    @State private var maps: Loaded<Heatmaps> = .loading

    var body: some View {
        Group {
            switch maps {
            case .loading: HeldPlaceholder(kind: .calendar)
            case .ready(let maps):
                FigureFade(value: maps) {
                    HeatmapContent(maps: maps, range: $range, isCurrent: range == shownRange)
                }
            case .failed: ProblemNote(model: model)
            }
        }
        .task(id: Asked(range: range, epoch: model.figuresEpoch)) {
            // A miss must not keep the previous span's hour grid under the new span's name.
            let ask = FigureAsk(page: .calendar, span: range)
            if case .heatmaps(let cached) = model.remembered(ask) {
                maps = .ready(cached)
                shownRange = range
            } else {
                maps = .loading
            }
            await model.whileShowing(.calendar, every: Self.refreshInterval) { await load() }
        }
    }

    private struct Asked: Equatable {
        var range: RangeChoice
        var epoch: Int
    }

    private func load() async {
        guard let engine = model.engine else {
            maps = .failed
            return
        }
        let asked = range
        let now = Date()
        do {
            let latest = try await engine.heatmaps(now: now, range: asked.timeRange(now: now))
            guard !Task.isCancelled, range == asked else { return }
            model.remember(.heatmaps(latest), for: FigureAsk(page: .calendar, span: asked), now: now)
            if case .ready(let old) = maps, old == latest, shownRange == asked { return }
            maps = .ready(latest)
            shownRange = asked
        } catch {
            if !Task.isCancelled { maps = .failed }
        }
    }
}

/// What the year grid colours by.
enum HeatMetric: String, CaseIterable, Identifiable {
    case tokens, cost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tokens: String(localized: "heatmap.tokens", bundle: .tacho)
        case .cost: String(localized: "sources.cost", bundle: .tacho)
        }
    }

    func value(of day: DayCell) -> Double {
        switch self {
        case .tokens: Double(day.tokens)
        case .cost: day.costUSD
        }
    }
}

/// Four shades, each holding about a quarter of the non-zero values, so that one huge day cannot wash out the rest.
struct HeatScale {
    /// One hue, light to dark; on a dark surface the order turns round, so that more use still stands out more.
    static let shades = [
        Color(light: 0x9EC5F4, dark: 0x104281),
        Color(light: 0x5598E7, dark: 0x256ABF),
        Color(light: 0x256ABF, dark: 0x5598E7),
        Color(light: 0x0D366B, dark: 0xB7D3F6),
    ]
    static let empty = Color.primary.opacity(0.07)

    private let edges: [Double]

    init(_ values: [Double]) {
        let used = values.filter { $0 > 0 }.sorted()
        edges = used.isEmpty ? [] : [0.25, 0.5, 0.75].map { used[Int(Double(used.count - 1) * $0)] }
    }

    /// The shade of `value`, 0 to 3; nil for no use.
    func level(of value: Double) -> Int? {
        value > 0 ? edges.filter { value > $0 }.count : nil
    }

    func color(of value: Double) -> Color {
        level(of: value).map { Self.shades[$0] } ?? Self.empty
    }
}

/// Both grids.
struct HeatmapContent: View {
    let maps: Heatmaps
    @Binding var range: RangeChoice
    /// False while `maps` still answers the last range: the hour grid dims until the new one is in.
    let isCurrent: Bool
    var calendar = Calendar.current

    @State private var metric = HeatMetric.tokens

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Flow(spacing: 12, lineSpacing: 6, spread: true) {
                        SectionTitle(String(localized: "heatmap.yearTitle", bundle: .tacho))
                            .fixedSize()
                        Picker(String(localized: "heatmap.metric", bundle: .tacho), selection: $metric) {
                            ForEach(HeatMetric.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    DayGrid(days: maps.days, metric: metric, calendar: calendar)
                    HeatLegend(note: String(localized: "heatmap.quantileDays", bundle: .tacho))
                    if metric == .cost {
                        Text(String(localized: "heatmap.costNote", bundle: .tacho))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Flow(spacing: 12, lineSpacing: 6, spread: true) {
                        SectionTitle(String(localized: "heatmap.hoursTitle", bundle: .tacho))
                            .fixedSize()
                        Picker(String(localized: "overview.range", bundle: .tacho), selection: $range) {
                            ForEach(RangeChoice.longer) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    HourGrid(hours: maps.hourOfWeek, calendar: calendar)
                        .opacity(isCurrent ? 1 : 0.4)
                    HeatLegend(note: String(localized: "heatmap.quantileHours", bundle: .tacho))
                }
            }
            .padding(16)
        }
    }
}

/// A square of a grid, with the place it takes: `column` from the left, `row` from the top.
private struct HeatCell: Identifiable {
    var column: Int
    var row: Int
    var color: Color
    var label: String
    var readout: String

    var id: String { "\(column)-\(row)" }
}

/// The marks and hover shared by both grids. The y axis counts up, so that a row's place from the top is turned round here.
private struct CellGrid: View {
    private static let gap = 0.07
    private static let columnAxis = String(localized: "heatmap.columnAxis", bundle: .tacho)
    private static let rowAxis = String(localized: "heatmap.rowAxis", bundle: .tacho)

    let cells: [HeatCell]
    let columns: Int
    let rows: Int
    /// Where the column labels go, by column.
    let columnLabels: [(column: Double, text: String)]
    /// Where the row labels go, by row from the top.
    let rowLabels: [(row: Int, text: String)]
    let height: CGFloat

    @State private var hovered: HeatCell?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(cells) { cell in
                    mark(cell, inset: Self.gap)
                        .foregroundStyle(cell.color)
                        .cornerRadius(2)
                        .accessibilityLabel(cell.label)
                        .accessibilityValue(cell.readout)
                }
                if let hovered {
                    mark(hovered, inset: 0)
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .cornerRadius(2)
                }
            }
            .chartXScale(domain: 0...Double(columns))
            .chartYScale(domain: 0...Double(rows))
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(position: .top, values: columnLabels.map(\.column)) { value in
                    AxisValueLabel(anchor: .bottomLeading) {
                        // Primary: an axis label is already dimmed, and secondary on top of that is too faint to read.
                        Text(columnLabels.first { $0.column == value.as(Double.self) }?.text ?? "")
                            .font(.caption2)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: rowLabels.map { Double(rows - $0.row) - 0.5 }) { value in
                    AxisValueLabel {
                        Text(rowLabels.first { Double(rows - $0.row) - 0.5 == value.as(Double.self) }?.text ?? "")
                            .font(.caption2)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): hovered = cell(at: location, proxy: proxy, geometry: geometry)
                            case .ended: hovered = nil
                            }
                        }
                }
            }
            .frame(height: height)

            // The same height with or without a square under the pointer, so that the page does not shift.
            Text(hovered?.readout ?? String(localized: "heatmap.hint", bundle: .tacho))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(hovered == nil ? .secondary : .primary)
        }
    }

    private func mark(_ cell: HeatCell, inset: Double) -> RectangleMark {
        RectangleMark(
            xStart: .value(Self.columnAxis, Double(cell.column) + inset),
            xEnd: .value(Self.columnAxis, Double(cell.column + 1) - inset),
            yStart: .value(Self.rowAxis, Double(rows - cell.row - 1) + inset),
            yEnd: .value(Self.rowAxis, Double(rows - cell.row) - inset)
        )
    }

    private func cell(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> HeatCell? {
        guard let plot = proxy.plotFrame.map({ geometry[$0] }) else { return nil }
        let point = CGPoint(x: location.x - plot.minX, y: location.y - plot.minY)
        guard let (x, y) = proxy.value(at: point, as: (Double, Double).self) else { return nil }
        let column = Int(x.rounded(.down))
        let row = rows - 1 - Int(y.rounded(.down))
        return cells.first { $0.column == column && $0.row == row }
    }
}

/// Each month's name above the week it starts in, or as near as leaves it room: Charts cuts a label short at the plot's edge.
enum MonthLabels {
    /// Columns a name needs at the narrowest window.
    private static let room = 3

    /// - Parameter calendar: with the locale that names the months.
    static func of(_ days: [DayCell], offset: Int, columns: Int, calendar: Calendar) -> [(column: Double, text: String)] {
        var labels: [(column: Double, text: String)] = []
        for (index, day) in days.enumerated() where calendar.component(.day, from: day.day) == 1 {
            let month = calendar.component(.month, from: day.day)
            labels.append((Double(min((index + offset) / 7, columns - room)), calendar.shortMonthSymbols[month - 1]))
        }
        return labels
    }
}

/// The last 365 days, a column to a week.
private struct DayGrid: View {
    let days: [DayCell]
    let metric: HeatMetric
    let calendar: Calendar

    private var offset: Int {
        guard let first = days.first else { return 0 }
        return (calendar.component(.weekday, from: first.day) - calendar.firstWeekday + 7) % 7
    }

    private var cells: [HeatCell] {
        let scale = HeatScale(days.map(metric.value))
        return days.enumerated().map { index, day in
            let place = index + offset
            let name = day.day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Labels.locale))
            let cost = WindowLabels.dayCost(day)
            return HeatCell(
                column: place / 7,
                row: place % 7,
                color: scale.color(of: metric.value(of: day)),
                label: name,
                readout: String(format: String(localized: "heatmap.dayReadout", bundle: .tacho), name, TokenFormat.compact(day.tokens), cost)
            )
        }
    }

    var body: some View {
        CellGrid(
            cells: cells,
            columns: 53,
            rows: 7,
            columnLabels: MonthLabels.of(days, offset: offset, columns: 53, calendar: named(calendar)),
            rowLabels: [0, 2, 4, 6].map { ($0, weekday(atRow: $0, calendar: calendar)) },
            height: 150
        )
    }
}

/// Seven rows of 24 hours, starting on the calendar's first weekday as `Heatmaps.hourOfWeek` does.
private struct HourGrid: View {
    let hours: [[Int]]
    let calendar: Calendar

    private var cells: [HeatCell] {
        let scale = HeatScale(hours.flatMap { $0.map(Double.init) })
        return hours.enumerated().flatMap { row, tokens in
            tokens.enumerated().map { hour, tokens in
                let name = String(format: "%@ %02ld:00", weekday(atRow: row, calendar: calendar), hour)
                return HeatCell(
                    column: hour,
                    row: row,
                    color: scale.color(of: Double(tokens)),
                    label: name,
                    readout: String(format: String(localized: "heatmap.hourReadout", bundle: .tacho), name, TokenFormat.compact(tokens))
                )
            }
        }
    }

    var body: some View {
        CellGrid(
            cells: cells,
            columns: 24,
            rows: 7,
            columnLabels: [0, 6, 12, 18].map { (Double($0), String(format: "%02ld:00", $0)) },
            rowLabels: (0..<7).map { ($0, weekday(atRow: $0, calendar: calendar)) },
            height: 200
        )
    }
}

private func weekday(atRow row: Int, calendar: Calendar) -> String {
    named(calendar).shortWeekdaySymbols[(calendar.firstWeekday - 1 + row) % 7]
}

/// `calendar`, for its names only. Which weekday comes first stays the region's, as the engine counts it, so that is read from `calendar` itself.
private func named(_ calendar: Calendar) -> Calendar {
    var named = calendar
    named.locale = Labels.locale
    return named
}

/// Says what the shades mean, in words as well as colour. Its three parts go onto separate lines when the page is narrow.
private struct HeatLegend: View {
    let note: String

    var body: some View {
        Flow(spacing: 14, lineSpacing: 4) {
            HStack(spacing: 4) {
                swatch(HeatScale.empty)
                Text(String(localized: "heatmap.none", bundle: .tacho))
            }
            .fixedSize()
            HStack(spacing: 4) {
                Text(String(localized: "heatmap.less", bundle: .tacho))
                ForEach(HeatScale.shades.indices, id: \.self) { swatch(HeatScale.shades[$0]) }
                Text(String(localized: "heatmap.more", bundle: .tacho))
            }
            .fixedSize()
            Text(note)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func swatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 11, height: 11)
    }
}
