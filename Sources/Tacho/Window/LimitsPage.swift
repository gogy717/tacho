import Charts
import SwiftUI
import TachoKit

/// A limit's record, with the limit it was read for.
struct LimitRecord {
    var limit: LimitKey
    var history: LimitHistory

    init(of limit: Projection, history: LimitHistory) {
        self.limit = LimitKey(limit.snapshot)
        self.history = history
    }
}

/// How a page reads a limit's record, for a test to stand in.
typealias LimitRead = @MainActor (QuotaSnapshot) async throws -> LimitHistory?

/// The Limits page, already worded.
struct LimitsState: Equatable {
    struct Row: Equatable, Identifiable {
        var key: LimitKey
        var name: String
        /// nil with no recent figure to show.
        var percent: String?
        var value: Double
        /// Where use would be at an even pace.
        var pace: Double?
        var level: Meter.Level
        /// Said in place of the bar.
        var message: String?

        var id: LimitKey { key }
    }

    struct How: Equatable, Identifiable {
        var label: String
        var value: String

        var id: String { label }
    }

    var rows: [Row] = []
    var selected: LimitKey?
    /// The toolbar's subtitle.
    var selectedName: String?
    var stats: [Stat] = []
    var runway: Runway?
    /// The limit's recorded windows, oldest first, the current one last.
    var windows: [LimitHistory.Window] = []
    /// Under the runway, left to right.
    var captions: [String] = []
    /// Said in place of the charts: nothing to draw for this limit.
    var message: String?
    /// There are no readings because the query is off: L7.
    var offersSettings = false
    var highlights: [String] = []
    var how: [How] = []
    /// CLIs with no quota to forecast, and what they spend instead. Spec goal 6.
    var noQuota: [FigureRow] = []
}

extension LimitsState {
    /// The limit the page is about: what the person picked; else the one the rules name; else the first with recent data. The figures'
    /// own row wherever there is one, as that moves on with the tick, where the rules' answer is only as new as the last read.
    static func chosen(of quotas: [Projection], selected: LimitKey?, insights: LimitsInsight?) -> Projection? {
        func row(_ key: LimitKey) -> Projection? { quotas.first { LimitKey($0.snapshot) == key } }
        return selected.flatMap(row)
            ?? insights?.limit.map { row(LimitKey($0.snapshot)) ?? $0 }
            ?? quotas.first(where: \.hasRecentData)
    }

    /// - Parameters:
    ///   - selected: what the person picked; else the most urgent.
    ///   - record: the last one read, once it is in.
    init(
        dashboard: Dashboard,
        insights: LimitsInsight?,
        selected: LimitKey?,
        record: LimitRecord?,
        now: Date,
        calendar: Calendar = .current
    ) {
        let quotas = dashboard.quotas
        let chosen = Self.chosen(of: quotas, selected: selected, insights: insights)
        self.init(
            rows: quotas.map { Self.row($0, now: now) },
            selected: chosen.map { LimitKey($0.snapshot) },
            selectedName: chosen.map { Labels.limitName($0.snapshot) },
            noQuota: dashboard.sources.filter { !$0.hasQuota && $0.today.total > 0 }.map {
                FigureRow(name: $0.source.displayName, figure: Labels.hourlyCost($0.costLastHour), fraction: nil)
            }
        )
        guard let chosen else {
            message = insights.flatMap { Labels.limitSay($0, now: now, calendar: calendar).0 }
            offersSettings = insights?.rule == .l7
            return
        }
        // A click moves the page on before the new limit's record is read.
        let history = record?.limit == LimitKey(chosen.snapshot) ? record?.history : nil
        // The right column stays with no recent data: only the stats and charts go.
        how = Self.how(chosen, now: now)
        // L1 is about the limit on the page, which may not be the one the rules picked.
        let usedUp = chosen.isUsedUp ? Labels.limitSay(LimitsInsight(rule: .l1, limit: chosen), now: now, calendar: calendar).0 : nil
        highlights = [usedUp].compactMap { $0 } + (history?.highlights(for: chosen) ?? []).map(WindowLabels.sentence)
        guard chosen.hasRecentData else {
            message = Self.noRecent(chosen, now: now)
            return
        }
        stats = Self.stats(chosen, now: now, calendar: calendar)
        runway = Runway(chosen, history: history?.readings ?? [], now: now)
        windows = history?.windows ?? []
        captions = Self.captions(chosen, now: now, calendar: calendar)
    }

