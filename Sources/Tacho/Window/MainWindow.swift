import AppKit
import SwiftUI
import TachoKit

/// What a page's data has come to.
enum Loaded<Value> {
    case loading
    case ready(Value)
    /// The engine could not be opened, or could not answer.
    case failed
}

extension Loaded: Equatable where Value: Equatable {}

/// The main window: the pages down the side, and the first-launch questions over them.
struct MainWindow: View {
    /// Its frame's autosave name.
    static let id = "main"
    static let minimumWidth: CGFloat = 820
    /// The toolbar's 52 go on top of this, so that the window's own minimum is 560.
    static let minimumHeight: CGFloat = 508

    let model: AppModel
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.menuBarBlocked {
                MenuBarBlockedNote(quit: quit)
            }
            NavigationSplitView {
                List(selection: selection) {
                    Section {
                        ForEach(Self.metrics, id: \.self, content: row)
                    }
                    Section(String(localized: "sidebar.records", bundle: .tacho)) {
                        ForEach(Self.records, id: \.self, content: row)
                    }
                    // A row like the others, not one pinned below the list: only a row of the list can share its selection.
                    Section {
                        row(.settings)
                    }
                }
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 240)
            } detail: {
                Group {
                    switch model.page {
                    case .summary: SummaryPage(model: model)
                    case .limits: LimitsPage(model: model)
                    case .cost: RangePage(model: model, kind: .cost)
                    case .tokens: RangePage(model: model, kind: .tokens)
                    case .cache: CachePage(model: model)
                    case .speed: SpeedPage(model: model)
                    case .activity: ActivityLogPage(model: model)
                    case .calendar: HeatmapPage(model: model)
                    case .settings: SettingsPage(model: model)
                    }
                }
                .navigationTitle(title(of: model.page))
                // The engine arrives with the first-launch answer: the pages start over, or they would sit on "no figures" until their next tick.
                .id(model.engine == nil)
            }
        }
        .frame(minWidth: Self.minimumWidth, minHeight: Self.minimumHeight)
        .sheet(isPresented: asking) {
            SetupSheet(model: model)
        }
    }

    private static let metrics: [Page] = [.summary, .limits, .cost, .tokens, .cache, .speed]
    private static let records: [Page] = [.activity, .calendar]

    private func row(_ page: Page) -> some View {
        Label(title(of: page), systemImage: symbol(of: page))
            .tag(page)
    }

    private var selection: Binding<Page?> {
        Binding(get: { model.page }, set: { if let page = $0 { model.page = page } })
    }

    /// Answering is what closes the sheet, so nothing here closes it.
    private var asking: Binding<Bool> {
        Binding(get: { model.setupStep != nil }, set: { _ in })
    }

    private func title(of page: Page) -> String {
        switch page {
        case .summary: String(localized: "page.summary", bundle: .tacho)
        case .limits: String(localized: "page.limits", bundle: .tacho)
        case .cost: String(localized: "page.cost", bundle: .tacho)
        case .tokens: String(localized: "page.tokens", bundle: .tacho)
        case .cache: String(localized: "page.cache", bundle: .tacho)
        case .speed: String(localized: "page.speed", bundle: .tacho)
        case .activity: String(localized: "page.activity", bundle: .tacho)
        case .calendar: String(localized: "page.calendar", bundle: .tacho)
        case .settings: String(localized: "page.settings", bundle: .tacho)
        }
    }

    private func symbol(of page: Page) -> String {
        switch page {
        case .summary: "square.grid.2x2"
        case .limits: "gauge.with.needle"
        case .cost: "dollarsign.circle"
        case .tokens: "chart.line.uptrend.xyaxis"
        case .cache: "cylinder"
        case .speed: "bolt"
        case .activity: "list.bullet.rectangle"
        case .calendar: "calendar"
        case .settings: "gearshape"
        }
    }
}

/// Said in place of a page's data when there is none to show. Old figures must not pass for current ones.
struct ProblemNote: View {
    let text: String

    /// Why this page has no figures, whether that is a question still to answer or a failure.
    init(model: AppModel) {
        text = Labels.setupNote(model) ?? String(localized: "popover.unavailable", bundle: .tacho)
    }

    /// For a part of a page that has its other figures.
    init() {
        text = String(localized: "popover.unavailable", bundle: .tacho)
    }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .preference(key: PageNoteKey.self, value: .problem)
    }
}

/// Says that macOS has the menu bar item blocked and where to allow it. With no popover to reach, Quit lives here too.
struct MenuBarBlockedNote: View {
    let quit: () -> Void
    /// The app, not a pane of it: no address of the Menu Bar pane has been proved on any macOS.
    var openSystemSettings: () -> Void = {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/System Settings.app"), configuration: .init())
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "blocked.title", bundle: .tacho))
                    .font(.callout.weight(.semibold))
                Text(String(localized: "blocked.body", bundle: .tacho))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(String(localized: "blocked.openSettings", bundle: .tacho), action: openSystemSettings)
                .fixedSize()
            Button(String(localized: "footer.quit", bundle: .tacho), action: quit)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

/// The spans a page can show.
enum RangeChoice: String, CaseIterable, Identifiable {
    case today, week, month, all

    /// The hour-of-week grid has no "today".
    static let longer: [RangeChoice] = [.week, .month, .all]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: String(localized: "range.today", bundle: .tacho)
        case .week: String(localized: "range.week", bundle: .tacho)
        case .month: String(localized: "range.month", bundle: .tacho)
        case .all: String(localized: "range.all", bundle: .tacho)
        }
    }

    /// Whole local days back from today, up to `now`.
    func timeRange(now: Date, calendar: Calendar = .current) -> TimeRange {
        let today = calendar.startOfDay(for: now)
        let start = switch self {
        case .today: today
        case .week: calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .all: Date(timeIntervalSince1970: 0)
        }
        return TimeRange(start: start, end: now)
    }
}
