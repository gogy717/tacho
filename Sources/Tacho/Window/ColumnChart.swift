import Charts
import SwiftUI
import TachoKit

/// What a detail page's chart draws, already in plain values.
struct ColumnSeries: Equatable {
    struct Layer: Equatable {
        var name: String
        var color: Color
    }

    struct Column: Equatable, Identifiable {
        /// Unique in the chart: the axis is one of categories, so that columns can take their room.
        var id: String
        /// What the axis says here, if anything.
        var axis: String?
        /// The hover line: `Tue · $126`.
        var readout: String
        /// One for each of `layers`, bottom first.
        var values: [Double]
        /// This column's own usual range, on a Day chart.
        var usual: ClosedRange<Double>?
    }

    var layers: [Layer]
    var columns: [Column]
    /// One usual range for the whole chart. nil for none.
    var usual: ClosedRange<Double>?
    /// How the trailing axis words a value.
    var isMoney: Bool
}

/// Columns with the usual range behind them: spec section 12.1.
struct ColumnChart: View {
    private static let columnAxis = String(localized: "chart.category", bundle: .tacho)
    private static let valueAxis = String(localized: "chart.value", bundle: .tacho)

    private struct Segment: Identifiable {
        var column: String
        var layer: String
        var value: Double

        var id: String { column + layer }
    }

    @State private var selection: String?

    let series: ColumnSeries
    var height: CGFloat = 300

    private var segments: [Segment] {
        series.columns.flatMap { column in
            zip(series.layers, column.values).map { Segment(column: column.id, layer: $0.name, value: $1) }
        }
    }

    private var hasBand: Bool {
        series.usual != nil || series.columns.contains { $0.usual != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chart.frame(height: height)
            legend
        }
    }

    private var chart: some View {
        Chart {
            if let usual = series.usual {
                RectangleMark(yStart: .value(Self.valueAxis, usual.lowerBound), yEnd: .value(Self.valueAxis, usual.upperBound))
                    .foregroundStyle(Theme.well)
            }
            ForEach(series.columns) { column in
                if let usual = column.usual {
                    AreaMark(
                        x: .value(Self.columnAxis, column.id),
                        yStart: .value(Self.valueAxis, usual.lowerBound),
                        yEnd: .value(Self.valueAxis, usual.upperBound)
                    )
                    .interpolationMethod(.stepCenter)
                    .foregroundStyle(Theme.well)
                }
            }
            ForEach(segments) { segment in
                BarMark(x: .value(Self.columnAxis, segment.column), y: .value(Self.valueAxis, segment.value), stacking: .standard)
                    .cornerRadius(1.5)
                    .foregroundStyle(by: .value(Self.columnAxis, segment.layer))
            }
        }
        .chartForegroundStyleScale(domain: series.layers.map(\.name), range: series.layers.map(\.color))
        .chartLegend(.hidden)
        .chartXSelection(value: $selection)
        .chartXAxis {
            AxisMarks(values: series.columns.filter { $0.axis != nil }.map(\.id)) { value in
                AxisValueLabel {
                    Text(series.columns.first { $0.id == value.as(String.self) }?.axis ?? "")
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(series.isMoney ? (number == 0 ? "$0" : TokenFormat.usd(number)) : TokenFormat.compact(Int(number)))
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(series.columns.map(\.readout).joined(separator: ", "))
    }

    /// The names, or under the pointer what that column holds.
    @ViewBuilder private var legend: some View {
        if let selection, let column = series.columns.first(where: { $0.id == selection }) {
            Text(column.readout)
                .font(Theme.Style.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            CategoryLegend(layers: series.layers, bandNote: hasBand ? String(localized: "detail.bandLegend", bundle: .tacho) : nil)
        }
    }
}

/// The swatches of a stack, in its order, since colour alone says nothing to some. They go onto a second line in a narrow column.
struct CategoryLegend: View {
    let layers: [ColumnSeries.Layer]
    var bandNote: String?

    var body: some View {
        Flow(spacing: 12, lineSpacing: 3) {
            ForEach(layers, id: \.name) { layer in
                // A model's id can be longer than the column, so a name wraps.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Swatch(color: layer.color)
                    Text(layer.name)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let bandNote {
                Text(bandNote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Theme.Style.caption)
        .foregroundStyle(.secondary)
    }
}

/// Type, Model, CLI: what the page's chart stacks by.
struct GroupingPicker: View {
    @Binding var selection: DetailGrouping?

    var body: some View {
        Picker(String(localized: "chart.grouping", bundle: .tacho), selection: $selection) {
            Text(String(localized: "chart.byType", bundle: .tacho)).tag(DetailGrouping?.none)
            Text(String(localized: "chart.byModel", bundle: .tacho)).tag(DetailGrouping?.some(.model))
            Text(String(localized: "chart.byCLI", bundle: .tacho)).tag(DetailGrouping?.some(.source))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// Which colour each model or CLI has. A colour follows the model and not its place: the stack reorders by size, and a colour that moved with it
/// would say the models had swapped. Once given, a colour stays through ranges and pages, and is taken back only when a newcomer needs one and
/// none is free, from whatever has been off the charts longest.
final class LayerColours {
    private let count: Int
    private var slots: [String: Int] = [:]
    private var lastShown: [String: Int] = [:]
    private var clock = 0

    init(count: Int = Theme.series.count) {
        self.count = count
    }

    /// The slot in `Theme.series` of each of `keys`, which are what one chart is showing: at most `count` of them.
    func slots(for keys: [String]) -> [String: Int] {
        clock += 1
        for key in keys {
            if slots[key] == nil { slots[key] = freeSlot(leaving: keys) }
            lastShown[key] = clock
        }
        return slots.filter { keys.contains($0.key) }
    }

    /// The first slot nothing holds, or else the one held longest off the charts.
    private func freeSlot(leaving keys: [String]) -> Int {
        let taken = Set(slots.values)
        if let free = (0..<count).first(where: { !taken.contains($0) }) { return free }
        let gone = slots.keys.filter { !keys.contains($0) }.min { (lastShown[$0] ?? 0, $0) < (lastShown[$1] ?? 0, $1) }
        return gone.flatMap { slots.removeValue(forKey: $0) } ?? 0
    }
}

/// What the chart pages keep for the session, as the pages themselves come and go.
@MainActor @Observable
final class ChartSession {
    private var groupings: [Page: DetailGrouping] = [:]
    /// Written while a page is drawn, so nothing may watch it.
    @ObservationIgnored private var colours: [DetailGrouping: LayerColours] = [:]

    func grouping(on page: Page) -> DetailGrouping? {
        groupings[page]
    }

    func setGrouping(_ grouping: DetailGrouping?, on page: Page) {
        groupings[page] = grouping
    }

    /// One for each grouping, shared by the pages: a model and a CLI are never on one chart.
    func colours(for grouping: DetailGrouping) -> LayerColours {
        if let known = colours[grouping] { return known }
        let made = LayerColours()
        colours[grouping] = made
        return made
    }
}