    private static func row(_ quota: Projection, now: Date) -> Row {
        // The engine's own warning first, as in the panel, so that a bar never disagrees with the icon.
        let level: Meter.Level = switch ProjectionEngine.alert([quota]) {
        case .red: .critical
        case .amber: .warning
        case .none: quota.isStale ? .stale : .normal
        }
        return Row(
            key: LimitKey(quota.snapshot),
            name: Labels.limitName(quota.snapshot),
            percent: Labels.percent(quota),
            value: quota.estimatedPercent / 100,
            pace: quota.isStale ? nil : quota.paceFraction(at: now),
            level: level,
            message: quota.hasRecentData ? nil : noRecent(quota, now: now)
        )
    }

    private static func noRecent(_ quota: Projection, now: Date) -> String {
        String(format: String(localized: "limit.noRecent", bundle: .tacho), Labels.ageShort(now.timeIntervalSince(quota.snapshot.observedAt)))
    }

    private static func stats(_ quota: Projection, now: Date, calendar: Calendar) -> [Stat] {
        var notes: [String] = []
        if quota.isStale { notes.append(String(localized: "quota.mayBeStale", bundle: .tacho)) }
        if quota.method == .windowAverage { notes.append(String(localized: "quota.windowAverage", bundle: .tacho)) }
        var stats = [Stat(
            label: String(localized: "stat.used", bundle: .tacho),
            value: Labels.percent(quota) ?? "",
            tone: quota.isUsedUp ? .critical : .plain,
            note: notes.isEmpty ? nil : notes.joined(separator: " · ")
        )]
        if case .runsOut(let at, _) = quota.outcome, !quota.isUsedUp {
            stats.append(Stat(
                label: String(localized: "stat.empties", bundle: .tacho),
                value: String(format: String(localized: "stat.emptiesValue", bundle: .tacho), Labels.reset(at, now: now, calendar: calendar)),
                tone: .warning
            ))
        }
        stats.append(Stat(label: String(localized: "stat.resets", bundle: .tacho), value: Labels.reset(quota.resetsAt, now: now, calendar: calendar)))
        return stats
    }

    private static func captions(_ quota: Projection, now: Date, calendar: Calendar) -> [String] {
        let start = quota.resetsAt.addingTimeInterval(-quota.snapshot.window.length)
        var captions = [
            String(format: String(localized: "limits.opens", bundle: .tacho), Labels.reset(start, now: now, calendar: calendar)),
            String(format: String(localized: "limits.now", bundle: .tacho), Labels.clock(now)),
        ]
        if case .runsOut(let at, _) = quota.outcome {
            captions.append(String(format: String(localized: "limits.short", bundle: .tacho), Labels.gap(from: at, to: quota.resetsAt)))
        }
        captions.append(String(format: String(localized: "limits.reset", bundle: .tacho), Labels.reset(quota.resetsAt, now: now, calendar: calendar)))
        return captions
    }

    private static func how(_ quota: Projection, now: Date) -> [How] {
        let snapshot = quota.snapshot
        let since: String
        // Moved on by the engine, whose clock this page's `now` can be a minute behind.
        if quota.resetsAt != snapshot.resetsAt {
            since = String(localized: "how.resetSince", bundle: .tacho)
        } else if quota.isEstimate {
            let gain = quota.estimatedPercent - snapshot.usedPercent
            since = String(format: String(localized: "how.sinceValue", bundle: .tacho), "\(Int(gain.rounded()))%")
        } else {
            since = String(localized: "how.noChange", bundle: .tacho)
        }
        var rows = [
            How(label: String(localized: "how.last", bundle: .tacho), value: String(
                format: String(localized: "how.lastValue", bundle: .tacho),
                "\(Int(snapshot.usedPercent.rounded()))%",
                Labels.duration(now.timeIntervalSince(snapshot.observedAt))
            )),
            How(label: String(localized: "how.from", bundle: .tacho), value: WindowLabels.origin(snapshot.origin)),
            How(label: String(localized: "how.since", bundle: .tacho), value: since),
            How(label: String(localized: "how.pace", bundle: .tacho), value: String(localized: quota.method == .calibrated ? "how.pace.recent" : "how.pace.window", bundle: .tacho)),
            How(label: String(localized: "how.method", bundle: .tacho), value: String(localized: quota.method == .calibrated ? "how.method.calibrated" : "how.method.window", bundle: .tacho)),
        ]
        if let plan = snapshot.plan {
            rows.append(How(label: String(localized: "how.plan", bundle: .tacho), value: plan))
        }
        return rows
    }
}

