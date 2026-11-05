import Charts
import SwiftUI

/// A day against the usual range. `hour` is hours since local midnight, 0 to 24.
struct UsualRangeSeries: Equatable {
    struct Band: Equatable {
        var hour: Double
        var low: Double
        var high: Double
    }

    struct Point: Equatable {
        var hour: Double
        var value: Double
    }

    var band: [Band] = []
    var line: [Point] = []

    /// Always the whole day, whatever the hour: a quiet morning sits low on the chart, and that is true.
    var top: Double {
        let highest = max(line.map(\.value).max() ?? 0, band.last?.high ?? 0)
        return highest > 0 ? highest * 1.05 : 1
    }

    /// Where today has got to.
    var now: Point? { line.last }
}

/// Tacho's chart of a day: the usual range as a band, today as a line, and a mark where it stands now. Spec §3.3.
///
/// Equatable, for `.equatable()`, so that a tick with no new figure does not rebuild its 96 marks.
struct UsualRangeChart: View, Equatable {
    private static let hourAxis = String(localized: "chart.hour", bundle: .tacho)
    private static let valueAxis = String(localized: "chart.value", bundle: .tacho)

    let series: UsualRangeSeries
    /// What the chart shows, for VoiceOver. The figures stay in the text beside it.
    let label: String
    /// `.primary`; the Output colour when a card has fallen back to output.
    var lineColor = Color.primary

    var body: some View {
        Chart {
            ForEach(series.band.indices, id: \.self) { index in
                let point = series.band[index]
                AreaMark(x: .value(Self.hourAxis, point.hour), yStart: .value(Self.valueAxis, point.low), yEnd: .value(Self.valueAxis, point.high))
                    .interpolationMethod(.linear)
                    .foregroundStyle(Theme.well)
            }
            ForEach(series.line.indices, id: \.self) { index in
                let point = series.line[index]
                LineMark(x: .value(Self.hourAxis, point.hour), y: .value(Self.valueAxis, point.value))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(lineColor)
            }
            if let now = series.now {
                PointMark(x: .value(Self.hourAxis, now.hour), y: .value(Self.valueAxis, now.value))
                    .symbolSize(36)
                    .foregroundStyle(lineColor)
            }
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: 0...series.top)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityElement()
        .accessibilityLabel(label)
    }
}
