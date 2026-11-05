import Foundation
import SwiftUI
import TachoKit

/// The words for what the engine reports. No figure is worked out here; these only say it.
enum Labels {
    /// The language the strings came from, for what Foundation words itself: dates, months and weekdays. A screen is in one language.
    /// The region stays the person's: it decides the order of a date and the clock.
    static let locale = locale(language: Bundle.tacho.preferredLocalizations.first ?? "en", region: Locale.current.region?.identifier)

    static func locale(language: String, region: String?) -> Locale {
        Locale(identifier: region.map { "\(language)-\($0)" } ?? language)
    }

    static func client(_ source: Source, _ raw: String) -> String {
        switch (source, raw) {
        case (_, ""): String(localized: "client.other", bundle: .tacho)
        case (.claudeCode, "cli"): String(localized: "client.terminal", bundle: .tacho)
        case (.claudeCode, "claude-desktop"), (.codex, "codex_work_desktop"): String(localized: "client.desktop", bundle: .tacho)
        case (.claudeCode, "claude-vscode"): String(localized: "client.vscode", bundle: .tacho)
        case (.claudeCode, "sdk-cli"): String(localized: "client.sdk", bundle: .tacho)
        case (.codex, "codex-tui"): String(localized: "client.cli", bundle: .tacho)
        default: raw
        }
    }

    static func provider(_ provider: QuotaProvider) -> String {
        switch provider {
        case .anthropic: String(localized: "provider.anthropic", bundle: .tacho)
        case .openai: String(localized: "provider.openai", bundle: .tacho)
        case .xai: String(localized: "provider.xai", bundle: .tacho)
        }
    }

    /// What a cost can truthfully say: "$0.83", "$0.83+" when some models have no price, "no price" when none does.
    static func cost(_ cost: CostSummary) -> String {
        guard cost.unpricedTokens > 0 else { return TokenFormat.usd(cost.usd) }
        guard cost.usd > 0 else { return String(localized: "cost.noPrice", bundle: .tacho) }
        return String(format: String(localized: "cost.partial", bundle: .tacho), TokenFormat.usd(cost.usd))
    }

    /// "≈ $0.20/h".
    static func hourlyCost(_ cost: CostSummary) -> String {
        guard cost.unpricedTokens == 0 || cost.usd > 0 else { return String(localized: "sources.hourlyNoPrice", bundle: .tacho) }
        return String(format: String(localized: "sources.hourlyCost", bundle: .tacho), figure(cost))
    }

    /// "Not counted: …", when a cost leaves something out.
    static func uncounted(_ cost: CostSummary) -> String? {
        guard cost.unpricedTokens > 0 else { return nil }
        guard !cost.unpricedModels.isEmpty else { return String(localized: "cost.uncountedUnnamed", bundle: .tacho) }
        return String(format: String(localized: "cost.uncounted", bundle: .tacho), cost.unpricedModels.joined(separator: ", "))
    }

