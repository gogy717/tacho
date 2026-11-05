import SwiftUI
import TachoKit

/// What Summary shows, already worded, so that every state draws and measures with no engine behind it.
struct SummaryState: Equatable {
    struct WeekColumns: Equatable {
        var before: [Double]
        var last: [Double]
    }

    /// Output this week. `before` is empty when it cannot compare.
    enum WeekChart: Equatable {
        case waiting
        case columns(WeekColumns)
        /// Saying it is not ready would not be true: it may never be.
        case failed
    }

    struct LimitCard: Equatable {
        var key: LimitKey
        var name: String
        var age: String?
        var sentence: String
        var tone: Tone
        var percent: String
        var runway: Runway
        var start: String
        var middle: String
        var end: String
    }

    /// One pinned card, wide enough for more than the panel's tile.
    struct PinnedCardState: Equatable, Identifiable {
        enum Visual: Equatable {
            case none
            case needle(value: Double, p25: Double, p75: Double)
            case spark([Double], color: Color)
            case shares([SplitBar.Part])
            case rows([FigureRow], more: Int)
            case hours([[Int]])
            case bars([Double])
        }

        var id: PinnedCard
        var title: String
        var value: String?
        var visual: Visual
        var say: String?
        var route: Route
    }

    var subtitle: String
    var rate: PanelState.Rate
    var today: PanelState.Today
    /// Beside the Cost today sentence.
    var todayFigure: String
    var limit: LimitCard?
    /// Said in place of the limit card, with nothing to chart.
    var limitsSay: String?
    var weekSentence: String
    var week: WeekChart
    var cards: [PinnedCardState]
    var progress: PanelState.Progress?
    /// The panel cannot be reached, so its rate comes here.
    var showsRate: Bool
}

extension SummaryState {
    /// The toolbar has the rate, so it counts here only when the page shows it too.
    func drawsTheSamePage(as other: SummaryState) -> Bool {
        var other = other
        if !showsRate { other.rate = rate }
        return self == other
    }

    /// - Parameters:
    ///   - insights: which rules fire. Until the first answer, no comparison is made and no limit is picked.
    ///   - day: today by the hour.
    ///   - week: the last 7 days, today so far, and as much of the 7 before them, which is what rules W compare.
    ///   - history: the limit card's record, once it is in.
    init(
        dashboard: Dashboard,
        insights: PanelInsights?,
        day: DetailFigures?,
        week: Loaded<DetailFigures>,
        history: LimitHistory? = nil,
        preferences: Preferences,
        menuBarBlocked: Bool,
        now: Date,
        calendar: Calendar = .current
    ) {
        let panel = PanelState(dashboard: dashboard, preferences: preferences, insights: insights, now: now)
        let limits = insights?.results.limits
        let card = limits.flatMap { Self.limitCard($0, history: history, now: now, calendar: calendar) }
        self.init(
            subtitle: now.formatted(Date.FormatStyle(time: .shortened).weekday(.wide).locale(Labels.locale)),
            rate: panel.rate,
            today: panel.today,
            todayFigure: panel.today.isOutput ? TokenFormat.compact(dashboard.today.tokens.output) : Labels.figure(dashboard.today.cost),
            limit: card,
            limitsSay: card == nil ? panel.limits.say : nil,
            weekSentence: insights.map { WindowLabels.sentence($0.results.week) } ?? " ",
            week: Self.weekChart(week, rule: insights?.results.week),
            cards: Self.cards(preferences.pinnedCards, dashboard: dashboard, insights: insights, day: day),
            progress: panel.progress,
            showsRate: menuBarBlocked
        )
    }

