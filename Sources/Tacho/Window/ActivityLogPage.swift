import SwiftUI
import TachoKit

/// One line per request, newest first, with filters, loaded a page at a time.
struct ActivityLogPage: View {
    private static let pageSize = 200
    private static let typingPause: Duration = .milliseconds(250)
    private static let refreshInterval: Duration = .seconds(30)

    /// What narrows the log. A change starts it over.
    private struct Query: Equatable {
        var source: Source?
        var project: String?
        var model: String?
        var search = ""

        var filter: EventFilter {
            EventFilter(
                sources: source.map { [$0] },
                projects: project.map { [$0] },
                models: model.map { [$0] },
                search: search.isEmpty ? nil : search
            )
        }
    }

    let model: AppModel

    @State private var query = Query()
    /// The query `lines` answers. A filter changes `query` first, and `lines` only once the new page is in.
    @State private var shownQuery: Query?
    @State private var lines: Loaded<[LogLine]> = .loading
    @State private var hasMore = false
    @State private var isLoadingMore = false
    @State private var projects: [String] = []
    @State private var models: [String] = []
    /// What the filter lets through, all of it and not only the rows loaded.
    @State private var summary: LogSummary?

    var body: some View {
        VStack(spacing: 0) {
            filters.padding(16)
            LogStrip(summary: summary, hasFilter: query != Query()) { query = Query() }
            switch lines {
            case .loading: HeldPlaceholder(kind: .log)
            case .failed: ProblemNote(model: model)
            case .ready(let lines) where lines.isEmpty:
                Text(String(localized: "log.empty", bundle: .tacho))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready(let lines):
                LogTable(lines: lines) { Task { await loadMore() } }
            }
        }
        .task {
            // An all-history query: once for the page, and again only while it has found nothing, which may be a failed look.
            await model.whileShowing(.activity, every: Self.refreshInterval) {
                if projects.isEmpty, models.isEmpty { await loadOptions() }
            }
        }
        .task(id: Asked(query: query, epoch: model.figuresEpoch)) {
            let ask = self.ask
            if case .activity(let rows, let hasMore, let summary) = model.remembered(ask) {
                lines = .ready(rows.map(LogLine.init))
                shownQuery = query
                self.hasMore = hasMore
                self.summary = summary
            } else {
                // Another filter's rows must not stay under this one.
                lines = .loading
                shownQuery = nil
                summary = nil
            }
            try? await Task.sleep(for: Self.typingPause)
            guard !Task.isCancelled else { return }
            await reload()
            await loadSummary()
            await model.whileShowing(.activity, every: Self.refreshInterval, startNow: false) {
                await loadNewer()
                await loadSummary()
            }
        }
    }

    private struct Asked: Equatable {
        var query: Query
        var epoch: Int
    }

    private var ask: FigureAsk {
        FigureAsk(page: .activity, source: query.source, project: query.project, modelName: query.model, search: query.search)
    }