    /// "45 min", "2 h 15 min", "3 d 4 h". Fixed forms, so that the app's own language decides them and not the system's.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded())
        if minutes < 1 { return String(localized: "duration.underMinute", bundle: .tacho) }
        if minutes < 60 { return String(format: String(localized: "duration.minutes", bundle: .tacho), minutes) }
        if minutes < 1_440 {
            return String(format: String(localized: "duration.hoursMinutes", bundle: .tacho), minutes / 60, minutes % 60)
        }
        return String(format: String(localized: "duration.daysHours", bundle: .tacho), minutes / 1_440, minutes % 1_440 / 60)
    }

    /// "≈ 42%" when the figure is inferred from local use; nil when there is no recent figure to give, which is not the same as 0%.
    static func percent(_ projection: Projection) -> String? {
        guard projection.hasRecentData else { return nil }
        let percent = "\(Int(projection.estimatedPercent.rounded()))%"
        guard projection.isEstimate else { return percent }
        return String(format: String(localized: "quota.approximate", bundle: .tacho), percent)
    }

    /// What a rate mode is called.
    static func rateMode(_ mode: RateMode) -> String {
        switch mode {
        case .output: String(localized: "rate.mode.output", bundle: .tacho)
        case .allTokens: String(localized: "rate.mode.tokens", bundle: .tacho)
        case .cost: String(localized: "rate.mode.cost", bundle: .tacho)
        }
    }

    /// The rate in `mode`: "11.2k/min", "$1.20/min", "$1.20+/min" with models left out, "no price" with none priced, never "$0".
    static func rate(_ dashboard: Dashboard, mode: RateMode, unit: RateUnit) -> String {
        switch mode {
        case .output: TokenFormat.rate(perMinute: dashboard.outputPerMinute, unit: unit)
        case .allTokens: TokenFormat.rate(perMinute: dashboard.perMinute, unit: unit)
        case .cost: costRate(dashboard.costPerMinute)
        }
    }

    /// Always per minute: a burst stretched over an hour would overstate it.
    private static func costRate(_ cost: CostSummary) -> String {
        guard cost.unpricedTokens == 0 || cost.usd > 0 else { return String(localized: "cost.noPrice", bundle: .tacho) }
        return TokenFormat.costRate(cost.usd, partial: cost.unpricedTokens > 0)
    }

    /// What the cost rate leaves out: "Excludes acme-coder-2: no price". With nothing priced there is no rate to leave it out of.
    static func rateNote(_ cost: CostSummary) -> String? {
        guard cost.unpricedTokens > 0, cost.usd > 0 else { return nil }
        guard let model = cost.unpricedModels.first else { return String(localized: "rate.excludesUnnamed", bundle: .tacho) }
        return String(format: String(localized: "rate.excludes", bundle: .tacho), model)
    }

    /// What a figure leaves out, for a card: the models by name, two at most, and the tokens.
    /// A log's stamp can run a little ahead of this Mac's clock, and that is no reason to say anything.
    private static let clockSlack: TimeInterval = 300

    /// Why Today is short: a clock set back leaves the newest logs in its future, where they do not count until it catches up.
    static func clockBehind(newestEvent: Date?, now: Date) -> String? {
        guard let newestEvent, newestEvent.timeIntervalSince(now) > clockSlack else { return nil }
        return String(localized: "today.clockBehind", bundle: .tacho)
    }

    static func notCounted(_ cost: CostSummary) -> String? {
        guard cost.unpricedTokens > 0 else { return nil }
        let tokens = TokenFormat.compact(cost.unpricedTokens)
        guard !cost.unpricedModels.isEmpty else {
            return String(format: String(localized: "cost.uncountedTokensUnnamed", bundle: .tacho), tokens)
        }
        var models = cost.unpricedModels.prefix(2).joined(separator: ", ")
        if cost.unpricedModels.count > 2 {
            models = String(format: String(localized: "more.count", bundle: .tacho), models, cost.unpricedModels.count - 2)
        }
        return String(format: String(localized: "cost.uncountedTokens", bundle: .tacho), models, tokens)
    }

    /// A figure of the 60-minute chart, under the pointer. A minute of cost goes by `figure`'s rule, so nothing priced is never $0.
    static func chartValue(_ value: Double, mode: RateMode, unpricedTokens: Int = 0) -> String {
        mode == .cost
            ? figure(CostSummary(usd: value, unpricedModels: [], unpricedTokens: unpricedTokens))
            : TokenFormat.compact(Int(value.rounded()))
    }

    /// Every figure from a `CostSummary`: cents up to $100, "$98.74+" with models left out, "no price" with none priced.
    static func figure(_ cost: CostSummary) -> String {
        guard cost.unpricedTokens == 0 || cost.usd > 0 else { return String(localized: "cost.noPrice", bundle: .tacho) }
        let figure = TokenFormat.usdFigure(cost.usd)
        guard cost.unpricedTokens > 0 else { return figure }
        return String(format: String(localized: "cost.partial", bundle: .tacho), figure)
    }

    /// `claude-opus-5-5` becomes `Opus 5.5`; anything else stays the raw id.
    static func modelShort(_ model: String) -> String {
        let parts = model.split(separator: "-").map(String.init)
        guard parts.count == 4, parts[0] == "claude", Int(parts[2]) != nil, Int(parts[3]) != nil else { return model }
        return "\(parts[1].capitalized) \(parts[2]).\(parts[3])"
    }

    /// A limit's name in a sentence: "Anthropic 5 hours", "Fable weekly".
    static func limitName(_ snapshot: QuotaSnapshot) -> String {
        if let scope = snapshot.scope {
            return String(format: String(localized: "limit.name.scoped", bundle: .tacho), scope)
        }
        return String(format: String(localized: snapshot.window == .fiveHour ? "limit.name.fiveHour" : "limit.name.weekly", bundle: .tacho), provider(snapshot.provider))
    }

    /// "16:52", in the person's own clock.
    static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(time: .shortened).locale(locale))
    }

    /// A time with its day unless that is today, by the calendar's days and not by seconds: at 23:00, 09:00 tomorrow is ten hours off and still
    /// another day. Tomorrow goes by name and other days by the weekday, until a week either side, where the weekday would read as today's.
    static func reset(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = Labels.locale, bundle: Bundle = .tacho) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(Date.FormatStyle(time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        switch calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0 {
        case 0: return time
        case 1: return String(format: String(localized: "time.tomorrow", bundle: bundle), time)
        case -6...6: return date.formatted(style.weekday(.abbreviated).hour().minute())
        // In two parts, as a row of the log is: as one style it brings back the year, and "at".
        default: return String(format: String(localized: "log.dayTime", bundle: bundle), date.formatted(style.month(.abbreviated).day()), time)
        }
    }

    /// The gap between two times printed to the minute, from those minutes: what a reader gets by subtracting them, which the moments themselves
    /// can be a minute off. Anything that prints two times and the gap between them takes the gap from here.
    static func gap(from start: Date, to end: Date) -> String {
        func minute(_ date: Date) -> TimeInterval { (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 }
        return duration(minute(end) - minute(start))
    }

    /// "updated 5 min ago".
    static func updated(_ age: TimeInterval) -> String {
        age < 60
            ? String(localized: "quota.updatedJustNow", bundle: .tacho)
            : String(format: String(localized: "quota.updatedAgo", bundle: .tacho), duration(age))
    }

    /// The largest unit only, for a tight cell: "7 d", "5 h", "12 min".
    static func ageShort(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded())
        if minutes < 60 { return String(format: String(localized: "age.minutes", bundle: .tacho), minutes) }
        if minutes < 1_440 { return String(format: String(localized: "age.hours", bundle: .tacho), minutes / 60) }
        return String(format: String(localized: "age.days", bundle: .tacho), minutes / 1_440)
    }

    // MARK: The rules of spec §8, in words. Which one fires is `Insights.compute`'s business.

    /// Rules H: today against usual.
    static func sentence(_ rule: TodayRule) -> String {
        switch rule {
        case .h1: String(localized: "highlight.h1", bundle: .tacho)
        case .h1h: String(localized: "highlight.h1h", bundle: .tacho)
        case .h2(let soFar):
            // Today is the last day it takes, and the range is taken over finished days.
            soFar >= UsualRange.minimumDays ? String(localized: "highlight.h2Tomorrow", bundle: .tacho) : String(format: String(localized: "highlight.h2", bundle: .tacho), soFar)
        case .h3: String(localized: "highlight.h3", bundle: .tacho)
        case .h4(let times): String(format: String(localized: "highlight.h4", bundle: .tacho), String(format: "%.1f", times))
        case .h5(let percent): String(format: String(localized: "highlight.h5", bundle: .tacho), percent)
        case .h5s: String(localized: "highlight.h5s", bundle: .tacho)
        case .h6: String(localized: "highlight.h6", bundle: .tacho)
        case .h7(let percent): String(format: String(localized: "highlight.h7", bundle: .tacho), percent)
        case .h7s: String(localized: "highlight.h7s", bundle: .tacho)
        case .h7f: String(localized: "highlight.h7f", bundle: .tacho)
        case .h8: String(localized: "highlight.h8", bundle: .tacho)
        case .h9: String(localized: "highlight.h9", bundle: .tacho)
        }
    }

    /// Rules L, and how loudly each is said. A rule that needs a limit and has none says nothing rather than something false.
    static func limitSay(_ insight: LimitsInsight, now: Date, calendar: Calendar = .current) -> (String?, Tone) {
        let limit = insight.limit
        let name = limit.map { limitName($0.snapshot) }
        let resetsAt = limit.map { reset($0.resetsAt, now: now, calendar: calendar) }
        switch insight.rule {
        case .l1:
            guard let name, let resetsAt else { return (nil, .plain) }
            return (String(format: String(localized: "limit.say.usedUp", bundle: .tacho), name, resetsAt), .critical)
        case .l2:
            guard let limit, let name, let resetsAt else { return (nil, .plain) }
            return (String(format: String(localized: "limit.say.high", bundle: .tacho), name, percent(limit) ?? "", resetsAt), .critical)
        case .l3:
            guard let limit, let name, let resetsAt, case .runsOut(let at, _) = limit.outcome else { return (nil, .plain) }
            return (String(format: String(localized: "limit.say.pace", bundle: .tacho), name, reset(at, now: now, calendar: calendar), gap(from: at, to: limit.resetsAt), resetsAt), .warning)
        case .l4: return (String(localized: "limit.say.clear", bundle: .tacho), .plain)
        case .l5: return (String(localized: "limit.say.noRisk", bundle: .tacho), .plain)
        case .l6: return (String(localized: "limit.say.noRecent", bundle: .tacho), .plain)
        case .l7: return (String(localized: "limit.say.noQuota", bundle: .tacho), .plain)
        case .l8: return (String(localized: "limit.say.waiting", bundle: .tacho), .plain)
        case .l9: return (String(localized: "limit.say.noQuotaOther", bundle: .tacho), .plain)
        }
    }

    /// What today is usually by now: under the Cost today card. While logs are being read it says nothing.
    static func usual(_ insight: TodayInsight, now: Date) -> String? {
        if insight.rule == .h1 || insight.rule == .h1h { return nil }
        guard let range = insight.range else { return String(localized: "usual.none", bundle: .tacho) }
        let median = switch insight.metric {
        case .cost: figure(CostSummary(usd: range.median, unpricedModels: [], unpricedTokens: 0))
        case .output: TokenFormat.compact(Int(range.median.rounded()))
        }
        return String(format: String(localized: "usual.median", bundle: .tacho), median, clock(now))
    }

    /// Rules P1 to P4: the Output card.
    static func say(_ rule: OutputRule) -> String {
        switch rule {
        case .p1: String(localized: "say.output.above", bundle: .tacho)
        case .p2: String(localized: "say.output.inside", bundle: .tacho)
        case .p3: String(localized: "say.output.below", bundle: .tacho)
        case .p4(let daysLeft): String(format: String(localized: "say.needsDays", bundle: .tacho), daysLeft)
        case .p4s: String(localized: "say.needsDay", bundle: .tacho)
        case .readingLogs: String(localized: "reading.logs", bundle: .tacho)
        }
    }

    /// Rule P13: the All tokens card.
    static func cacheReads(_ percent: Int) -> String {
        String(format: String(localized: "say.cacheReads", bundle: .tacho), percent)
    }

    /// Rule P14: the When you work card.
    static func say(_ rule: WhenRule, calendar: Calendar = .current) -> String {
        switch rule {
        case .p14(let row, let from, let to):
            var calendar = calendar
            calendar.locale = locale
            let weekday = calendar.shortWeekdaySymbols[(calendar.firstWeekday - 1 + row) % 7]
            return String(format: String(localized: "say.when.busiest", bundle: .tacho), weekday, hour(from, calendar), hour(to, calendar))
        case .needsDays(let left):
            return left == 1 ? String(localized: "say.needsDay", bundle: .tacho) : String(format: String(localized: "say.needsDays", bundle: .tacho), left)
        case .readingLogs:
            return String(localized: "reading.logs", bundle: .tacho)
        }
    }

    /// An hour of no day in particular, as a clock shows it. The day chosen has no daylight saving change anywhere.
    private static func hour(_ hour: Int, _ calendar: Calendar) -> String {
        clock(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date(timeIntervalSinceReferenceDate: 86_400)) ?? .distantPast)
    }

    /// Rules P5 to P7: the Cache card.
    static func say(_ rule: CacheRule) -> String {
        switch rule {
        case .p5(let usd): String(format: String(localized: "say.cache.kept", bundle: .tacho), figure(CostSummary(usd: usd, unpricedModels: [], unpricedTokens: 0)))
        case .p6(let usd): String(format: String(localized: "say.cache.keptPartial", bundle: .tacho), figure(CostSummary(usd: usd, unpricedModels: [], unpricedTokens: 0)))
        case .p7: String(localized: "cost.noPrice", bundle: .tacho)
        }
    }

    /// Rules P4 and P8 to P11: the Speed card.
    static func say(_ rule: SpeedRule, model: String) -> String {
        let short = modelShort(model)
        return switch rule {
        case .p4(let daysLeft): String(format: String(localized: "say.needsDays", bundle: .tacho), daysLeft)
        case .p4s: String(localized: "say.needsDay", bundle: .tacho)
        case .p8: String(format: String(localized: "say.speed.usual", bundle: .tacho), short)
        case .p9: String(format: String(localized: "say.speed.faster", bundle: .tacho), short)
        case .p10: String(format: String(localized: "say.speed.slower", bundle: .tacho), short)
        case .readingLogs: String(localized: "reading.logs", bundle: .tacho)
        }
    }

    /// Why there are no figures yet, while the first-launch question stands; nil once it is answered.
    @MainActor static func setupNote(_ model: AppModel) -> String? {
        guard !model.preferences.askedAboutSources else { return nil }
        return String(localized: model.sourcesAcknowledged ? "setup.none" : "setup.waiting", bundle: .tacho)
    }

    static func speed(_ speed: ModelSpeed) -> String {
        tokensPerSecond(speed.tokensPerSecond, approximate: speed.approximate)
    }

    static func tokensPerSecond(_ speed: Double, approximate: Bool) -> String {
        String(format: String(localized: approximate ? "today.speedApproximate" : "today.speed", bundle: .tacho), Int(speed.rounded()))
    }

    /// A model by its id. The engine reports requests that name none under "", which TachoKit leaves for the interface to word.
    static func model(_ key: String) -> String {
        key.isEmpty ? String(localized: "overview.noModel", bundle: .tacho) : key
    }

    /// A project by the last part of its path; the same "" rule as `model`.
    static func project(_ key: String) -> String {
        key.isEmpty ? String(localized: "overview.noProject", bundle: .tacho) : (key as NSString).lastPathComponent
    }

    /// "Claude Code · Terminal", or the source alone when the request names no client.
    static func source(of event: UsageEvent) -> String {
        guard let raw = event.client, !raw.isEmpty else { return event.source.displayName }
        return String(format: String(localized: "log.sourceClient", bundle: .tacho), event.source.displayName, client(event.source, raw))
    }

    /// One request's cost: "no price" is not the same as nothing.
    static func logCost(_ usd: Double?) -> String {
        usd.map(TokenFormat.usd) ?? String(localized: "cost.noPrice", bundle: .tacho)
    }

    static func logSpeed(_ row: LogRow) -> String {
        row.tokensPerSecond.map { tokensPerSecond($0, approximate: row.approximateSpeed) } ?? "–"
    }

    /// A rate of the price table, in full: "$1.25", "$0.075".
    static func priceRate(_ usd: Double) -> String {
        "$" + String(format: "%g", usd)
    }

    /// The backfill's progress line; nil once it is done.
    static func progress(_ progress: IngestProgress) -> String? {
        switch progress.phase {
        case .live:
            nil
        case .idle:
            String(localized: "progress.starting", bundle: .tacho)
        case .recent:
            String(format: String(localized: "progress.recent", bundle: .tacho), progress.filesDone, progress.filesTotal)
        case .history:
            String(format: String(localized: "progress.history", bundle: .tacho), progress.filesDone, progress.filesTotal)
        }
    }
}

/// The four token categories, in the order they are always shown.
enum TokenCategory: CaseIterable {
    case input, output, cacheRead, cacheWrite

    var name: String {
        switch self {
        case .input: String(localized: "category.input", bundle: .tacho)
        case .output: String(localized: "category.output", bundle: .tacho)
        case .cacheRead: String(localized: "category.cacheRead", bundle: .tacho)
        case .cacheWrite: String(localized: "category.cacheWrite", bundle: .tacho)
        }
    }

    func usd(in cost: CategoryCost) -> Double {
        switch self {
        case .input: cost.input
        case .output: cost.output
        case .cacheRead: cost.cacheRead
        case .cacheWrite: cost.cacheWrite
        }
    }

    func tokens(in counts: TokenCounts) -> Int {
        switch self {
        case .input: counts.input
        case .output: counts.output
        case .cacheRead: counts.cacheRead
        case .cacheWrite: counts.cacheWrite
        }
    }

    /// A fixed hue per category, from `Theme`.
    var color: Color {
        switch self {
        case .input: Theme.input
        case .output: Theme.output
        case .cacheRead: Theme.cacheRead
        case .cacheWrite: Theme.cacheWrite
        }
    }
}