    /// With nothing to compare, the grey columns go: section 11.1.
    private static func weekChart(_ week: Loaded<DetailFigures>, rule: WeekRule?) -> WeekChart {
        guard case .ready(let figures) = week else {
            if case .failed = week { return .failed }
            return .waiting
        }
        // Whether two weeks can be compared is the engine's to say, so with no answer they are not.
        var canCompare = rule != nil
        if case .w4 = rule { canCompare = false }
        if case .w6 = rule { canCompare = false }
        return .columns(WeekColumns(
            before: canCompare ? figures.previousColumns.map { Double($0.tokens.output) } : [],
            last: figures.columns.map { Double($0.tokens.output) }
        ))
    }

    private static func limitCard(_ insight: LimitsInsight, history: LimitHistory?, now: Date, calendar: Calendar) -> LimitCard? {
        guard let quota = insight.limit, let rule = insight.summarySay, let centre = insight.summaryCentre else { return nil }
        let (sentence, tone) = WindowLabels.sentence(rule, quota, now: now, calendar: calendar)
        return LimitCard(
            key: LimitKey(quota.snapshot),
            name: Labels.limitName(quota.snapshot),
            age: Labels.updated(now.timeIntervalSince(quota.snapshot.observedAt)),
            sentence: sentence,
            tone: tone,
            percent: Labels.percent(quota) ?? "",
            runway: Runway(quota, history: history?.readings ?? [], now: now),
            start: Labels.reset(quota.resetsAt.addingTimeInterval(-quota.snapshot.window.length), now: now, calendar: calendar),
            middle: WindowLabels.caption(centre, quota, now: now, calendar: calendar),
            end: Labels.reset(quota.resetsAt, now: now, calendar: calendar)
        )
    }

    /// The panel's cards, with what the window has room for: spec section 11.2.
    private static func cards(_ pinned: [PinnedCard], dashboard: Dashboard, insights: PanelInsights?, day: DetailFigures?) -> [PinnedCardState] {
        let tiles = PanelState.Tile.pinned(pinned, dashboard: dashboard, insights: insights, limit: nil)
        return zip(pinned, tiles).map { card, tile in
            var state = PinnedCardState(id: card, title: tile.title, value: tile.value, visual: visual(tile.mark), say: tile.say, route: tile.route)
            switch card {
            case .output:
                if dashboard.today.tokens.output > 0, let day { state.visual = .bars(day.columns.map { Double($0.tokens.output) }) }
            case .clis:
                addRows(to: &state, sources: dashboard.sources, shares: insights?.clis.shares ?? [])
            case .tokens:
                if let percent = insights?.results.cacheReadPercent {
                    state.say = String(format: String(localized: "say.tokensCacheShare", bundle: .tacho), percent)
                }
            case .when:
                if let hours = insights?.hourOfWeek, hours.contains(where: { $0.contains { $0 > 0 } }) {
                    state.value = nil
                    state.visual = .hours(hours)
                }
            case .cache, .speed:
                break
            }
            return state
        }
    }

    private static func visual(_ mark: PanelState.Tile.Mark) -> PinnedCardState.Visual {
        switch mark {
        case .needle(let value, let p25, let p75): .needle(value: value, p25: p25, p75: p75)
        case .spark(let values): .spark(values, color: Theme.cacheRead)
        case .layers(let fractions): .shares(zip(Theme.stackOrder, fractions).map { .init(share: $1, color: $0.color) })
        case .none, .shares: .none
        }
    }

    /// Up to four rows of money, in the engine's order and on its basis, so that the bars agree with the sentence under them. The rows
    /// are the dashboard's, which ticks every second, and `shares` is up to a minute old: a CLI it has not heard of goes last, with no
    /// bar to compare, and one that has gone leaves no row. With no answer yet nothing is compared.
    private static func addRows(to state: inout PinnedCardState, sources: [SourceRow], shares: [CLIFigures.Share]) {
        let shown = 4
        let used = sources.filter { $0.today.total > 0 }
        guard !used.isEmpty else { return }
        let ranked = shares.compactMap { share in used.first { $0.source == share.source }.map { (row: $0, fraction: Optional(share.fraction)) } }
        let unranked = used.filter { row in !shares.contains { $0.source == row.source } }.map { (row: $0, fraction: Double?.none) }
        let top = ranked.first?.fraction ?? 0
        let rows = (ranked + unranked).map { item in
            FigureRow(
                name: item.row.source.displayName,
                figure: Labels.figure(item.row.todayCost),
                fraction: top > 0 ? item.fraction.map { $0 / top } : nil
            )
        }
        state.title = String(localized: "card.clisToday", bundle: .tacho)
        state.value = nil
        state.visual = .rows(Array(rows.prefix(shown)), more: max(rows.count - shown, 0))
    }
}

