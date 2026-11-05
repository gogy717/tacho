import Foundation
import Testing
@testable import Tacho
import TachoKit

struct LabelsTests {
    private let now = Date(timeIntervalSince1970: 1_793_800_000)

    private func projection(_ percent: Double, _ outcome: Projection.Outcome, method: Projection.Method = .windowAverage) -> Projection {
        let snapshot = QuotaSnapshot(provider: .anthropic, window: .fiveHour, scope: nil, usedPercent: percent, resetsAt: now.addingTimeInterval(7_200), observedAt: now, origin: .claudeCache)
        return Projection(snapshot: snapshot, estimatedPercent: percent, isEstimate: true, method: method, outcome: outcome, isStale: false, resetsAt: now.addingTimeInterval(7_200))
    }

    private func numeric(_ locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 23, minute: 46))!
        var style = Date.FormatStyle(date: .numeric, time: .shortened).locale(locale)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    @Test func theRegionDecidesTheDateOrderAndTheClock() {
        let british = numeric(Labels.locale(language: "en", region: "GB"))
        #expect(british.hasPrefix("04/11/2026"))
        #expect(british.contains("23:46"))
        #expect(numeric(Labels.locale(language: "en", region: "US")).hasPrefix("11/4/2026"))
    }

    @Test func theLanguageStaysTheStrings() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Labels.locale(language: "zh-Hans", region: "AU")
        #expect(calendar.shortMonthSymbols[10].contains("月"))
        calendar.locale = Labels.locale(language: "en", region: "CN")
        #expect(calendar.shortMonthSymbols[10] == "Nov")
    }

    private var sydney: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return calendar
    }

    /// "2026-11-05 23:00", in Sydney.
    private func local(_ text: String) -> Date {
        let parts = text.split { "- :".contains($0) }.compactMap { Int($0) }
        return sydney.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4]))!
    }

    /// Now, a time, and what it reads as. 5 November 2026 is a Thursday. `zh_Hans_AU` takes a 12-hour clock from the region. Sydney's clocks go back
    /// on 5 April 2026, a day of 25 hours, and forward on 4 October, a day of 23.
    private static let days: [(now: String, date: String, en: String, zh: String)] = [
        ("2026-11-05 10:00", "2026-11-05 17:30", "5:30 PM", "下午5:30"),
        ("2026-11-05 00:10", "2026-11-05 23:50", "11:50 PM", "下午11:50"), // nearly a day away, and still today
        ("2026-11-05 23:00", "2026-11-06 09:00", "9:00 AM tomorrow", "明天 上午9:00"), // the case a person saw
        ("2026-11-05 23:50", "2026-11-06 00:10", "12:10 AM tomorrow", "明天 上午12:10"), // 20 minutes away, and another day
        ("2026-11-05 10:00", "2026-11-06 10:00", "10:00 AM tomorrow", "明天 上午10:00"), // exactly 24 hours
        ("2026-11-05 10:00", "2026-11-07 10:00", "Sat 10:00 AM", "周六 上午10:00"),
        ("2026-11-05 10:00", "2026-11-11 10:00", "Wed 10:00 AM", "周三 上午10:00"), // 6 days
        ("2026-11-05 10:00", "2026-11-12 10:00", "Nov 12, 10:00 AM", "11月12日 上午10:00"), // 7 days: Thu on a Thursday would read as today
        ("2026-11-05 10:00", "2026-11-13 10:00", "Nov 13, 10:00 AM", "11月13日 上午10:00"), // past the week, a weekday says nothing
        ("2026-11-05 10:00", "2026-11-04 20:00", "Wed 8:00 PM", "周三 下午8:00"), // a window opened last night
        ("2026-11-05 10:00", "2026-10-30 10:00", "Fri 10:00 AM", "周五 上午10:00"), // 6 days ago
        ("2026-11-05 10:00", "2026-10-29 10:00", "Oct 29, 10:00 AM", "10月29日 上午10:00"), // 7 days ago: Thu again
        ("2026-04-05 00:30", "2026-04-05 23:30", "11:30 PM", "下午11:30"), // 24 hours on, on a day of 25: still today
        ("2026-10-03 23:30", "2026-10-04 23:30", "11:30 PM tomorrow", "明天 下午11:30"), // 23 hours on, on a day of 23: tomorrow
        ("2026-10-04 00:30", "2026-10-05 00:30", "12:30 AM tomorrow", "明天 上午12:30"), // the same day of 23, from its start
    ]

    @Test func aTimeSaysWhichDayItIsOn() throws {
        let english = try #require(Tests.strings("en"))
        let chinese = try #require(Tests.strings("zh-Hans"))
        for day in Self.days {
            let en = Labels.reset(local(day.date), now: local(day.now), calendar: sydney, locale: Labels.locale(language: "en", region: "US"), bundle: english)
            let zh = Labels.reset(local(day.date), now: local(day.now), calendar: sydney, locale: Labels.locale(language: "zh-Hans", region: "AU"), bundle: chinese)
            #expect(en.replacingOccurrences(of: "\u{202F}", with: " ") == day.en, "\(day.now) to \(day.date)")
            #expect(zh.replacingOccurrences(of: "\u{202F}", with: " ") == day.zh, "\(day.now) to \(day.date)")
        }
    }

    /// The day and the clock come from one zone, the calendar's, whatever the Mac's is. These fixtures are in Sydney, so this one is not.
    @Test func aTimeIsPrintedInItsCalendarsZone() throws {
        let english = try #require(Tests.strings("en"))
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let now = try #require(newYork.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 23)))
        // Late at night, so that a time printed in Sydney would also change its day.
        for (day, hour, said) in [(6, 9, "9:00 AM tomorrow"), (7, 23, "Sat 11:00 PM"), (12, 23, "Nov 12, 11:00 PM")] {
            let date = try #require(newYork.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour)))
            let text = Labels.reset(date, now: now, calendar: newYork, locale: Labels.locale(language: "en", region: "US"), bundle: english)
            #expect(text.replacingOccurrences(of: "\u{202F}", with: " ") == said)
        }
    }

    /// The day in words does not change what the two times subtract to.
    @Test func aGapAcrossMidnightStillSubtracts() {
        #expect(Labels.gap(from: local("2026-11-05 23:50"), to: local("2026-11-06 00:10")) == "20 min")
        let quota = WindowSamples.projection(empties: local("2026-11-05 23:50"), resets: local("2026-11-06 00:10"))
        let said = Labels.limitSay(LimitsInsight(rule: .l3, limit: quota), now: local("2026-11-05 23:00"), calendar: sydney).0
        #expect(said?.contains("20 min before") == true)
        #expect(said?.contains("tomorrow") == true)
    }

    /// Across a clock change the gap stays the time that will really pass, which is the point of it, though the two times then subtract to an hour more or less.
    @Test func aGapAcrossAClockChangeIsTheTimeThatPasses() {
        #expect(Labels.gap(from: local("2026-10-04 01:30"), to: local("2026-10-04 03:30")) == "1 h 0 min")
    }

    /// Just after midnight the chart's hour reaches back into yesterday.
    @Test func aMinuteOfTheChartBeforeMidnightSaysItsDay() {
        let midnight = local("2026-11-05 00:10")
        let today = Labels.reset(midnight, now: midnight, calendar: sydney)
        #expect(PanelHeader.minute(0, now: midnight, calendar: sydney) == today)
        #expect(PanelHeader.minute(-30, now: midnight, calendar: sydney) == Labels.reset(local("2026-11-04 23:40"), now: midnight, calendar: sydney))
        #expect(PanelHeader.minute(-30, now: midnight, calendar: sydney).contains("Wed"))
    }

    @Test func nullModelAndProjectAreNamed() {
        #expect(Labels.model("") == String(localized: "overview.noModel", bundle: .tacho))
        #expect(Labels.project("") == String(localized: "overview.noProject", bundle: .tacho))
        #expect(Labels.model("gpt-6") == "gpt-6")
        #expect(Labels.project("/Users/x/Dev/tacho") == "tacho")
        #expect(Labels.project("/Users/x/Dev/tacho/") == "tacho")
    }

    @Test func logFigures() {
        #expect(Labels.logCost(nil) == String(localized: "cost.noPrice", bundle: .tacho))
        #expect(Labels.logCost(0) == "$0.00")
        #expect(Labels.logCost(1.5) == "$1.50")
        #expect(Labels.priceRate(1.25) == "$1.25")
        #expect(Labels.priceRate(5) == "$5")
        #expect(Labels.priceRate(0.075) == "$0.075")
    }

    @Test func quartersOfTheNonZeroValues() {
        let scale = HeatScale([0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 1_000_000])
        #expect(scale.level(of: 0) == nil)
        #expect(scale.level(of: 1) == 0)
        #expect(scale.level(of: 1_000_000) == 3)
        #expect(HeatScale([]).level(of: 5) == 0)
        #expect(HeatScale([0, 0]).level(of: 0) == nil)
    }

    @Test func rangesAreWholeLocalDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        let today = calendar.startOfDay(for: now)
        #expect(RangeChoice.today.timeRange(now: now, calendar: calendar) == TimeRange(start: today, end: now))
        #expect(calendar.dateComponents([.day], from: RangeChoice.week.timeRange(now: now, calendar: calendar).start, to: today).day == 6)
        #expect(calendar.dateComponents([.day], from: RangeChoice.month.timeRange(now: now, calendar: calendar).start, to: today).day == 29)
        #expect(RangeChoice.all.timeRange(now: now, calendar: calendar).start == Date(timeIntervalSince1970: 0))
    }

    private func cost(_ usd: Double, unpriced: Int = 0, models: [String] = []) -> CostSummary {
        CostSummary(usd: usd, unpricedModels: models, unpricedTokens: unpriced)
    }

    private func dashboard(cost: CostSummary = CostSummary(usd: 0, unpricedModels: [], unpricedTokens: 0), output: Int = 11_200, all: Int = 4_100_000) -> Dashboard {
        Dashboard(perMinute: all, perSecond: Double(all) / 60, isIdle: false, lastMinute: .zero, series: [], sources: [], quotas: [], today: TodaySummary(tokens: .zero, cost: cost, speeds: []), alert: .none, progress: IngestProgress(phase: .live, filesDone: 0, filesTotal: 0), outputPerMinute: output, costPerMinute: cost)
    }

    // The rate modes: spec §2.5.
    @Test func eachModeHasItsFigure() {
        let dashboard = dashboard(cost: cost(1.2))
        #expect(Labels.rate(dashboard, mode: .output, unit: .perMinute) == "11.2k/min")
        #expect(Labels.rate(dashboard, mode: .allTokens, unit: .perMinute) == "4.1M/min")
        #expect(Labels.rate(dashboard, mode: .cost, unit: .perMinute) == "$1.20/min")
    }

    @Test func costStaysPerMinuteWhateverTheUnit() {
        #expect(Labels.rate(dashboard(cost: cost(1.2)), mode: .cost, unit: .perSecond) == "$1.20/min")
        #expect(Labels.rate(dashboard(), mode: .output, unit: .perSecond).hasSuffix("/s"))
    }

    @Test func costRateSteps() {
        #expect(Labels.rate(dashboard(cost: cost(0.004)), mode: .cost, unit: .perMinute) == "<$0.01/min")
        #expect(Labels.rate(dashboard(cost: cost(9.99)), mode: .cost, unit: .perMinute) == "$9.99/min")
        #expect(Labels.rate(dashboard(cost: cost(14.4)), mode: .cost, unit: .perMinute) == "$14/min")
    }

    @Test func unpricedModelsGetAPlusAndANote() {
        let cost = cost(1.2, unpriced: 500, models: ["acme-coder-2"])
        #expect(Labels.rate(dashboard(cost: cost), mode: .cost, unit: .perMinute) == "$1.20+/min")
        #expect(Labels.rateNote(cost)?.contains("acme-coder-2") == true)
    }

    @Test func nothingPricedIsNeverZero() {
        let text = Labels.rate(dashboard(cost: cost(0, unpriced: 500, models: ["acme-coder-2"])), mode: .cost, unit: .perMinute)
        #expect(text == String(localized: "cost.noPrice", bundle: .tacho))
    }

    @Test func costFigureKeepsCentsUpToAHundred() {
        #expect(Labels.figure(cost(98.74)) == "$98.74")
        #expect(Labels.figure(cost(375)) == "$375")
        #expect(Labels.figure(cost(1_630)) == "$1,630")
        #expect(Labels.figure(cost(0.004)) == "<$0.01")
        #expect(Labels.figure(cost(0)) == "$0.00")
        #expect(Labels.figure(cost(98.74, unpriced: 5)).contains("$98.74"))
        #expect(Labels.figure(cost(98.74, unpriced: 5)).contains("+"))
        #expect(Labels.figure(cost(0, unpriced: 5)) == String(localized: "cost.noPrice", bundle: .tacho))
    }

    @Test func ageIsItsLargestUnitOnly() {
        #expect(Labels.ageShort(7 * 86_400 + 3_600) == "7 d")
        #expect(Labels.ageShort(5 * 3_600 + 600) == "5 h")
        #expect(Labels.ageShort(12 * 60) == "12 min")
    }

    @Test func notCountedNamesItsModelsAndTokens() throws {
        let text = try #require(Labels.notCounted(cost(1, unpriced: 12_400_000, models: ["acme-coder-2"])))
        #expect(text.contains("acme-coder-2"))
        #expect(text.contains("12.4M"))
    }

    @Test func moreThanTwoModelsShowTwo() throws {
        let text = try #require(Labels.notCounted(cost(1, unpriced: 5, models: ["a-1", "b-2", "c-3", "d-4"])))
        #expect(text.contains("a-1"))
        #expect(text.contains("b-2"))
        #expect(!text.contains("c-3"))
        #expect(text.contains("2"))
    }

    @Test func notCountedWithNoModelSaysSo() throws {
        let text = try #require(Labels.notCounted(cost(1, unpriced: 5)))
        #expect(text.contains("5"))
        #expect(Labels.notCounted(cost(1)) == nil)
    }

    @Test func theRateNoteNamesTheFirstModelOrSaysNone() {
        #expect(Labels.rateNote(cost(1, unpriced: 5, models: ["a-1", "b-2"])) == String(format: String(localized: "rate.excludes", bundle: .tacho), "a-1"))
        #expect(Labels.rateNote(cost(1, unpriced: 5)) == String(localized: "rate.excludesUnnamed", bundle: .tacho))
        #expect(Labels.rateNote(cost(1)) == nil)
    }

    /// The figure itself says "no price", so a note that something is left out would say it twice, and less truly.
    @Test func nothingPricedHasNoRateNote() {
        #expect(Labels.rateNote(cost(0, unpriced: 5, models: ["a-1"])) == nil)
        #expect(Labels.rateNote(cost(0, unpriced: 5)) == nil)
    }

    @Test func modelsGetShortNames() {
        #expect(Labels.modelShort("claude-opus-5-5") == "Opus 5.5")
        #expect(Labels.modelShort("gpt-6.1-sol") == "gpt-6.1-sol")
        #expect(Labels.modelShort("claude-opus") == "claude-opus")
    }

    @Test func aScopedLimitIsNamedByItsScope() {
        let snapshot = QuotaSnapshot(provider: .anthropic, window: .weekly, scope: "Fable", usedPercent: 10, resetsAt: now, observedAt: now, origin: .claudeCache)
        #expect(Labels.limitName(snapshot).contains("Fable"))
        #expect(!Labels.limitName(snapshot).contains("Anthropic"))
    }

    /// $14.60 an hour must not read $15: the cut `usdFigure` exists to stop.
    @Test func anHourlyCostKeepsItsCents() {
        #expect(Labels.hourlyCost(cost(14.6)) == "≈ $14.60/h")
        #expect(Labels.hourlyCost(cost(0.2)) == "≈ $0.20/h")
        #expect(Labels.hourlyCost(cost(375)) == "≈ $375/h")
    }

    @Test func anHourlyCostFollowsTheThreeWayRule() {
        #expect(Labels.hourlyCost(cost(14.6, unpriced: 10)) == "≈ $14.60+/h")
        #expect(Labels.hourlyCost(cost(0, unpriced: 10)) == "hourly cost: no price")
    }

    @Test func aMinuteOfCostFollowsTheThreeWayRule() {
        #expect(Labels.chartValue(1.2, mode: .cost) == "$1.20")
        #expect(Labels.chartValue(1.2, mode: .cost, unpricedTokens: 500) == "$1.20+")
        #expect(Labels.chartValue(0, mode: .cost, unpricedTokens: 500) == "no price")
    }

    @Test func aMinuteUnderACentDoesNotReadAsNothing() {
        #expect(Labels.chartValue(0.004, mode: .cost) == "<$0.01")
    }

    @Test func aMinuteWithNothingInItIsZero() {
        #expect(Labels.chartValue(0, mode: .cost) == "$0.00")
    }

    @Test func aMinuteOfTokensIsACount() {
        #expect(Labels.chartValue(18_200, mode: .output) == "18.2k")
        #expect(Labels.chartValue(18_200, mode: .allTokens, unpricedTokens: 500) == "18.2k")
    }
}
