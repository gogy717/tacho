import Foundation
import Observation
import TachoKit

/// The pages of the main window. The raw values are what `-TachoPage` takes.
enum Page: String, CaseIterable, Hashable {
    case summary, limits, cost, tokens, cache, speed, activity, calendar, settings
}

/// What the first-launch sheet asks next.
enum SetupStep: Equatable {
    case sources, consent, ready
}

/// What the interface shows, and the one place it talks to the `Engine`.
@MainActor @Observable
final class AppModel {
    private static let preferencesKey = "preferences"
    private static let refreshInterval: Duration = .seconds(1)
    private static let insightsInterval: TimeInterval = 60
    /// Longer than a double-click.
    private static let consentPause: Duration = .milliseconds(500)

    /// The latest figures. nil until the first ones arrive, and whenever they cannot be read: old figures must not pass for current ones.
    private(set) var dashboard: Dashboard? {
        didSet { pageInputs += 1 }
    }
    /// Moves with whatever a page builds its state from here, so that a look can tell at no cost that there is nothing to see. What a
    /// page reads for itself, or a person changes, it looks at when that happens.
    @ObservationIgnored private(set) var pageInputs = 0
    /// When `dashboard` was computed, for the "updated N min ago" lines.
    private(set) var refreshedAt = Date()
    /// `refreshedAt`, moved on by the first tick of each minute: the window's pages say nothing finer, and what a body reads redraws
    /// its page whenever it moves, which `refreshedAt` does every second.
    private(set) var pageClock = Date() {
        didSet { pageInputs += 1 }
    }
    /// Older logs are still coming in, or there are no figures to say otherwise. For the pages that need only this of the figures:
    /// it moves when the phase does, where `dashboard` moves on most ticks.
    private(set) var isReadingLogs = true
    /// The engine could not be opened, or the last refresh failed.
    private(set) var isFailing: Bool
    var indexWasSetAside: Bool { engine?.indexWasSetAside ?? false }
    /// The last `save` could not be written. The new preferences still apply until the app quits.
    private(set) var couldNotSave = false
    private(set) var preferences: Preferences
    var page: Page
    /// What a card asked of `page`, until that page reads it: `takeRoute`.
    private(set) var pendingRoute: Route?
    /// The panel's slower figures. nil until the first answer, and whenever they cannot be read.
    private(set) var insights: PanelInsights?
    /// When they were last asked for, whatever the answer.
    private var insightsAskedAt: Date?
    /// Moves on when an answer still being read can no longer be trusted.
    private var insightsEpoch = 0
    /// Every log was in, at the last look.
    private var isLive = false
    /// Loops of `whilePanelOpen`: one, while the panel is open.
    private var panelLoops = 0
    /// Where they come from.
    var readInsights: @Sendable (Engine, Date) async throws -> PanelInsights = { try await $0.insights(now: $1) }
    /// How preferences reach the engine.
    var applyToEngine: @Sendable (Engine, Preferences) async -> Void = { await $0.apply($1) }
    /// The main window is open and at least partly on screen.
    var mainWindowVisible = false {
        didSet {
            if mainWindowVisible, !oldValue { warmDefaultsIfReady() }
        }
    }
    /// Polling loops running now, one for each `whileShowing` and one for an open panel. None survive their window.
    private(set) var activePolls = 0
    /// Whether the status item should be in the menu bar. False once macOS has taken it away.
    var menuBarItemInserted = true
    /// macOS does not allow the status item, so the main window is the only way in.
    var menuBarBlocked = false {
        didSet { pageInputs += 1 }
    }
    /// Settings asked for the consent sheet, to turn the Anthropic query on.
    private(set) var consentRequested = false
    /// No CLI was found to choose from. The defaults stay, and the next launch asks again.
    private(set) var sourcesAcknowledged = false
    /// The first-launch answers have just started reading, and the sheet still has to say where Tacho went. Gone with the launch.
    private(set) var showsReady = false
    /// When the chooser last gave way to the next step.
    private var sourcesAnsweredAt: ContinuousClock.Instant?

    let home: URL
    /// The language this run started in, which is the one it stays in.
    let launchLanguage: AppLanguage

    /// nil until the first-launch chooser is answered, so that nothing can be read before it, and built from that answer: `apply` would
    /// rescan everything in one go, without the backfill's recent-first order or its progress. Also nil when the database could not be
    /// opened. The app then stays up and says so: a menu bar app that stops at launch tells nobody why.
    private(set) var engine: Engine?