/// What Summary has read, kept apart from the page so that a test can reach what a failed read does.
struct SummaryReads {
    var insights: PanelInsights?
    var history: LimitHistory?
    var day: DetailFigures?
    var week: Loaded<DetailFigures> = .loading

    /// Together, or a changed limit would draw the old one's readings until the next await. A failed read keeps what is drawn: the card
    /// is an old answer for a minute, not no answer.
    mutating func take(insights answer: PanelInsights?, history record: LimitHistory?) {
        guard let answer else { return }
        insights = answer
        history = record
    }

    mutating func take(day latest: DetailFigures?) {
        if let latest { day = latest }
    }

    mutating func take(week latest: DetailFigures?) {
        week = latest.map { .ready($0) } ?? .failed
    }
}

/// What Summary has on screen, moved on only for a change the page would show. The figures move on most ticks, and any update to the
/// page's host costs milliseconds, however little changed, where working out the state to compare costs 0.06 of one. So the body does
/// not read them, and a look from outside it decides.
@MainActor @Observable
final class SummaryFeed {
    private(set) var drawn: SummaryState?
    /// Read only by the toolbar's small view, so that nothing else is redrawn when the rate moves.
    private(set) var rate: PanelState.Rate?

    func take(_ latest: SummaryState?) {
        // The toolbar draws no chart, so a chart moving alone is no reason to touch it.
        var shown = latest?.rate
        shown?.series = []
        shown?.unpricedTokens = []
        if shown != rate { rate = shown }
        if let latest, let drawn, latest.drawsTheSamePage(as: drawn) { return }
        if latest != drawn { drawn = latest }
    }
}

/// The main interface: what changed, then the cards the person keeps. Spec section 11.
struct SummaryPage: View {
    private static let refreshInterval: Duration = .seconds(60)
    private static let lookInterval: Duration = .seconds(1)

    let model: AppModel
    var read: DetailRead?

    @State private var reads = SummaryReads()
    @State private var isEditing = false
    @State private var feed = SummaryFeed()
    @State private var looks = PageLook()

    /// The page as the figures have it now. The body reads this only until the first look, so that the page opens with its figures.
    private var latest: SummaryState? {
        model.dashboard.map { dashboard in
            SummaryState(
                dashboard: dashboard,
                insights: insights,
                day: day,
                week: week,
                history: history,
                preferences: model.preferences,
                menuBarBlocked: model.menuBarBlocked,
                now: model.pageClock
            )
        }
    }

    private var insights: PanelInsights? { reads.insights }
    private var day: DetailFigures? { reads.day }
    private var week: Loaded<DetailFigures> { reads.week }
    private var history: LimitHistory? { reads.history }

