import Charts
import SwiftUI

/// The last hour, one step a minute: spec §3.4. The newest step is the minute under way.
///
/// Equatable, for `.equatable()`: the panel's body runs on every 1 s tick, and a chart of up to 240 marks must not rebuild when no figure
/// has changed.
struct MinuteChart: View, Equatable {
    private static let minuteAxis = String(localized: "chart.minute", bundle: .tacho)
    private static let valueAxis = String(localized: "chart.value", bundle: .tacho)
    private static let layerAxis = String(localized: "chart.category", bundle: .tacho)

    struct Layer: Equatable, Identifiable {
        var name: String
        var color: Color

        var id: String { name }
    }

    private struct Segment: Identifiable {
        var minute: Int
        var layer: String
        var value: Double

        var id: String { "\(minute)-\(layer)" }
    }

    /// Oldest first, with a value for each of `layers`, which are bottom first.
    let series: [[Double]]
    let layers: [Layer]
    let label: String
    /// What an empty hour says. Cost mode with tokens but no price says that instead: `chart.noPrice`.
    var emptyText = String(localized: "chart.empty", bundle: .tacho)
    /// The minute under the pointer, as minutes before now, negative. nil when the pointer is elsewhere.
    @Binding var selection: Int?

    nonisolated static func == (left: MinuteChart, right: MinuteChart) -> Bool {
        left.series == right.series && left.layers == right.layers && left.label == right.label && left.emptyText == right.emptyText
    }

    /// Every layer at every minute, zeros included: a stack needs all its layers at each point.
    private var segments: [Segment] {
        series.enumerated().flatMap { index, values in
            zip(layers, values).map { layer, value in
                Segment(minute: index - series.count + 1, layer: layer.name, value: value)
            }
        }
    }

    private var isEmpty: Bool {
        series.allSatisfy { $0.allSatisfy { $0 == 0 } }
    }

    var body: some View {
        if isEmpty {
            Text(emptyText)
                .font(Theme.Style.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(segments) { segment in
                    AreaMark(x: .value(Self.minuteAxis, segment.minute), y: .value(Self.valueAxis, segment.value), stacking: .standard)
                        .interpolationMethod(.stepCenter)
                        .foregroundStyle(by: .value(Self.layerAxis, segment.layer))
                }
                RuleMark(y: .value(Self.valueAxis, 0))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color(nsColor: .separatorColor))
            }
            .chartForegroundStyleScale(domain: layers.map(\.name), range: layers.map(\.color))
            .chartXScale(domain: -59.5...0.5)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartXSelection(value: $selection)
            .accessibilityElement()
            .accessibilityLabel(label)
        }
    }
}
