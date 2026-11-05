import Foundation
import TachoKit

extension Projection {
    /// The engine's rule, not a copy of it: `summarySay` reads only the limit.
    var isUsedUp: Bool {
        LimitsInsight(rule: .l1, limit: self).summarySay == .wl1
    }
}

/// The window's words for what the engine reports. As in `Labels`, no figure is worked out here.
enum WindowLabels {
    /// Rules W: output this week, spec section 11.1.
    static func sentence(_ rule: WeekRule) -> String {
        switch rule {
        case .w1(let percent): String(format: String(localized: "week.up", bundle: .tacho), percent)
        case .w2(let percent): String(format: String(localized: "week.down", bundle: .tacho), percent)
        case .w3: String(localized: "week.same", bundle: .tacho)
        case .w4(let soFar): String(format: String(localized: "week.needsDays", bundle: .tacho), soFar)
        case .w5: String(localized: "week.nothingBefore", bundle: .tacho)
        case .w6: String(localized: "week.reading", bundle: .tacho)
        }
    }

    /// Rules D: the Cost page, spec section 12.2. D1 is the sentence from Cost today, which only the panel's answer has.
    static func sentence(_ rule: CostHighlight, today: TodayRule?) -> String? {
        func say(_ key: String.LocalizationValue, _ values: any CVarArg...) -> String {
            String(format: String(localized: key, bundle: .tacho), arguments: values)
        }
        return switch rule {
        case .d1: today.map(Labels.sentence)
        case .d2(let cost): say("rule.d2", Labels.figure(cost))
        case .d3(let tokens, let cost): say("rule.d3", tokens, cost)
        case .d4(let percent): say("rule.d4", percent)
        case .d5(let percent): say("rule.d5", percent)
        case .d6: say("rule.d6")
        case .d7(let days, let percent): days == 1 ? say("rule.d7.one", percent) : say("rule.d7", days, percent)
        case .d8(let from, let to): say("rule.d8", from, to)
        case .d9(let percent): say("rule.d9", percent)
        case .d10(let percent): say("rule.d10", percent)
        case .d11: say("rule.d11")
        case .d12(let days): days == 1 ? say("rule.d12.one") : say("rule.d12", days)
        case .d13(let days): days == 1 ? say("rule.d13.one") : say("rule.d13", days)
        case .d14(let month, let cost): say("rule.d14", month.formatted(Date.FormatStyle().month(.wide).locale(Labels.locale)), Labels.figure(cost))
        case .d15(let days): days == 1 ? say("rule.d15.one") : say("rule.d15", days)
        }
    }

    /// Rules T: the Tokens page, spec section 12.3.
    static func sentence(_ rule: TokenHighlight) -> String {
        switch rule {
        case .t1(let percent): String(format: String(localized: "rule.t1", bundle: .tacho), percent)
        case .t2(let percent): String(format: String(localized: "rule.t2", bundle: .tacho), percent)
        }
    }

    /// Rules K: the Cache page, spec section 12.4.
    static func sentence(_ rule: CacheHighlight) -> String {
        switch rule {
        case .k1(let from, let to): String(format: String(localized: "rule.k1", bundle: .tacho), oneDecimal(from), oneDecimal(to))
        case .k2(let rate): String(format: String(localized: "rule.k2", bundle: .tacho), oneDecimal(rate))
        case .k3(let tokens, let cost): String(format: String(localized: "rule.k3", bundle: .tacho), tokens, cost)
        case .k4(let usd, let tokens, let cost): String(format: String(localized: "rule.k4", bundle: .tacho), TokenFormat.usdFigure(usd), cost, tokens)
        }
    }

