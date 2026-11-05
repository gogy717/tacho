import Charts
import SwiftUI
import TachoKit

/// The Speed page, already worded.
struct SpeedState: Equatable {
    struct Point: Equatable {
        var label: String
        /// What the axis says here, if anything.
        var axis: String?
        /// nil with no samples: the column keeps its place on the axis, with nothing to plot.
        var tokensPerSecond: Double?
    }

    struct Choice: Equatable, Identifiable {
        var id: String
        var name: String
    }

    var stats: [Stat] = []
    /// Fewer than 2 to plot draw no line.
    var points: [Point]?
    var usual: ClosedRange<Double>?
    /// The models to choose between, most samples first.
    var choices: [Choice] = []
    var chosen: String?
    /// The P rule, when the engine's answer is about the chosen model.
    var highlights: [String] = []
    var models: [FigureRow] = []
    /// Some of the chosen model's requests were timed by an approximate start, so its chart is approximate too.
    var isApproximate = false
}

extension SpeedState {
    /// What stays chosen once `figures` are in. `Engine.speed` draws the model it was asked for while `models` lists only those with
    /// samples, so a model gone from the range would leave its chart under another's figures: it is let go, and the page asks again.
    static func keptChoice(_ chosen: String?, in figures: SpeedFigures) -> String? {
        figures.models.contains { $0.speed.model == chosen } ? chosen : nil
    }

    /// - Parameters:
    ///   - chosen: the model the figures are for; nil or gone from the range, the one with the most samples.
    ///   - isReading: older logs are still coming in, so no day can be called missing.
    ///   - insight: the engine's answer for its own choice of model.
    init(figures: SpeedFigures, chosen: String?, isReading: Bool = false, insight: SpeedInsight? = nil, calendar: Calendar = .current) {
        let model = figures.models.first { $0.speed.model == chosen } ?? figures.models.first
        self.init(
            stats: model.map { Self.stats($0, todayHasUse: figures.todayHasUse, isReading: isReading) } ?? [],
            points: figures.columns.enumerated().map { index, column in
                Point(
                    label: WindowLabels.columnLabel(column.start, range: figures.range, calendar: calendar),
                    axis: WindowLabels.axisLabel(column.start, index: index, range: figures.range, calendar: calendar),
                    tokensPerSecond: column.tokensPerSecond
                )
            },
            usual: figures.range == .week || figures.range == .month ? model?.usual?.closed : nil,
            choices: figures.models.map { Choice(id: $0.speed.model, name: Labels.modelShort($0.speed.model)) },
            chosen: model?.speed.model,
            highlights: insight.flatMap { $0.model == model?.speed.model ? [Labels.say($0.rule, model: $0.model)] : nil } ?? [],
            models: figures.models.map {
                FigureRow(
                    name: Labels.modelShort($0.speed.model),
                    figure: Labels.speed($0.speed),
                    fraction: nil,
                    note: WindowLabels.requests($0.speed.samples)
                )
            },
            isApproximate: model?.speed.approximate ?? false
        )
    }

    /// What a column holds, under the pointer. nil with no samples there.
    func readout(of point: Point) -> String? {
        point.tokensPerSecond.map {
            String(format: String(localized: "rate.menu.item", bundle: .tacho), point.label, Labels.tokensPerSecond($0, approximate: isApproximate))
        }
    }

    /// `≈ 60 to 80 tok/s`: marked once, at the front, since all of it is approximate and not only its top.
    private static func usualRange(_ range: UsualRange, approximate: Bool) -> String {
        let figures = String(format: String(localized: "stat.usualRange", bundle: .tacho), "\(Int(range.p25.rounded()))", Labels.tokensPerSecond(range.p75, approximate: false))
        return approximate ? String(format: String(localized: "quota.approximate", bundle: .tacho), figures) : figures
    }

    private static func stats(_ model: SpeedFigures.Model, todayHasUse: Bool, isReading: Bool) -> [Stat] {
        let usual: String = if let range = model.usual {
            Self.usualRange(range, approximate: model.speed.approximate)
        } else {
            WindowLabels.needsDays(model.speedDays, todayHasUse: todayHasUse, isReading: isReading)
        }
        return [
            Stat(label: String(localized: "stat.median", bundle: .tacho), value: Labels.speed(model.speed)),
            Stat(label: String(localized: "stat.usual", bundle: .tacho), value: usual),
            Stat(label: String(localized: "stat.samples", bundle: .tacho), value: model.speed.samples.formatted()),
        ]
    }
}

/// How fast each model writes: spec section 12.6.
struct SpeedPage: View {
    /// What the figures were asked for. A model of `""` is not the same as none: clearing it must restart the task.
    private struct Asked: Equatable {
        var range: DetailRange
        var model: String?
        var epoch: Int
    }

    private static let refreshInterval: Duration = .seconds(60)

    let model: AppModel
    var read: SpeedRead?

    @State private var range = DetailRange.week
    @State private var chosen: String?
    @State private var figures: Loaded<SpeedFigures> = .loading
    @State private var insight: SpeedInsight?
    /// The models to choose from as the last figures had them, and the one on the page: the picker keeps these while the next figures
    /// are read, rather than going blank and coming back around a click.
    @State private var choices: [SpeedState.Choice] = []
    @State private var shownChoice: String?