/// One limit in full, and all the others beside it: spec section 12.5.
struct LimitsPage: View {
    private static let refreshInterval: Duration = .seconds(60)
    private static let lookInterval: Duration = .seconds(1)

    let model: AppModel
    var read: LimitRead?

    @State private var selected: LimitKey?
    @State private var insight: LimitsInsight?
    @State private var record: LimitRecord?
    /// What is on screen. Like Summary's feed: a body that read the figures would lay the page out on most ticks.
    @State private var drawn: LimitsState?
    @State private var looks = PageLook()

    /// The page as the figures have it now. The body reads this only until the first look, so that the page opens with its figures.
    private var latest: LimitsState? {
        model.dashboard.map { dashboard in
            LimitsState(dashboard: dashboard, insights: insight, selected: selected, record: record, now: model.pageClock)
        }
    }

    private func look() {
        let latest = latest
        if latest != drawn { drawn = latest }
    }

    var body: some View {
        Group {
            if let state = drawn ?? latest {
                LimitsContent(state: state, now: model.pageClock, select: { selected = $0 }, openSettings: { model.page = .settings })
                    .navigationSubtitle(state.selectedName ?? "")
            } else {
                NoFigures(model: model)
            }
        }
        .onChange(of: model.pendingRoute, initial: true) {
            if let route = model.takeRoute(for: .limits), let asked = route.limit { selected = asked }
        }
        // A person's own change does not wait for the next look, nor does a window coming back.
        .onChange(of: selected) { look() }
        .onChange(of: model.mainWindowVisible) { if model.mainWindowVisible { look() } }
        // By what the page is about, not only by what was picked: that can move with nothing picked, or when the figures come back.
        .task(id: (drawn ?? latest)?.selected) {
            record = nil
            await model.whileShowing(.limits, every: Self.refreshInterval) { await load() }
        }
        .task {
            await model.whileShowing(.limits, every: Self.lookInterval) {
                if looks.isDue(model.pageInputs) { look() }
            }
        }
    }

    private func load() async {
        // A failed read costs only the sentences: the page has its figures from the dashboard.
        let answer = (try? await model.engine?.insights(now: Date()))?.results.limits
        let limit = LimitsState.chosen(of: model.dashboard?.quotas ?? [], selected: selected, insights: answer)
        let latest: LimitRecord? = if let limit, let history = try? await history(of: limit.snapshot) {
            LimitRecord(of: limit, history: history)
        } else {
            nil
        }
        guard !Task.isCancelled else { return }
        // Together, or for a moment the sentences would come from another limit's record.
        insight = answer
        record = latest
        // A read is news, and does not wait for the next look.
        look()
    }
}

extension LimitsPage {
    private func history(of snapshot: QuotaSnapshot) async throws -> LimitHistory? {
        if let read { return try await read(snapshot) }
        return try await model.engine?.limitHistory(of: snapshot, now: Date())
    }
}

struct LimitsContent: View {
    let state: LimitsState
    let now: Date
    let select: (LimitKey) -> Void
    let openSettings: () -> Void