    var body: some View {
        Group {
            if let state = feed.drawn ?? latest {
                SummaryContent(
                    state: state,
                    now: model.pageClock,
                    pick: { model.setRateMode($0) },
                    open: { model.open($0) },
                    edit: { isEditing = true }
                )
                .navigationSubtitle(state.subtitle)
                .toolbar {
                    // One identity, so that a page that redraws keeps the item rather than rebuilding it under a click.
                    ToolbarItem(id: "rate", placement: .primaryAction) {
                        LiveRateMenu(feed: feed, first: state.rate, pick: { model.setRateMode($0) }) { model.page = .settings }
                    }
                }
            } else {
                NoFigures(model: model)
            }
        }
        .sheet(isPresented: $isEditing) {
            PinsSheet(pinned: model.preferences.pinnedCards) { pinned in
                var changed = model.preferences
                changed.pinnedCards = pinned
                model.save(changed)
                isEditing = false
            }
        }
        // A person's own change does not wait for the next look, nor does a window coming back.
        .onChange(of: model.preferences) { feed.take(latest) }
        .onChange(of: model.mainWindowVisible) { if model.mainWindowVisible { feed.take(latest) } }
        .task {
            await model.whileShowing(.summary, every: Self.refreshInterval) { await load() }
        }
        .task {
            await model.whileShowing(.summary, every: Self.lookInterval) {
                if looks.isDue(model.pageInputs) { feed.take(latest) }
            }
        }
    }

    private func load() async {
        // Each read waits for the last, so a closed page stops here, not after all four. What a failed read costs is `SummaryReads`'.
        let answer = try? await model.engine?.insights(now: Date())
        guard !Task.isCancelled else { return }
        let record: LimitHistory? = if let limit = answer?.results.limits.limit {
            try? await model.engine?.limitHistory(of: limit.snapshot, now: Date())
        } else {
            nil
        }
        guard !Task.isCancelled else { return }
        reads.take(insights: answer, history: record)
        feed.take(self.latest)
        let today = try? await model.detail(.day, via: read)
        guard !Task.isCancelled else { return }
        reads.take(day: today)
        let week = try? await model.detail(.week, via: read)
        guard !Task.isCancelled else { return }
        reads.take(week: week)
        // A read is news, and does not wait for the next look.
        feed.take(self.latest)
    }
}

/// The rate on its own: it moves on most ticks, and this is all that is redrawn for it.
private struct LiveRateMenu: View {
    let feed: SummaryFeed
    /// Until the first look.
    let first: PanelState.Rate
    let pick: (RateMode) -> Void
    let openSettings: () -> Void

    var body: some View {
        RateToolbarMenu(rate: feed.rate ?? first, pick: pick, openSettings: openSettings)
    }
}

/// A standard toolbar menu: a toolbar's items take the system's type, so this is not the panel's figure.
struct RateToolbarMenu: View {
    let rate: PanelState.Rate
    let pick: (RateMode) -> Void
    let openSettings: () -> Void

    private var title: String {
        switch rate.headline {
        case .live(let figure): figure
        case .idle: String(localized: "rate.idle", bundle: .tacho)
        case .reading: String(localized: "rate.reading", bundle: .tacho)
        }
    }