    /// They go onto a second line in a narrow window, rather than squeezing their titles.
    private var filters: some View {
        Flow(spacing: 12, lineSpacing: 8) {
            Picker(String(localized: "log.source", bundle: .tacho), selection: $query.source) {
                Text(String(localized: "log.all", bundle: .tacho)).tag(Source?.none)
                ForEach(Source.allCases, id: \.self) { Text($0.displayName).tag(Source?.some($0)) }
            }
            .fixedSize()
            Picker(String(localized: "log.project", bundle: .tacho), selection: $query.project) {
                Text(String(localized: "log.all", bundle: .tacho)).tag(String?.none)
                ForEach(projects, id: \.self) { Text(($0 as NSString).abbreviatingWithTildeInPath).tag(String?.some($0)) }
            }
            .fixedSize()
            Picker(String(localized: "log.model", bundle: .tacho), selection: $query.model) {
                Text(String(localized: "log.all", bundle: .tacho)).tag(String?.none)
                ForEach(models, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .fixedSize()
            TextField(String(localized: "log.search", bundle: .tacho), text: $query.search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The projects and models there are to filter by. A request that names none cannot be picked, so "" is left out.
    private func loadOptions() async {
        guard let overview = try? await model.engine?.overview(range: RangeChoice.all.timeRange(now: Date())) else { return }
        projects = overview.byProject.map(\.key).filter { !$0.isEmpty }
        models = overview.byModel.map(\.key).filter { !$0.isEmpty }
    }

    private func reload() async {
        guard let engine = model.engine else {
            lines = .failed
            return
        }
        do {
            let asked = query
            let page = try await engine.log(filter: asked.filter, before: nil, limit: Self.pageSize)
            guard !Task.isCancelled, query == asked else { return }
            let more = Self.mayHaveMore(page)
            if case .ready(let old) = lines, shownQuery == asked, old.map(\.row) == page {
                hasMore = more
            } else {
                lines = .ready(page.map(LogLine.init))
                shownQuery = asked
                hasMore = more
            }
            storeShown()
        } catch {
            if !Task.isCancelled { lines = .failed }
        }
    }

    private func loadMore() async {
        let asked = query
        guard hasMore, !isLoadingMore, shownQuery == asked, case .ready(let shown) = lines, let last = shown.last, let engine = model.engine else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        // A failed page leaves `hasMore` as it was, so the next look at the last row tries again.
        guard let page = try? await engine.log(filter: asked.filter, before: last.row.event.time, limit: Self.pageSize), shownQuery == asked, query == asked,
              case .ready(let current) = lines else { return }
        lines = .ready(current + page.map(LogLine.init))
        hasMore = Self.mayHaveMore(page)
        storeShown()
    }

    /// A failed read takes the strip away and leaves the table.
    private func loadSummary() async {
        let latest = try? await model.engine?.logSummary(filter: query.filter)
        guard !Task.isCancelled else { return }
        summary = latest
        storeShown()
    }

    /// Merges in what arrived since, rather than reloading: that would drop the pages already loaded, and the place in them.
    private func loadNewer() async {
        let asked = query
        guard shownQuery == asked, let engine = model.engine,
              let page = try? await engine.log(filter: asked.filter, before: nil, limit: Self.pageSize),
              shownQuery == asked, query == asked, case .ready(let current) = lines else { return }
        let known = Set(current.map(\.id))
        let fresh = page.map(LogLine.init).filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        // A whole page of new rows may not reach the ones shown, which would leave a gap between them.
        guard fresh.count < page.count else { return await reload() }
        // Sorted, not put on top: a backfill brings rows older than some already shown.
        lines = .ready((fresh + current).sorted { $0.row.event.time > $1.row.event.time })
        storeShown()
    }

    /// The first page only. Later pages stay on the screen, and out of the cache, so a long scroll cannot stay in memory after the page closes.
    private func storeShown() {
        guard shownQuery == query, case .ready(let shown) = lines else { return }
        let rows = Array(shown.prefix(Self.pageSize).map(\.row))
        model.remember(.activity(rows: rows, hasMore: hasMore || shown.count > rows.count, summary: summary), for: ask)
    }

    /// `logPage` runs past the limit to finish a tied time, so a full page can hold more than `limit`: testing `== limit` would stop early.
    /// A shorter page, and so an empty one, ends the log.
    private static func mayHaveMore(_ page: [LogRow]) -> Bool {
        page.count >= pageSize
    }
}

/// What the filter lets through, and the way back from it: spec section 13.1.
struct LogStrip: View {
    let summary: LogSummary?
    let hasFilter: Bool
    let clear: () -> Void

    var body: some View {
        if summary != nil || hasFilter {
            VStack(spacing: 0) {
                Flow(spacing: 24, lineSpacing: 4) {
                    if let summary {
                        item("log.showing", WindowLabels.requests(summary.requests))
                        item("log.cost", Labels.figure(summary.cost))
                        item("log.output", TokenFormat.compact(summary.output))
                        if let hit = summary.cacheHitRate {
                            item("log.cacheHit", String(format: "%.1f%%", hit * 100))
                        }
                        if let share = summary.subagentShare {
                            item("log.subagents", String(format: String(localized: "log.subagentsValue", bundle: .tacho), Int((share * 100).rounded())))
                        }
                    }
                    if hasFilter {
                        Button(String(localized: "log.clear", bundle: .tacho), action: clear)
                            .buttonStyle(.link)
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(Theme.Style.small)
                .padding(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                Divider()
            }
        }
    }

    private func item(_ label: String.LocalizationValue, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(String(localized: label, bundle: .tacho))
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .fixedSize()
    }
}

/// A row of the log, identified by the event it shows.
struct LogLine: Identifiable {
    let row: LogRow

    var id: String { row.event.dedupKey }
}

/// A model id and what kind of request it was.
struct LogModelCell: View {
    let event: UsageEvent
    /// The row's tooltip; the whole id when there is none.
    var help: String?

    var body: some View {
        HStack(spacing: 5) {
            // The whole id if it fits. If not the family, cut at its end, so that what tells two models apart goes last. The tooltip has
            // it whole, and the id gives way before the chips.
            ViewThatFits(in: .horizontal) {
                Text(Labels.model(event.model ?? ""))
                    .lineLimit(1)
                Text(WindowLabels.modelFamily(Labels.model(event.model ?? "")))
                    .lineLimit(1)
            }
            .help(help ?? event.model ?? "")
            if event.isSubagent { chip(String(localized: "log.tagAgent", bundle: .tacho)) }
            if event.speed == "fast" { chip(String(localized: "log.tagFast", bundle: .tacho)) }
        }
    }

    /// The id gives way first: a chip is short, and says something the tooltip does not.
    private func chip(_ text: String) -> some View {
        Text(text)
            .font(Theme.Style.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .layoutPriority(1)
    }
}

/// The table's columns, in column order, with their ideal widths and the order in which they give way as the log narrows.
enum LogColumn: String, CaseIterable {
    case time, cli, project, model, input, output, cacheRead, write5m, write1h, cost, speed

    var ideal: CGFloat {
        switch self {
        // `10月28日 上午12:48:58`: Chinese on a 12-hour clock is the widest older row of any language here.
        case .time: 148
        // The CLI's name alone, its client in the tooltip: `Claude Code · Terminal` would need 144.
        case .cli: 82
        case .project: 72
        case .model: 153
        case .input: 46
        case .output: 50
        case .cacheRead: 66
        case .write5m: 60
        case .write1h: 36
        case .cost: 52
        case .speed: 72
        }
    }

    /// Least wanted first. Time, CLI, Model and Cost never go: a row says when, which CLI and model, and what it cost.
    static let givingWay: [LogColumn] = [.write1h, .write5m, .speed, .input, .cacheRead, .project, .output]
    /// What the table spends besides the columns' widths: 17 beside each column and 15 at the edges, 202 for all eleven, measured on the
    /// real table. A point over and AppKit shaves the first two columns, which cuts Time.
    static let beside: CGFloat = 17
    static let edges: CGFloat = 15

    /// The columns a log `width` wide shows: all of them, less as many as must give way, in their order, for the rest to fit whole.
    static func shown(in width: CGFloat) -> Set<LogColumn> {
        var shown = Set(allCases)
        for column in givingWay where needs(shown) > width {
            shown.remove(column)
        }
        return shown
    }

    static func needs(_ columns: Set<LogColumn>) -> CGFloat {
        columns.reduce(edges) { $0 + $1.ideal + beside }
    }
}

/// The log's table. `reachedEnd` runs when its last line comes into view. Columns give way as it narrows, and what they held stays in
/// each row's tooltip.
struct LogTable: View {
    let lines: [LogLine]
    let reachedEnd: () -> Void

    @State private var width: CGFloat = 0

    private var shown: Set<LogColumn> {
        LogColumn.shown(in: width)
    }

    /// The columns are chosen before the table is made, and it is made again when they change: AppKit gives a hidden column's width to
    /// the others, so hiding one in a table already laid out leaves the table as wide as before, and the log scrolls sideways.
    var body: some View {
        Color.clear
            .overlay {
                if width > 0 {
                    table.id(shown)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// Every column shown or hidden as `shown` has it, from the start.
    private var visibility: Binding<TableColumnCustomization<LogLine>> {
        var columns = TableColumnCustomization<LogLine>()
        for column in LogColumn.allCases {
            columns[visibility: column.rawValue] = shown.contains(column) ? .visible : .hidden
        }
        return .constant(columns)
    }

    private var table: some View {
        Table(lines, columnCustomization: visibility) {
            Group {
                TableColumn(String(localized: "log.time", bundle: .tacho)) { (line: LogLine) in
                    Text(WindowLabels.logTime(line.row.event.time, now: Date()))
                        .monospacedDigit()
                        .help(help(line, line.row.event.time.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(Labels.locale))))
                        .onAppear { if line.id == lines.last?.id { reachedEnd() } }
                }
                .width(min: 80, ideal: LogColumn.time.ideal)
                .customizationID(LogColumn.time.rawValue)
                .disabledCustomizationBehavior(.visibility)
                TableColumn(String(localized: "log.cli", bundle: .tacho)) { (line: LogLine) in
                    Text(line.row.event.source.displayName)
                        .help(help(line, Labels.source(of: line.row.event)))
                }
                .width(min: 60, ideal: LogColumn.cli.ideal)
                .customizationID(LogColumn.cli.rawValue)
                .disabledCustomizationBehavior(.visibility)
                TableColumn(String(localized: "log.project", bundle: .tacho)) { (line: LogLine) in
                    Text(Labels.project(line.row.event.project ?? ""))
                        .help(help(line, line.row.event.project ?? ""))
                }
                .width(min: 60, ideal: LogColumn.project.ideal)
                .customizationID(LogColumn.project.rawValue)
                TableColumn(String(localized: "log.model", bundle: .tacho)) { (line: LogLine) in
                    LogModelCell(event: line.row.event, help: help(line, line.row.event.model ?? ""))
                }
                .width(min: 90, ideal: LogColumn.model.ideal)
                .customizationID(LogColumn.model.rawValue)
                .disabledCustomizationBehavior(.visibility)
            }
            Group {
                TableColumn(TokenCategory.input.name) { (line: LogLine) in secondary(line.row.event.tokens.input, line) }
                    .width(min: 40, ideal: LogColumn.input.ideal)
                    .customizationID(LogColumn.input.rawValue)
                TableColumn(TokenCategory.output.name) { (line: LogLine) in number(line.row.event.tokens.output, line) }
                    .width(min: 44, ideal: LogColumn.output.ideal)
                    .customizationID(LogColumn.output.rawValue)
                TableColumn(TokenCategory.cacheRead.name) { (line: LogLine) in secondary(line.row.event.tokens.cacheRead, line) }
                    .width(min: 56, ideal: LogColumn.cacheRead.ideal)
                    .customizationID(LogColumn.cacheRead.rawValue)
                TableColumn(String(localized: "log.write5m", bundle: .tacho)) { (line: LogLine) in secondary(line.row.event.tokens.cacheWrite5m, line) }
                    .width(min: 56, ideal: LogColumn.write5m.ideal)
                    .customizationID(LogColumn.write5m.rawValue)
                TableColumn(String(localized: "log.write1h", bundle: .tacho)) { (line: LogLine) in secondary(line.row.event.tokens.cacheWrite1h, line) }
                    .width(min: 36, ideal: LogColumn.write1h.ideal)
                    .customizationID(LogColumn.write1h.rawValue)
                TableColumn(String(localized: "sources.cost", bundle: .tacho)) { (line: LogLine) in
                    Text(Labels.logCost(line.row.costUSD))
                        .monospacedDigit()
                        .help(help(line))
                }
                .width(min: 48, ideal: LogColumn.cost.ideal)
                .customizationID(LogColumn.cost.rawValue)
                .disabledCustomizationBehavior(.visibility)
                TableColumn(String(localized: "log.speed", bundle: .tacho)) { (line: LogLine) in
                    Text(Labels.logSpeed(line.row))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help(help(line))
                }
                .width(min: 52, ideal: LogColumn.speed.ideal)
                .customizationID(LogColumn.speed.rawValue)
            }
        }
    }

    /// A cell's tooltip: what it says of itself, then whatever the row's hidden columns hold.
    private func help(_ line: LogLine, _ own: String? = nil) -> String {
        LogTable.hidden(line.row, shown: shown, own: own)
    }

    /// Each hidden column's name and value, a line each, under `own`.
    nonisolated static func hidden(_ row: LogRow, shown: Set<LogColumn>, own: String? = nil) -> String {
        let tokens = row.event.tokens
        let lines: [String] = LogColumn.allCases.filter { !shown.contains($0) }.compactMap { column in
            switch column {
            case .project: "\(String(localized: "log.project", bundle: .tacho)): \(Labels.project(row.event.project ?? ""))"
            case .input: "\(TokenCategory.input.name): \(TokenFormat.compact(tokens.input))"
            case .output: "\(TokenCategory.output.name): \(TokenFormat.compact(tokens.output))"
            case .cacheRead: "\(TokenCategory.cacheRead.name): \(TokenFormat.compact(tokens.cacheRead))"
            // In full: the headers lean on each other, and "1 h" alone says nothing.
            case .write5m: "\(String(localized: "prices.cacheWrite5m", bundle: .tacho)): \(TokenFormat.compact(tokens.cacheWrite5m))"
            case .write1h: "\(String(localized: "prices.cacheWrite1h", bundle: .tacho)): \(TokenFormat.compact(tokens.cacheWrite1h))"
            // It names its own unit: `71 tok/s`.
            case .speed: Labels.logSpeed(row)
            case .time, .cli, .model, .cost: nil
            }
        }
        return ([own].compactMap { $0?.isEmpty == false ? $0 : nil } + lines).joined(separator: "\n")
    }

    private func secondary(_ tokens: Int, _ line: LogLine) -> some View {
        number(tokens, line)
            .foregroundStyle(.secondary)
    }

    private func number(_ tokens: Int, _ line: LogLine) -> some View {
        Text(TokenFormat.compact(tokens))
            .monospacedDigit()
            .help(help(line))
    }
}