    /// Rules LH: the Limits page, spec section 12.5.
    static func sentence(_ rule: LimitHighlight) -> String {
        switch rule {
        case .lh1(let recent, let average): String(format: String(localized: "rule.lh1", bundle: .tacho), oneDecimal(recent), oneDecimal(average))
        case .lh2(let recent, let average): String(format: String(localized: "rule.lh2", bundle: .tacho), oneDecimal(recent), oneDecimal(average))
        case .lh3(let median): String(format: String(localized: "rule.lh3", bundle: .tacho), median)
        case .lh4: String(localized: "rule.lh4", bundle: .tacho)
        }
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// Rules WL: the limit card in Summary, whose title has already named the limit. Spec section 11.1.
    static func sentence(_ rule: SummaryLimitRule, _ projection: Projection, now: Date, calendar: Calendar = .current) -> (text: String, tone: Tone) {
        let reset = Labels.reset(projection.resetsAt, now: now, calendar: calendar)
        switch rule {
        case .wl1:
            return (String(format: String(localized: "limitCard.usedUp", bundle: .tacho), reset), .critical)
        case .wl2:
            return (String(format: String(localized: "limitCard.high", bundle: .tacho), Labels.percent(projection) ?? "", reset), .critical)
        case .wl3:
            guard case .runsOut(let at, _) = projection.outcome else { return (String(localized: "limitCard.unknown", bundle: .tacho), .plain) }
            return (String(format: String(localized: "limitCard.pace", bundle: .tacho), Labels.reset(at, now: now, calendar: calendar)), .warning)
        case .wl4:
            return (String(format: String(localized: "limitCard.clearTo", bundle: .tacho), reset), .plain)
        case .wl5:
            return (String(localized: "limitCard.idle", bundle: .tacho), .plain)
        case .wl6:
            return (String(localized: "limitCard.unknown", bundle: .tacho), .plain)
        }
    }

    /// Rules WC: the middle of the row under the runway.
    static func caption(_ rule: SummaryLimitCentre, _ projection: Projection, now: Date, calendar: Calendar = .current) -> String {
        let reset = Labels.reset(projection.resetsAt, now: now, calendar: calendar)
        guard rule == .wc1, case .runsOut(let at, _) = projection.outcome else {
            return String(format: String(localized: "limitCard.resets", bundle: .tacho), reset)
        }
        return String(format: String(localized: "limitCard.resetsLater", bundle: .tacho), reset, Labels.gap(from: at, to: projection.resetsAt))
    }

    /// Rule P12. The share is of cost or of tokens as the engine found it, and says which: the rows beside it are always in money.
    static func share(_ insight: CLIShareInsight) -> String {
        let key: String.LocalizationValue = insight.basis == .cost ? "card.clis.sayCost" : "card.clis.sayTokens"
        return String(format: String(localized: key, bundle: .tacho), insight.source.displayName, insight.percent)
    }

    /// A row's time: the clock today, and the date too on any other day, since the log runs across days.
    static func logTime(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = Labels.locale, bundle: Bundle = .tacho) -> String {
        let time = date.formatted(Date.FormatStyle(time: .standard).locale(locale))
        guard !calendar.isDate(date, inSameDayAs: now) else { return time }
        // In two parts: as one style it brings back the year, and "at", which the column has no room for.
        let day = date.formatted(Date.FormatStyle().month(.abbreviated).day().locale(locale))
        return String(format: String(localized: "log.dayTime", bundle: bundle), day, time)
    }

    /// A model id as short as it can go and still say which model it is: `claude-sonnet-5-5-20261104` is `sonnet-5-5`. A row of one
    /// vendor's models differ in the family, and a date says the least.
    static func modelFamily(_ id: String) -> String {
        var parts = id.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 1, parts[0] == "claude" { parts.removeFirst() }
        if parts.count > 1, let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        return parts.joined(separator: "-")
    }

    /// `1 request`, `1,204 requests`.
    static func requests(_ count: Int) -> String {
        count == 1 ? String(localized: "log.request", bundle: .tacho) : String(format: String(localized: "log.requests", bundle: .tacho), count.formatted())
    }

    static func title(of card: PinnedCard) -> String {
        switch card {
        case .output: String(localized: "card.outputToday", bundle: .tacho)
        case .cache: String(localized: "card.cache", bundle: .tacho)
        case .speed: String(localized: "card.speed", bundle: .tacho)
        case .clis: String(localized: "card.clis", bundle: .tacho)
        case .tokens: String(localized: "card.tokens", bundle: .tacho)
        case .when: String(localized: "card.when", bundle: .tacho)
        }
    }

    static func range(_ range: DetailRange) -> String {
        switch range {
        case .day: String(localized: "range.day", bundle: .tacho)
        case .week: String(localized: "range.weekShort", bundle: .tacho)
        case .month: String(localized: "range.monthShort", bundle: .tacho)
        case .year: String(localized: "range.year", bundle: .tacho)
        }
    }

    static func origin(_ origin: QuotaOrigin) -> String {
        switch origin {
        case .anthropicAPI: String(localized: "quota.origin.anthropicAPI", bundle: .tacho)
        case .claudeCache: String(localized: "quota.origin.claudeCache", bundle: .tacho)
        case .ompCache: String(localized: "quota.origin.ompCache", bundle: .tacho)
        case .codexLog: String(localized: "quota.origin.codexLog", bundle: .tacho)
        case .grokLog: String(localized: "quota.origin.grokLog", bundle: .tacho)
        }
    }

    /// The first figure on a range page: "Today", "Last 7 days".
    static func totalLabel(_ range: DetailRange) -> String {
        switch range {
        case .day: String(localized: "stat.today", bundle: .tacho)
        case .week: String(localized: "stat.last7", bundle: .tacho)
        case .month: String(localized: "stat.last30", bundle: .tacho)
        case .year: String(localized: "stat.last12", bundle: .tacho)
        }
    }

    /// What is still missing for there to be a usual range. Until the older logs are read no day can be called missing: section 8.1.
    static func needsDays(_ daysOfUse: Int, todayHasUse: Bool, isReading: Bool) -> String {
        guard !isReading else { return String(localized: "reading.logs", bundle: .tacho) }
        let left = Insights.daysLeft(of: UsualRange.minimumDays, finished: daysOfUse, todayHasUse: todayHasUse)
        return left == 1 ? String(localized: "say.needsDay", bundle: .tacho) : String(format: String(localized: "say.needsDays", bundle: .tacho), left)
    }

    /// A day's cost under the pointer: "no price" for a day of tokens with none priced.
    static func dayCost(_ day: DayCell) -> String {
        day.costUSD > 0 || day.tokens == 0 ? TokenFormat.usdFigure(day.costUSD) : String(localized: "cost.noPrice", bundle: .tacho)
    }

    /// `$41.00 to $84.00`, `$20.00 to $70.00 a day`, or what is missing for there to be one.
    static func usual(_ bands: UsualBands, range: DetailRange, isCost: Bool, daysOfUse: Int, todayHasUse: Bool, isReading: Bool) -> String {
        let band = range == .day ? bands.now : bands.daily
        guard let band else { return needsDays(daysOfUse, todayHasUse: todayHasUse, isReading: isReading) }
        let amount: (Double) -> String = { isCost ? TokenFormat.usdFigure($0) : TokenFormat.compact(Int($0.rounded())) }
        return String(format: String(localized: range == .day ? "stat.usualRange" : "stat.usualDay", bundle: .tacho), amount(band.p25), amount(band.p75))
    }

    /// A column's name under the pointer: `15:00`, `Tue 4 Nov`, `Sep 2026`.
    static func columnLabel(_ start: Date, range: DetailRange, calendar: Calendar = .current) -> String {
        switch range {
        case .day: Labels.clock(start)
        case .week, .month: start.formatted(Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).locale(Labels.locale))
        case .year: start.formatted(Date.FormatStyle().month(.abbreviated).year().locale(Labels.locale))
        }
    }

    /// What the axis says at this column, if anything: spec section 12.1.
    static func axisLabel(_ start: Date, index: Int, range: DetailRange, calendar: Calendar = .current) -> String? {
        switch range {
        case .day: index % 6 == 0 ? String(format: "%02ld", index) : nil
        case .week: start.formatted(Date.FormatStyle().weekday(.abbreviated).locale(Labels.locale))
        // Every 7th day, starting in from the edge, where a label would be cut short.
        case .month: index % 7 == 2 ? start.formatted(Date.FormatStyle().day().month(.abbreviated).locale(Labels.locale)) : nil
        case .year: start.formatted(Date.FormatStyle().month(.abbreviated).locale(Labels.locale))
        }
    }
}