    private let defaults: UserDefaults
    private let support: URL
    private let launch: @Sendable (Engine) async -> Void
    private let priceOverridesFile: URL
    /// What the overrides file is known to hold. A save compares with this, not with `preferences`, so a failed write is tried again.
    private var storedOverrides: [String: PriceEntry]
    private var refreshing: Task<Void, Never>?
    private var applying: Task<Void, Never>?
    /// Answers a page has already shown. Writes here do not redraw: nothing in a body reads it.
    private let figures = FigureMemory()
    /// The local day `figures` belongs to. A different day drops them.
    private var figuresDay: Date?
    /// Moves when remembered figures are dropped, so the open page reads again instead of keeping them.
    private(set) var figuresEpoch = 0
    /// What the chart pages keep while they are not showing.
    let chart = ChartSession()
    /// The default ranges are warmed once, not on any later tick.
    private var warmed = false
    private var warming: Task<Void, Never>?

    /// - Parameter launch: `Engine.start` in the app. Tests pass their own, to see when it would run.
    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = .standard,
        launch: @escaping @Sendable (Engine) async -> Void = { await $0.start() }
    ) {
        let support = home.appendingPathComponent("Library/Application Support/Tacho", isDirectory: true)
        self.home = home
        self.defaults = defaults
        self.support = support
        self.launch = launch
        page = defaults.string(forKey: "TachoPage").flatMap(Page.init(rawValue:)) ?? .summary
        priceOverridesFile = support.appendingPathComponent("price-overrides.json")
        let preferences = Self.loadPreferences(home: home, defaults: defaults, priceOverridesFile: priceOverridesFile)
        self.preferences = preferences
        launchLanguage = preferences.language
        storedOverrides = preferences.priceOverrides
        let engine = preferences.askedAboutSources ? Self.makeEngine(home: home, support: support, preferences: preferences) : nil
        self.engine = engine
        isFailing = preferences.askedAboutSources && engine == nil
        figuresDay = Calendar.current.startOfDay(for: Date())
    }

    private static func makeEngine(home: URL, support: URL, preferences: Preferences) -> Engine? {
        try? Engine(databaseURL: support.appendingPathComponent("tacho.sqlite"), home: home, preferences: preferences)
    }

    /// Whether the main window belongs on screen when the app starts.
    var opensMainWindowAtLaunch: Bool {
        defaults.bool(forKey: "TachoOpenMainWindow") || setupStep != nil
    }

    /// What the first-launch sheet asks now; nil once nothing is left to ask.
    var setupStep: SetupStep? {
        if !preferences.askedAboutSources, !sourcesAcknowledged { return .sources }
        if isAskingConsent { return .consent }
        return showsReady ? .ready : nil
    }

    /// The CLIs on this Mac: those with a root that exists. A look at the paths only; nothing in them is opened.
    var detectedSources: [Source] {
        Source.allCases.filter { source in
            (preferences.roots.roots[source] ?? []).contains { FileManager.default.fileExists(atPath: $0) }
        }
    }

    /// What Settings lists before the first-launch answer, when there is no engine to ask. It has to list something: a CLI outside the
    /// default paths is found only by adding its path there. nil once answered, when a missing engine is a problem to say.
    var statusesBeforeEngine: [SourceStatus]? {
        guard !preferences.askedAboutSources else { return nil }
        let detected = detectedSources
        return Source.allCases.map { source in
            SourceStatus(
                source: source,
                roots: preferences.roots.roots[source] ?? [],
                detected: detected.contains(source),
                enabled: preferences.enabledSources.contains(source),
                files: 0,
                events: 0,
                skipped: 0,
                lastUpdate: nil
            )
        }
    }

    /// The first-launch answer. `chosen` becomes `enabledSources`; nil means there was nothing to choose from.
    func answerSources(_ chosen: Set<Source>?) {
        guard !preferences.askedAboutSources else { return }
        sourcesAnsweredAt = .now
        guard let chosen else {
            sourcesAcknowledged = true
            return
        }
        var answered = preferences
        answered.askedAboutSources = true
        answered.enabledSources = chosen
        save(answered)
        engine = Self.makeEngine(home: home, support: support, preferences: answered)
        isFailing = engine == nil
        showsReady = engine != nil
        start()
    }

    /// The last first-launch step is read, and reading goes on without it.
    func finishSetup() {
        showsReady = false
    }

    /// Goes to `route`'s page, and leaves the rest for that page to read.
    func open(_ route: Route) {
        page = route.page
        pendingRoute = route == Route(page: route.page) ? nil : route
    }

    /// What was asked of `page`, once: a card may aim at the page already showing, so a page reads this whenever it changes.
    func takeRoute(for page: Page) -> Route? {
        guard let route = pendingRoute, route.page == page else { return nil }
        pendingRoute = nil
        return route
    }

    private func isShowing(_ page: Page) -> Bool {
        mainWindowVisible && self.page == page
    }

    /// Runs `work`, then again every `interval` until the calling task ends, but only while `page` is on screen in the main window.
    /// - Parameter startNow: false when the caller has just done the work itself.
    func whileShowing(_ page: Page, every interval: Duration, startNow: Bool = true, _ work: @MainActor () async -> Void) async {
        activePolls += 1
        defer { activePolls -= 1 }
        if startNow { await work() }
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if !Task.isCancelled, isShowing(page) { await work() }
        }
    }

    /// Reads the panel's slower figures, at most once a minute. A failed read counts, so that it is not tried again on every call.
    func refreshInsights(now: Date = Date()) async {
        guard let engine else { return }
        if let asked = insightsAskedAt, now.timeIntervalSince(asked) < Self.insightsInterval { return }
        insightsAskedAt = now
        let epoch = insightsEpoch
        let latest = try? await readInsights(engine, now)
        guard epoch == insightsEpoch else { return }
        if latest != insights { insights = latest }
    }

    /// What the slower figures may say depends on every log being in, so crossing `.live` ends the old answer at once: comparisons
    /// must not sit beside a rebuild, nor "still reading logs" outlast one. A backfill crosses it at most twice, and this is the only
    /// read the tick can cause.
    private func follow(isLive now: Bool) {
        guard now != isLive else { return }
        isLive = now
        insightsEpoch += 1
        insightsAskedAt = nil
        if !now { insights = nil }
        if panelLoops > 0 { Task { await refreshInsights() } }
        if now { warmDefaultsIfReady() }
    }

    /// For as long as the calling task runs: the slower figures at once, then once a minute.
    func whilePanelOpen() async {
        activePolls += 1
        panelLoops += 1
        defer {
            activePolls -= 1
            panelLoops -= 1
        }
        while !Task.isCancelled {
            await refreshInsights()
            try? await Task.sleep(for: .seconds(Self.insightsInterval))
        }
    }

    /// The consent sheet is due: at first launch, or because Settings asked for it.
    var isAskingConsent: Bool {
        !preferences.askedAboutAnthropicQuery || consentRequested
    }

    /// What the rate shows, in the panel and the menu bar.
    func setRateMode(_ mode: RateMode) {
        var changed = preferences
        changed.rateMode = mode
        save(changed)
    }

    func requestConsent() {
        consentRequested = true
    }

    func turnOffAnthropicQuery() {
        var changed = preferences
        changed.anthropicQueryEnabled = false
        save(changed)
    }

    /// The only code that turns the Anthropic query on: the user has seen what it reads, where it goes and how often.
    func answerConsent(allow: Bool) {
        // Continue and Allow nearly coincide when the sheet swaps, so the second click of a double-click lands here. Allow has to be a
        // decision: it reads the Keychain and sends a token. Not now costs nothing, so it needs no pause.
        if allow, let answered = sourcesAnsweredAt, answered.duration(to: .now) < Self.consentPause { return }
        consentRequested = false
        var answered = preferences
        answered.askedAboutAnthropicQuery = true
        if allow { answered.anthropicQueryEnabled = true }
        save(answered)
    }

    /// Takes effect at the next launch: the language is read from the app's defaults as it starts.
    func setLanguage(_ language: AppLanguage) {
        var changed = preferences
        changed.language = language
        save(changed)
        switch language {
        case .system: defaults.removeObject(forKey: "AppleLanguages")
        case .en: defaults.set(["en"], forKey: "AppleLanguages")
        case .zhHans: defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        }
    }

    /// Returns once the engine has every preference it reads, of those saved so far.
    func settled() async {
        await applying?.value
    }

    /// Starts the engine, then refreshes `dashboard` every second. Before the first-launch answer there is no engine, so nothing starts.
    func start() {
        guard let engine, refreshing == nil else { return }
        let launch = self.launch
        let previous = applying
        applying = Task {
            await previous?.value
            await launch(engine)
        }
        refreshing = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(from: engine)
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    /// Whether `new` says anything the engine must hear, since being told anything makes it throw away its day's caches. The settings
    /// here are the interface's alone. Anything else reaches it, so that a new setting is safe until someone says otherwise.
    static func reachesEngine(from old: Preferences, to new: Preferences) -> Bool {
        var compared = new
        compared.rateMode = old.rateMode
        compared.rateUnit = old.rateUnit
        compared.menuBarStyle = old.menuBarStyle
        compared.language = old.language
        compared.pinnedCards = old.pinnedCards
        return compared != old
    }

    /// Keeps `preferences`, stores them, and hands the engine any change it reads, in the order they were saved.
    func save(_ preferences: Preferences) {
        let changed = preferences != self.preferences
        let reachesEngine = Self.reachesEngine(from: self.preferences, to: preferences)
        self.preferences = preferences
        if changed { dropFigures() }
        couldNotSave = !store(preferences)
        // Settings gained a path that exists: there is something to choose from after all.
        if sourcesAcknowledged, !detectedSources.isEmpty { sourcesAcknowledged = false }

        guard reachesEngine, let engine else { return }
        let previous = applying
        let apply = applyToEngine
        applying = Task {
            await previous?.value
            await apply(engine, preferences)
        }
    }

    /// Takes new figures: the only way they arrive.
    func apply(_ latest: Dashboard) {
        // Unchanged figures are not assigned, so an idle menu bar is not redrawn every second.
        let settled = latest.settled(on: dashboard)
        if settled != dashboard { dashboard = settled }
        let isReading = latest.progress.phase != .live
        if isReading != isReadingLogs { isReadingLogs = isReading }
        isFailing = false
        follow(isLive: latest.progress.phase == .live)
    }

    private func refresh(from engine: Engine) async {
        let now = Date()
        do {
            tick(try await engine.dashboard(now: now), at: now)
        } catch {
            tickFailed(at: now)
        }
    }

    /// The figures could not be read at `now`.
    func tickFailed(at now: Date) {
        dashboard = nil
        isReadingLogs = true
        isFailing = true
        moveClocks(to: now)
    }

    /// One second's figures, read at `now`.
    func tick(_ latest: Dashboard, at now: Date) {
        apply(latest)
        moveClocks(to: now)
    }

    private func moveClocks(to now: Date) {
        refreshedAt = now
        // The day is compared when the minute moves, not on every tick: a page is not read from here.
        if Self.minute(of: now) != Self.minute(of: pageClock) {
            pageClock = now
            noteDay(now, calendar: .current)
        }
    }

    /// The last answer for `ask`, when it was remembered today. A different day drops every answer first.
    func remembered(_ ask: FigureAsk, now: Date = Date(), calendar: Calendar = .current) -> FigureAnswer? {
        noteDay(now, calendar: calendar)
        return figures.answer(for: ask)
    }

    /// Keeps `answer` for `ask`, and forgets the oldest once more than a dozen are held.
    func remember(_ answer: FigureAnswer, for ask: FigureAsk, now: Date = Date(), calendar: Calendar = .current) {
        noteDay(now, calendar: calendar)
        figures.store(answer, for: ask)
    }

    /// Drops remembered figures and rebuilds the index. With no engine there is nothing to rebuild, and the figures still go:
    /// a rebuild that could not start must not leave the old ones looking current.
    func rebuildIndex() async throws {
        dropFigures()
        guard let engine else { return }
        defer { dropFigures() }
        try await engine.rebuildIndex()
    }

    /// The local day changed. Yesterday's answers are not today's.
    private func noteDay(_ now: Date, calendar: Calendar) {
        let day = calendar.startOfDay(for: now)
        guard figuresDay != day else { return }
        figuresDay = day
        figures.removeAll()
        figuresEpoch += 1
    }

    private func dropFigures() {
        figures.removeAll()
        figuresEpoch += 1
    }

    /// Once the logs are in and the window is open: the four pages' default ranges, one at a time, off the tick.
    /// Measured read-only on a full store: a month's quarter-hour groups about 70 ms, the first 90-day walk about 40 ms, a week about
    /// 16 ms. The three reads together stay under a second, and they are the wait Cost's first open would otherwise spend on the click.
    private func warmDefaultsIfReady() {
        guard !warmed, isLive, mainWindowVisible, engine != nil else { return }
        warmed = true
        warming = Task(priority: .utility) { [weak self] in
            await self?.warmDefaults()
        }
    }

    private func warmDefaults() async {
        guard let engine else { return }
        let now = Date()
        if let month = try? await engine.detail(range: .month, now: now) {
            remember(.detail(month), for: FigureAsk(page: .cost, range: .month), now: now)
        }
        guard !Task.isCancelled else { return }
        await Task.yield()
        if let week = try? await engine.detail(range: .week, now: now) {
            remember(.detail(week), for: FigureAsk(page: .tokens, range: .week), now: now)
            remember(.detail(week), for: FigureAsk(page: .cache, range: .week), now: now)
        }
        guard !Task.isCancelled else { return }
        await Task.yield()
        if let speed = try? await engine.speed(range: .week, model: nil, now: now) {
            remember(.speed(speed), for: FigureAsk(page: .speed, range: .week), now: now)
        }
    }

    private static func minute(of date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / 60)
    }

    private static func loadPreferences(home: URL, defaults: UserDefaults, priceOverridesFile: URL) -> Preferences {
        let stored = defaults.data(forKey: preferencesKey)
        var preferences = stored.flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? .defaults(home: home)
        if let file = try? Data(contentsOf: priceOverridesFile),
           let overrides = try? JSONDecoder().decode([String: PriceEntry].self, from: file) {
            preferences.priceOverrides = overrides
        }
        return preferences
    }

    /// Price overrides live in their own file, so the rest goes to the defaults with none. That file is written only when they
    /// differ from what it holds: one that could not be read at launch must not be replaced by the empty set this run started from.
    private func store(_ preferences: Preferences) -> Bool {
        var withoutOverrides = preferences
        withoutOverrides.priceOverrides = [:]
        do {
            defaults.set(try JSONEncoder().encode(withoutOverrides), forKey: Self.preferencesKey)
            if preferences.priceOverrides != storedOverrides {
                try FileManager.default.createDirectory(at: priceOverridesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(preferences.priceOverrides).write(to: priceOverridesFile, options: .atomic)
                storedOverrides = preferences.priceOverrides
            }
            return true
        } catch {
            return false
        }
    }
}

