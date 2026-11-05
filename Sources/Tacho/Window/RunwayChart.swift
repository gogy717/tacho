import Charts
import SwiftUI
import TachoKit

/// How a limit's window has gone, and where it is heading: spec section 12.5.
struct Runway: Equatable {
    enum Forecast: Equatable {
        case none
        /// Runs out at this time, before the reset.
        case empties(at: Date)
        /// Reaches this percent at the reset.
        case reaches(percent: Double)
    }

    struct Point: Equatable {
        var time: Date
        var percent: Double
    }

    var start: Date
    var reset: Date
    var now: Date
    /// From the start of the window to now.
    var used: [Point]
    /// With its readings in, each step is a real one. Without them, steps would claim all the use came at once, just now.
    var hasReadings: Bool
    var forecast: Forecast
}

extension Runway {
    /// - Parameter history: the window's readings, oldest first; none yet is a line from its start to now.
    init(_ projection: Projection, history: [LimitHistory.Reading] = [], now: Date) {
        let start = projection.resetsAt.addingTimeInterval(-projection.snapshot.window.length)
        let forecast: Forecast = switch projection.outcome {
        case .runsOut(let at, _): .empties(at: at)
        case .lastsUntilReset:
            projection.pacePercentPerHour.map {
                .reaches(percent: min(100, projection.estimatedPercent + $0 * projection.resetsAt.timeIntervalSince(now) / 3_600))
            } ?? .none
        case .idle, .unknown: .none
        }
        self.init(
            start: start,
            reset: projection.resetsAt,
            now: now,
            used: [Point(time: start, percent: 0)]
                + history.map { Point(time: $0.time, percent: $0.percent) }
                + [Point(time: now, percent: projection.estimatedPercent)],
            hasReadings: !history.isEmpty,
            forecast: projection.isUsedUp ? .none : forecast
        )
    }
}

struct RunwayChart: View {
    private static let timeAxis = String(localized: "chart.hour", bundle: .tacho)
    private static let percentAxis = String(localized: "chart.value", bundle: .tacho)
    private static let series = String(localized: "chart.category", bundle: .tacho)

    private static let lineWidth: CGFloat = 2.4
    private static let pointSize: CGFloat = 50

    let runway: Runway
    /// Summary's small chart leaves out the 50 line.
    var showsMiddle = true
    let label: String

    private var gridlines: [Double] {
        showsMiddle ? [0, 50, 100] : [0, 100]
    }

    var body: some View {
        Chart {
            ForEach(gridlines, id: \.self) { line in
                RuleMark(y: .value(Self.percentAxis, line))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color(nsColor: .separatorColor))
            }
            if case .empties(let at) = runway.forecast {
                RectangleMark(
                    xStart: .value(Self.timeAxis, at),
                    xEnd: .value(Self.timeAxis, runway.reset),
                    yStart: .value(Self.percentAxis, 0),
                    yEnd: .value(Self.percentAxis, 100)
                )
                .foregroundStyle(Theme.amberWash)
            }
            ForEach(runway.used.indices, id: \.self) { index in
                LineMark(
                    x: .value(Self.timeAxis, runway.used[index].time),
                    y: .value(Self.percentAxis, runway.used[index].percent),
                    series: .value(Self.series, "used")
                )
                .interpolationMethod(runway.hasReadings ? .stepEnd : .linear)
                .lineStyle(StrokeStyle(lineWidth: Self.lineWidth, lineJoin: .round))
                .foregroundStyle(Color.accentColor)
            }
            forecastMarks
            RuleMark(x: .value(Self.timeAxis, runway.now))
                .lineStyle(StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(.secondary)
            if let last = runway.used.last {
                PointMark(x: .value(Self.timeAxis, last.time), y: .value(Self.percentAxis, last.percent))
                    .symbolSize(Self.pointSize)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .chartXScale(domain: runway.start...runway.reset)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    @ChartContentBuilder private var forecastMarks: some ChartContent {
        if let last = runway.used.last {
            switch runway.forecast {
            case .none:
                EmptyChartContent()
            case .empties(let at):
                forecastLine(from: last, to: Runway.Point(time: at, percent: 100), color: Theme.amberFill)
                PointMark(x: .value(Self.timeAxis, at), y: .value(Self.percentAxis, 100))
                    .symbolSize(Self.pointSize)
                    .foregroundStyle(Theme.amberFill)
            case .reaches(let percent):
                forecastLine(from: last, to: Runway.Point(time: runway.reset, percent: percent), color: .secondary)
            }
        }
    }

    @ChartContentBuilder private func forecastLine(from: Runway.Point, to: Runway.Point, color: Color) -> some ChartContent {
        ForEach([from, to].indices, id: \.self) { index in
            let point = index == 0 ? from : to
            LineMark(
                x: .value(Self.timeAxis, point.time),
                y: .value(Self.percentAxis, point.percent),
                series: .value(Self.series, "forecast")
            )
            .lineStyle(StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, dash: [5, 5]))
            .foregroundStyle(color)
        }
    }
}

/// Charts has no empty content of its own to return from one branch of a switch.
private struct EmptyChartContent: ChartContent {
    var body: some ChartContent {
        RuleMark(y: .value("", 0)).opacity(0)
    }
}