    var body: some View {
        Menu(title) {
            Picker(String(localized: "rate.switch", bundle: .tacho), selection: Binding(get: { rate.mode }, set: { pick($0) })) {
                ForEach(rate.readings) { Text($0.title).tag($0.mode) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button(String(localized: "rate.menu.settings", bundle: .tacho), action: openSettings)
        }
        .disabled(rate.headline == .reading)
        .help(String(localized: "rate.average", bundle: .tacho))
    }
}

struct SummaryContent: View {
    let state: SummaryState
    let now: Date
    let pick: (RateMode) -> Void
    let open: (Route) -> Void
    let edit: () -> Void

    var body: some View {
        PageBody {
            VStack(alignment: .leading, spacing: Theme.Size.columnGap) {
                if state.showsRate {
                    PanelHeader(rate: state.rate, now: now, chartHeight: 44, pick: pick) { open(Route(page: .settings)) }
                        .background(Theme.tile, in: RoundedRectangle(cornerRadius: Theme.Size.cardRadius, style: .continuous))
                }
                if let progress = state.progress {
                    VStack(alignment: .leading, spacing: 4) {
                        Say(progress.text)
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    }
                }
                // The pinned column holds two cards at least, beside the highlights.
                TwoColumns(weight: 1.3, rightMinimum: 2 * CardGrid.narrowest + Theme.Size.cardGap) {
                    highlights
                } right: {
                    pinned
                }
            }
        }
    }

    private var highlights: some View {
        VStack(alignment: .leading, spacing: Theme.Size.cardGap) {
            PageHeading(String(localized: "summary.highlights", bundle: .tacho))
            Highlight(
                title: state.today.title,
                sentence: state.today.sentence,
                series: state.today.series,
                chartLabel: String(localized: "panel.usualChartLabel", bundle: .tacho),
                figure: state.todayFigure,
                note: state.today.note,
                axis: ["00:00", state.today.series.band.isEmpty ? "" : String(localized: "summary.bandLegend", bundle: .tacho), "24:00"],
                lineColor: state.today.isOutput ? Theme.output : .primary,
                sentenceStyle: Theme.Style.sentenceL,
                chartHeight: 96,
                help: state.today.help,
                open: { open(Route(page: .cost, range: .day)) }
            )
            limitCard
            weekCard
        }
    }

    @ViewBuilder private var limitCard: some View {
        if let limit = state.limit {
            Card(action: { open(Route(page: .limits, limit: limit.key)) }) {
                CardHeader(limit.name, opens: true) {
                    if let age = limit.age {
                        Text(age)
                            .font(Theme.Style.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(limit.sentence)
                        .font(Theme.Style.sentenceL)
                        .foregroundStyle(limit.tone == .plain ? AnyShapeStyle(.primary) : AnyShapeStyle(limit.tone.color))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Text(limit.percent)
                        .font(Theme.Style.figureL)
                        .monospacedDigit()
                }
                RunwayChart(runway: limit.runway, showsMiddle: false, label: String(localized: "chart.runway", bundle: .tacho))
                    .frame(height: 74)
                Flow(spacing: 12, lineSpacing: 2, spread: true) {
                    Text(limit.start).fixedSize()
                    Text(limit.middle).fixedSize()
                    Text(limit.end).fixedSize()
                }
                .font(Theme.Style.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        } else if let say = state.limitsSay {
            Card(action: { open(Route(page: .limits)) }) {
                CardHeader(String(localized: "quota.title", bundle: .tacho), opens: true)
                Text(say)
                    .font(Theme.Style.sentenceL)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var weekCard: some View {
        Card(action: { open(Route(page: .tokens, metric: .output, range: .week)) }) {
            CardHeader(String(localized: "summary.outputWeek", bundle: .tacho), opens: true)
            Text(state.weekSentence)
                .font(Theme.Style.sentenceL)
                .fixedSize(horizontal: false, vertical: true)
            switch state.week {
            case .columns(let week):
                WeekBars(week: week)
                    .frame(height: 96)
                Flow(spacing: 12, lineSpacing: 2, spread: true) {
                    if !week.before.isEmpty {
                        Text(String(localized: "summary.lastWeek", bundle: .tacho)).fixedSize()
                    }
                    Text(String(localized: "summary.thisWeek", bundle: .tacho)).fixedSize()
                }
                .font(Theme.Style.caption)
                .foregroundStyle(.secondary)
            case .waiting:
                WaitingNote()
                    .frame(height: 96)
            case .failed:
                ProblemNote()
                    .frame(height: 96)
            }
        }
    }

    private var pinned: some View {
        VStack(alignment: .leading, spacing: Theme.Size.cardGap) {
            HStack {
                PageHeading(String(localized: "summary.pinned", bundle: .tacho))
                Spacer()
                Button(String(localized: "summary.edit", bundle: .tacho), action: edit)
                    .buttonStyle(.link)
                    .font(Theme.Style.small)
            }
            // As many columns as the room holds; a row's cards share a height, and a short card is not left short.
            CardGrid(spacing: Theme.Size.cardGap) {
                ForEach(state.cards) { card in
                    PinnedCardView(card: card, open: open)
                }
            }
        }
    }
}