/// Whether a page's once-a-second look has anything to see.
@MainActor
final class PageLook {
    private var seen: Int?

    func isDue(_ inputs: Int) -> Bool {
        defer { seen = inputs }
        return inputs != seen
    }
}

private extension Dashboard {
    /// While a pace holds, a forecast's moment moves on with the clock, so no two ticks would be equal and each one would redraw
    /// whatever reads the figures. Nothing shows it finer than the minute, so a limit keeps the moment it has until that is a minute
    /// out. Only the moment waits: any other change to a limit, or to anything else, comes through as it did.
    func settled(on kept: Dashboard?) -> Dashboard {
        guard let kept, kept.quotas.count == quotas.count else { return self }
        var settled = self
        for (index, quota) in quotas.enumerated() {
            let old = kept.quotas[index]
            guard quota.snapshot == old.snapshot,
                  quota.resetsAt == old.resetsAt,
                  case .runsOut(let moment, _) = quota.outcome,
                  case .runsOut(let keptMoment, _) = old.outcome,
                  abs(moment.timeIntervalSince(keptMoment)) < 60 else { continue }
            settled.quotas[index].outcome = old.outcome
        }
        return settled
    }
}

/// What a page asked for. A different page, range or model is a different answer, so one range's figures never stand in for another's.
struct FigureAsk: Hashable, Sendable {
    var page: Page
    var range: String
    var model: String
    /// What a chart page stacks by: a stacked answer holds what another does not.
    var grouping: DetailGrouping?