    private var state: SpeedState {
        guard case .ready(let figures) = figures else { return SpeedState() }
        return SpeedState(figures: figures, chosen: chosen, isReading: model.isReadingLogs, insight: insight)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageControls {
                RangePicker(selection: $range)
                Picker(String(localized: "log.model", bundle: .tacho), selection: Binding(get: { shownChoice ?? "" }, set: { picked in
                    shownChoice = picked
                    chosen = picked
                })) {
                    ForEach(choices) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(choices.isEmpty)
            }
            switch figures {
            case .loading: HeldPlaceholder(kind: .detail)
            case .failed: ProblemNote(model: model)
            case .ready(let latest):
                FigureFade(value: latest) {
                    SpeedContent(state: state)
                }
                .preference(
                    key: ShownAskKey.self,
                    value: ShownAsk(page: .speed, range: latest.range.rawValue, marker: latest.models.first?.speed.model ?? "")
                )
            }
        }
            .onChange(of: model.pendingRoute, initial: true) {
                guard let route = model.takeRoute(for: .speed) else { return }
                if let asked = route.range { range = asked }
                if let asked = route.model { chosen = asked }
            }
            .task(id: Asked(range: range, model: chosen, epoch: model.figuresEpoch)) {
                // A miss shows nothing of the previous range or model. A hit shows that ask's own last answer.
                let ask = FigureAsk(page: .speed, range: range, model: chosen)
                if case .speed(let cached) = model.remembered(ask), cached.range == range {
                    figures = .ready(cached)
                    keepChoices(of: cached)
                } else {
                    figures = .loading
                }
                await model.whileShowing(.speed, every: Self.refreshInterval) { await load() }
            }
    }

    private func load() async {
        var latest = try? await model.speed(range, model: chosen, via: read)
        guard !Task.isCancelled else { return }
        let isGone = latest.map { chosen != nil && SpeedState.keptChoice(chosen, in: $0) == nil } ?? false
        var answeredModel = chosen
        if isGone {
            // Read again here: clearing it does not always restart this task. A route sets `chosen` before the first read,
            // so clearing it can put the task's id back where it began, and the page would wait for the next tick.
            chosen = nil
            answeredModel = nil
            latest = try? await model.speed(range, model: nil, via: read)
            guard !Task.isCancelled else { return }
        }
        guard let latest else {
            figures = .failed
            insight = try? await model.engine?.speedInsight(model: chosen, now: Date())
            return
        }
        model.remember(.speed(latest), for: FigureAsk(page: .speed, range: range, model: answeredModel))
        if figures != .ready(latest) { figures = .ready(latest) }
        keepChoices(of: latest)
        // The rule is for the model on screen, not for whichever model a card named.
        insight = try? await model.engine?.speedInsight(model: chosen ?? latest.models.first?.speed.model, now: Date())
    }

    private func keepChoices(of figures: SpeedFigures) {
        let shown = SpeedState(figures: figures, chosen: chosen, isReading: model.isReadingLogs, insight: insight)
        if choices != shown.choices { choices = shown.choices }
        if shownChoice != shown.chosen { shownChoice = shown.chosen }
    }
}

struct SpeedContent: View {
    private static let timeAxis = String(localized: "chart.hour", bundle: .tacho)
    private static let speedAxis = String(localized: "chart.value", bundle: .tacho)

    @State private var selection: String?

    let state: SpeedState

    /// Under the pointer: what that column holds.
    private var readout: String {
        state.points?.first { $0.label == selection }.flatMap(state.readout(of:)) ?? " "
    }

    var body: some View {
        PageBody {
            TwoColumns(weight: 1.75) {
                VStack(alignment: .leading, spacing: 8) {
                    StatRow(stats: state.stats)
                    if let points = state.points {
                        if points.compactMap(\.tokensPerSecond).count >= 2 {
                            chart(points)
                            Text(readout)
                                .font(Theme.Style.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text(String(localized: "speed.few", bundle: .tacho))
                                .font(Theme.Style.small)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 300)
                        }
                    }
                }
            } right: {
                VStack(alignment: .leading, spacing: 14) {
                    HighlightList(sentences: state.highlights)
                    FigureList(title: String(localized: "speed.models", bundle: .tacho), rows: state.models)
                    AboutBox(text: String(localized: "about.speed", bundle: .tacho))
                }
            }
        }
    }

    private func chart(_ points: [SpeedState.Point]) -> some View {
        let plotted = points.compactMap { point in point.tokensPerSecond.map { (label: point.label, speed: $0) } }
        return Chart {
            if let usual = state.usual {
                RectangleMark(yStart: .value(Self.speedAxis, usual.lowerBound), yEnd: .value(Self.speedAxis, usual.upperBound))
                    .foregroundStyle(Theme.well)
            }
            ForEach(plotted.indices, id: \.self) { index in
                LineMark(x: .value(Self.timeAxis, plotted[index].label), y: .value(Self.speedAxis, plotted[index].speed))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Color.primary)
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: $selection)
        .chartXScale(domain: points.map(\.label))
        .chartXAxis {
            AxisMarks(values: points.filter { $0.axis != nil }.map(\.label)) { value in
                AxisValueLabel {
                    Text(points.first { $0.label == value.as(String.self) }?.axis ?? "")
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .frame(height: 300)
    }
}