    var body: some View {
        if state.rows.isEmpty {
            VStack(spacing: 12) {
                if let message = state.message {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if state.offersSettings {
                    Button(String(localized: "limits.openSettings", bundle: .tacho), action: openSettings)
                }
            }
            .padding(Theme.Size.pageInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PageBody {
                TwoColumns(weight: 1.75) {
                    left
                } right: {
                    right
                }
            }
        }
    }

    private var left: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = state.message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            StatRow(stats: state.stats)
            if let runway = state.runway {
                RunwayChart(runway: runway, label: String(localized: "chart.runway", bundle: .tacho))
                    .frame(height: 250)
                Flow(spacing: 8, lineSpacing: 2, spread: true) {
                    ForEach(state.captions.indices, id: \.self) { index in
                        Text(state.captions[index])
                            .fixedSize()
                    }
                }
                .font(Theme.Style.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            RecentWindows(windows: state.windows, now: now)
                .padding(.top, 8)
        }
    }

    private var right: some View {
        VStack(alignment: .leading, spacing: 14) {
            HighlightList(sentences: state.highlights)
            if !state.how.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    PageHeading(String(localized: "how.title", bundle: .tacho))
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(state.how) { row in
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.label)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(row.value)
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                            }
                            .font(Theme.Style.small)
                        }
                    }
                    .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
                    .background(Theme.tile, in: RoundedRectangle(cornerRadius: Theme.Size.noteRadius, style: .continuous))
                    Say(String(localized: "quota.footnote", bundle: .tacho))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                PageHeading(String(localized: "limits.every", bundle: .tacho))
                LimitList {
                    ForEach(Array(state.rows.enumerated()), id: \.element.id) { index, row in
                        self.row(row, at: index)
                    }
                }
            }
            FigureList(title: String(localized: "limits.noQuota", bundle: .tacho), rows: state.noQuota)
        }
    }

    /// A row's parts, for `LimitList` to lay out: the button that is the whole row behind, then what it shows.
    @ViewBuilder private func row(_ row: LimitsState.Row, at index: Int) -> some View {
        Button { select(row.key) } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(row.key == state.selected ? Theme.hover : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "limit.tickHelp", bundle: .tacho))
        .accessibilityLabel([row.name, row.message ?? row.percent].compactMap(\.self).joined(separator: ", "))
        .layoutValue(key: LimitList.Part.self, value: .init(row: index, column: .back))
        Group {
            Text(row.name)
                .font(Theme.Style.small)
                .fixedSize(horizontal: false, vertical: true)
                .layoutValue(key: LimitList.Part.self, value: .init(row: index, column: .name))
            if let message = row.message {
                Text(message)
                    .font(Theme.Style.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutValue(key: LimitList.Part.self, value: .init(row: index, column: .message))
            } else {
                Meter(value: row.value, tick: row.pace, level: row.level)
                    .layoutValue(key: LimitList.Part.self, value: .init(row: index, column: .meter))
                Text(row.percent ?? "")
                    .font(Theme.Style.small.weight(.medium))
                    .monospacedDigit()
                    .fixedSize()
                    .layoutValue(key: LimitList.Part.self, value: .init(row: index, column: .percent))
            }
        }
        // The row behind takes the click.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// "Every limit": a row to a limit, with its name, meter and percent in columns. The percent column takes its widest percent and the name
/// column its widest name, unless that would leave a meter shorter than its shortest, when the names wrap instead; the meter takes the rest.
/// The button that picks a limit lies behind its whole row. Measured from the content, so no name or percent is cut, in any language.
private struct LimitList: Layout {
    enum Column {
        case back, name, meter, percent, message
    }

    struct Part: LayoutValueKey {
        static let defaultValue = Part(row: 0, column: .back)

        var row: Int
        var column: Column
    }

    private static let gap: CGFloat = 8
    private static let inset = EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
    private static let rowGap: CGFloat = 2
    private static let shortestMeter: CGFloat = 24
    /// A meter's length when nothing proposes a width.
    private static let idealMeter: CGFloat = 96

    private struct Measured {
        var width: CGFloat
        var name: CGFloat
        var meter: CGFloat
        var percent: CGFloat
        var heights: [CGFloat]
    }

    private func measure(_ subviews: Subviews, width proposed: CGFloat?) -> Measured {
        var widestName: CGFloat = 0, narrowestName: CGFloat = 0, percent: CGFloat = 0, rows = 0
        for subview in subviews {
            let part = subview[Part.self]
            rows = max(rows, part.row + 1)
            switch part.column {
            case .name:
                widestName = max(widestName, subview.sizeThatFits(.unspecified).width)
                narrowestName = max(narrowestName, subview.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width)
            case .percent:
                percent = max(percent, subview.sizeThatFits(.unspecified).width)
            case .back, .meter, .message:
                break
            }
        }
        let sides = Self.inset.leading + Self.inset.trailing
        let fixed = percent + 2 * Self.gap + sides
        let width = proposed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? (proposed == 0 ? narrowestName + Self.shortestMeter + fixed : widestName + Self.idealMeter + fixed)
        let name = max(narrowestName, min(widestName, width - fixed - Self.shortestMeter))
        let meter = max(0, width - fixed - name)
        var heights = [CGFloat](repeating: 0, count: rows)
        for subview in subviews {
            let part = subview[Part.self]
            let cell: CGFloat? = switch part.column {
            case .name: name
            case .meter: meter
            case .percent: percent
            case .message: max(0, width - sides - name - Self.gap)
            case .back: nil
            }
            guard let cell else { continue }
            heights[part.row] = max(heights[part.row], subview.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height)
        }
        return Measured(width: width, name: name, meter: meter, percent: percent, heights: heights.map { $0 + Self.inset.top + Self.inset.bottom })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let measured = measure(subviews, width: proposal.width)
        return CGSize(width: measured.width, height: measured.heights.reduce(0, +) + Self.rowGap * CGFloat(max(measured.heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = measure(subviews, width: bounds.width)
        var tops: [CGFloat] = []
        var top = bounds.minY
        for height in measured.heights {
            tops.append(top)
            top += height + Self.rowGap
        }
        for subview in subviews {
            let part = subview[Part.self]
            guard tops.indices.contains(part.row) else { continue }
            let height = measured.heights[part.row]
            let inner = height - Self.inset.top - Self.inset.bottom
            let left = bounds.minX + Self.inset.leading
            let nameRight = left + measured.name + Self.gap
            switch part.column {
            case .back:
                subview.place(at: CGPoint(x: bounds.minX, y: tops[part.row]), proposal: ProposedViewSize(width: measured.width, height: height))
            case .name:
                subview.place(at: CGPoint(x: left, y: tops[part.row] + Self.inset.top), proposal: ProposedViewSize(width: measured.name, height: nil))
            case .message:
                subview.place(at: CGPoint(x: nameRight, y: tops[part.row] + Self.inset.top), proposal: ProposedViewSize(width: max(0, bounds.maxX - Self.inset.trailing - nameRight), height: nil))
            case .meter:
                subview.place(at: CGPoint(x: nameRight, y: tops[part.row] + Self.inset.top + inner / 2), anchor: .leading, proposal: ProposedViewSize(width: measured.meter, height: nil))
            case .percent:
                subview.place(at: CGPoint(x: bounds.maxX - Self.inset.trailing, y: tops[part.row] + Self.inset.top + inner / 2), anchor: .trailing, proposal: ProposedViewSize(width: measured.percent, height: nil))
            }
        }
    }
}

/// How far each recent window got: spec section 12.5.
struct RecentWindows: View {
    private static let peakAxis = String(localized: "chart.value", bundle: .tacho)
    private static let windowAxis = String(localized: "chart.category", bundle: .tacho)

    let windows: [LimitHistory.Window]
    let now: Date

    private var ranOut: Int {
        windows.filter(\.reachedLimit).count
    }

    var body: some View {
        if windows.count >= 2 {
            VStack(alignment: .leading, spacing: 6) {
                PageHeading(String(localized: "limits.recent", bundle: .tacho))
                Chart {
                    ForEach(windows.indices, id: \.self) { index in
                        BarMark(x: .value(Self.windowAxis, String(index)), y: .value(Self.peakAxis, windows[index].peak))
                            .cornerRadius(1.5)
                            .foregroundStyle(color(index))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 68)
                .accessibilityElement()
                .accessibilityLabel(String(format: String(localized: "limits.recentOf", bundle: .tacho), ranOut, windows.count))
                Flow(spacing: 8, lineSpacing: 2, spread: true) {
                    Text(String(format: String(localized: "limits.oldest", bundle: .tacho), Labels.ageShort(now.timeIntervalSince(windows[0].resetsAt))))
                        .fixedSize()
                    Text(String(format: String(localized: "limits.recentOf", bundle: .tacho), ranOut, windows.count))
                        .fixedSize()
                    Text(String(localized: "chart.now", bundle: .tacho))
                        .fixedSize()
                }
                .font(Theme.Style.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ index: Int) -> Color {
        if windows[index].reachedLimit { return Theme.amberFill }
        return index == windows.count - 1 ? .accentColor : Theme.well
    }
}