    init(page: Page, range: DetailRange, model: String? = nil, grouping: DetailGrouping? = nil) {
        self.page = page
        self.range = range.rawValue
        self.model = model ?? ""
        self.grouping = grouping
    }

    init(page: Page, span: RangeChoice) {
        self.page = page
        self.range = span.rawValue
        self.model = ""
    }

    /// The activity log's filter. An empty piece means anything, which is not the same as a name.
    init(page: Page, source: Source?, project: String?, modelName: String?, search: String) {
        self.page = page
        self.range = "\(source?.rawValue ?? "")\u{1}\(project ?? "")\u{1}\(search)"
        self.model = modelName ?? ""
    }
}

/// An answer a page can show again without waiting.
enum FigureAnswer: Equatable, Sendable {
    case detail(DetailFigures)
    case speed(SpeedFigures)
    case heatmaps(Heatmaps)
    case activity(rows: [LogRow], hasMore: Bool, summary: LogSummary?)
}

/// A dozen answers, newest last. A class, so filling it does not publish a change through `AppModel`.
@MainActor private final class FigureMemory {
    static let limit = 12

    private var order: [FigureAsk] = []
    private var answers: [FigureAsk: FigureAnswer] = [:]

    func answer(for ask: FigureAsk) -> FigureAnswer? {
        guard let answer = answers[ask] else { return nil }
        order.removeAll { $0 == ask }
        order.append(ask)
        return answer
    }

    func store(_ answer: FigureAnswer, for ask: FigureAsk) {
        order.removeAll { $0 == ask }
        order.append(ask)
        answers[ask] = answer
        while order.count > Self.limit {
            answers[order.removeFirst()] = nil
        }
    }

    func removeAll() {
        order.removeAll()
        answers.removeAll()
    }
}
