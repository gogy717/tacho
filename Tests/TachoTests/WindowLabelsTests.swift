import AppKit
import Foundation
import Testing
@testable import Tacho
import TachoKit

/// The window's sentences, against the tables in spec section 11.1.
struct WindowLabelsTests {
    private let now = WindowSamples.now
    private let calendar = Calendar.current

    private func reset(_ quota: Projection) -> String {
        Labels.reset(quota.resetsAt, now: now, calendar: calendar)
    }

    @Test func rulesW() {
        #expect(WindowLabels.sentence(.w1(percent: 20)) == "20% up on last week.")
        #expect(WindowLabels.sentence(.w2(percent: 8)) == "8% down on last week.")
        #expect(WindowLabels.sentence(.w3) == "About the same as last week.")
        #expect(WindowLabels.sentence(.w4(soFar: 9)) == "Comparing weeks starts after 14 days of use. 9 so far.")
        #expect(WindowLabels.sentence(.w5) == "Nothing last week to compare with.")
        #expect(WindowLabels.sentence(.w6) == "Still reading your logs. This comparison may follow.")
    }

    private func said(_ rule: SummaryLimitRule, _ quota: Projection) -> (text: String, tone: Tone) {
        WindowLabels.sentence(rule, quota, now: now, calendar: calendar)
    }

    @Test func rulesWL() {
        let at = now + 600
        let running = WindowSamples.projection(percent: 60, outcome: .runsOut(at: at, beforeReset: 100))
        let high = WindowSamples.projection(percent: 92)
        #expect(said(.wl1, high).text == "Used up. It resets at \(reset(high)).")
        #expect(said(.wl2, high).text == "At 92%. It resets at \(reset(high)).")
        #expect(said(.wl3, running).text == "At this pace it empties about \(Labels.reset(at, now: now, calendar: calendar)).")
        #expect(said(.wl4, high).text == "Clear to \(reset(high)).")
        #expect(said(.wl5, high).text == "Clear for now: not in use.")
        #expect(said(.wl6, high).text == "No forecast yet.")
    }

    @Test func onlyWhatWarnsTakesAColour() {
        let quota = WindowSamples.projection(percent: 60, outcome: .runsOut(at: now + 600, beforeReset: 100))
        #expect(said(.wl1, quota).tone == .critical)
        #expect(said(.wl2, quota).tone == .critical)
        #expect(said(.wl3, quota).tone == .warning)
        #expect(said(.wl4, quota).tone == .plain)
        #expect(said(.wl5, quota).tone == .plain)
        #expect(said(.wl6, quota).tone == .plain)
    }

    @Test func rulesWC() {
        let lasting = WindowSamples.projection(percent: 40, outcome: .lastsUntilReset)
        #expect(WindowLabels.caption(.wc2, lasting, now: now, calendar: calendar) == "resets \(reset(lasting))")
        let running = WindowSamples.projection(percent: 60, outcome: .runsOut(at: now + 4_200, beforeReset: 5_100))
        #expect(WindowLabels.caption(.wc1, running, now: now, calendar: calendar) == "resets \(reset(running)), 1 h 25 min later")
    }

    /// The card's sentence gives the one time and this caption the other, with the gap between them.
    @Test func aCaptionsGapIsWhatItsTwoTimesSubtractTo() {
        for gap in WindowSamples.gaps {
            let quota = WindowSamples.projection(empties: gap.empties, resets: gap.resets)
            #expect(WindowLabels.caption(.wc1, quota, now: now, calendar: calendar) == "resets \(reset(quota)), \(gap.short) later")
        }
    }

    /// Every pair of seconds, each minute read back off the printed time, so that a time printed any other way than cut to the minute shows here.
    @Test func everyPairOfSecondsSubtractsToTheGapPrinted() {
        func minute(_ date: Date) -> Int { Int(Labels.clock(date).split(separator: ":")[1].prefix(2)) ?? -1 }
        var wrong = 0
        for empties in 0..<60 {
            for resets in 0..<60 {
                let at = WindowSamples.turn + Double(empties)
                let end = WindowSamples.turn + Double(92 * 60 + resets)
                let quota = WindowSamples.projection(empties: at, resets: end)
                let subtracted = (minute(end) - minute(at) + 60) % 60
                if WindowLabels.caption(.wc1, quota, now: now, calendar: calendar) != "resets \(reset(quota)), 1 h \(subtracted) min later" { wrong += 1 }
            }
        }
        #expect(wrong == 0)
    }

    @Test func ruleP12SaysWhichShareItIs() {
        #expect(WindowLabels.share(CLIShareInsight(source: .claudeCode, percent: 80, basis: .cost)) == "Claude Code: 80% of cost")
        #expect(WindowLabels.share(CLIShareInsight(source: .claudeCode, percent: 72, basis: .tokens)) == "Claude Code: 72% of tokens")
    }

    @Test func rulesD() {
        let say = { (rule: CostHighlight) in WindowLabels.sentence(rule, today: nil) }
        let cost = CostSummary(usd: 33.1, unpricedModels: [], unpricedTokens: 0)
        #expect(say(.d2(cost: cost)) == "The last hour was the busiest today: $33.10.")
        #expect(say(.d3(tokensPercent: 97, costPercent: 46)) == "Cache reads are 97% of tokens but 46% of cost.")
        #expect(say(.d4(percent: 12)) == "12% up on the previous 7 days.")
        #expect(say(.d5(percent: 12)) == "12% down on the previous 7 days.")
        #expect(say(.d6) == "About the same as the previous 7 days.")
        #expect(say(.d8(fromPercent: 28, toPercent: 31)) == "Output's share of cost went from 28% to 31%.")
        #expect(say(.d9(percent: 12)) == "12% up on the previous 30 days.")
        #expect(say(.d10(percent: 12)) == "12% down on the previous 30 days.")
        #expect(say(.d11) == "About the same as the previous 30 days.")
    }

    @Test func rulesDAreSingularForOneDay() {
        let say = { (rule: CostHighlight) in WindowLabels.sentence(rule, today: nil) }
        #expect(say(.d7(days: 2, percent: 60)) == "2 days carried 60% of the week.")
        #expect(say(.d7(days: 1, percent: 60)) == "1 day carried 60% of the week.")
        #expect(say(.d12(days: 3)) == "3 days were above your usual range.")
        #expect(say(.d12(days: 1)) == "1 day was above your usual range.")
        #expect(say(.d13(days: 3)) == "3 days had no use.")
        #expect(say(.d13(days: 1)) == "1 day had no use.")
        #expect(say(.d15(days: 200)) == "200 days with use in the last 12 months.")
        #expect(say(.d15(days: 1)) == "1 day with use in the last 12 months.")
    }

    @Test func ruleD14NamesTheMonthAndTheCost() throws {
        let month = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        let cost = CostSummary(usd: 1_630, unpricedModels: [], unpricedTokens: 0)
        #expect(WindowLabels.sentence(.d14(month: month, cost: cost), today: nil)?.hasSuffix(" was the busiest month: $1,630.") == true)
    }

    @Test func ruleD1IsCostTodaysSentenceOrNothing() {
        #expect(WindowLabels.sentence(.d1, today: .h3) == "Nothing yet today.")
        #expect(WindowLabels.sentence(.d1, today: nil) == nil)
    }

    @Test func rulesT() {
        #expect(WindowLabels.sentence(TokenHighlight.t1(percent: 40)) == "40% of output was thinking, where recorded.")
        #expect(WindowLabels.sentence(TokenHighlight.t2(percent: 38)) == "Sub-agents made 38% of requests.")
    }

    @Test func rulesK() {
        #expect(WindowLabels.sentence(CacheHighlight.k1(from: 94.2, to: 97.8)) == "Your hit rate went from 94.2% to 97.8% this week.")
        #expect(WindowLabels.sentence(CacheHighlight.k2(rate: 97.8)) == "Your hit rate held near 97.8% this week.")
        #expect(WindowLabels.sentence(CacheHighlight.k3(tokensPercent: 97, costPercent: 46)) == "Cache reads are 97% of your tokens but 46% of your cost.")
        // `{b}` of the bill from `{a}` of the tokens: the order of the words is not the order of the values.
        #expect(WindowLabels.sentence(CacheHighlight.k4(usd: 286, tokensPercent: 2, costPercent: 26)) == "Cache writes cost $286: 26% of the bill from 2% of the tokens.")
    }

    @Test func rulesLH() {
        #expect(WindowLabels.sentence(LimitHighlight.lh1(recent: 31.2, average: 26)) == "This window is running ahead: 31.2% an hour lately, against 26.0% an hour since it opened.")
        #expect(WindowLabels.sentence(LimitHighlight.lh2(recent: 0.3, average: 0.5)) == "This window has slowed: 0.3% an hour lately, against 0.5% an hour since it opened.")
        #expect(WindowLabels.sentence(LimitHighlight.lh3(medianPercent: 44)) == "Recent windows peaked around 44%.")
        #expect(WindowLabels.sentence(LimitHighlight.lh4) == "This window is past most recent peaks.")
    }

    @Test func aLogRowFromTodayGivesOnlyItsTime() {
        #expect(WindowLabels.logTime(now, now: now, calendar: calendar) == now.formatted(Date.FormatStyle(time: .standard).locale(Labels.locale)))
    }

    @Test func aLogRowFromAnotherDayGivesMonthDayAndTimeWithNoYear() {
        // Comparing lengths passed on `Nov 6, 2026 at 4:33:20 AM`, whose clock the column then cut off.
        let earlier = now - 3 * 86_400
        let time = earlier.formatted(Date.FormatStyle(time: .standard).locale(Labels.locale))
        let day = earlier.formatted(Date.FormatStyle().month(.abbreviated).day().locale(Labels.locale))
        let text = WindowLabels.logTime(earlier, now: now, calendar: calendar)
        #expect(text == "\(day), \(time)")
        #expect(!text.contains(String(calendar.component(.year, from: earlier))))
        #expect(!text.contains(" at "))
    }

    private func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]).width
    }

    /// By the column's real font, in the string file of the language shown. A row that is cut off loses its clock first.
    /// `zh_Hans_AU` is a real person's locale: outside China, Chinese takes a 12-hour clock from the region.
    @Test(arguments: [("en_US", "en"), ("en_AU", "en"), ("zh_Hans_CN", "zh-Hans"), ("zh_Hans_AU", "zh-Hans"), ("zh_Hans_US", "zh-Hans")])
    func theWidestOlderRowFitsTheColumn(locale: String, language: String) throws {
        let table = try #require(Tests.strings(language))
        // Two-digit months and days, and each kind of hour: AM is wider than PM, and 12 is as wide as 10.
        let widest = try (1...12).flatMap { month in
            try [0, 10, 12, 22].map { hour in
                let date = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: 28, hour: hour, minute: 48, second: 58)))
                return width(WindowLabels.logTime(date, now: now, calendar: calendar, locale: Locale(identifier: locale), bundle: table))
            }
        }.max() ?? 0
        #expect(widest > 100)
        #expect(widest <= LogColumn.time.ideal, "\(widest)")
    }

    @Test func everyCLIReadsWhole() {
        #expect(Source.allCases.map { width($0.displayName) }.allSatisfy { $0 <= LogColumn.cli.ideal })
    }

    /// 1039 is what a real app's detail gets at the default window: 1240 less the sidebar's 200 and the divider.
    @Test func allElevenColumnsShowAtTheDefaultWindow() {
        #expect(LogColumn.shown(in: 1039).count == 11)
        #expect(LogColumn.shown(in: 1038).count == 10)
    }

    /// The narrowest log the window gives, 820 less the sidebar: what goes, in order, and what never does.
    @Test func columnsGiveWayInTheirOrderAndNeverTimeCLIModelOrCost() {
        var gone: [LogColumn] = []
        for width in stride(from: CGFloat(1039), through: 400, by: -1) {
            gone += LogColumn.allCases.filter { !LogColumn.shown(in: width).contains($0) && !gone.contains($0) }
        }
        #expect(gone == LogColumn.givingWay)
        #expect(LogColumn.shown(in: 400) == [.time, .cli, .model, .cost])
        #expect(LogColumn.shown(in: 612).isSuperset(of: [.time, .cli, .model, .cost, .output]))
    }

    @Test func aRowsTooltipHoldsWhatItsHiddenColumnsSay() {
        let event = UsageEvent(source: .claudeCode, dedupKey: "k", project: "/Users/demo/Code/demo-app", model: "claude-opus-5-5", time: WindowSamples.now,
                               tokens: TokenCounts(input: 120, output: 1_500, cacheRead: 98_000, cacheWrite5m: 2_300, cacheWrite1h: 1_200))
        let row = LogRow(event: event, costUSD: 1, tokensPerSecond: 71, approximateSpeed: false)
        let tooltip = LogTable.hidden(row, shown: [.time, .cli, .model, .cost, .output], own: "Claude Code")
        #expect(tooltip == ["Claude Code", "Project: demo-app", "Input: 120", "Cache read: 98.0k", "Cache write, 5 min: 2.3k", "Cache write, 1 h: 1.2k", "71 tok/s"].joined(separator: "\n"))
        #expect(LogTable.hidden(row, shown: Set(LogColumn.allCases)).isEmpty)
    }

    @Test func aModelsFamilyKeepsWhatDiffersAndLosesTheVendorAndTheDate() {
        #expect(WindowLabels.modelFamily("claude-opus-5-5") == "opus-5-5")
        #expect(WindowLabels.modelFamily("claude-sonnet-5-5-20261104") == "sonnet-5-5")
        #expect(WindowLabels.modelFamily("claude-3-5-haiku-20241022") == "3-5-haiku")
    }

    @Test func anIdWithNoVendorOrDateIsLeftAlone() {
        #expect(WindowLabels.modelFamily("gpt-6.1-sol") == "gpt-6.1-sol")
        #expect(WindowLabels.modelFamily("gemini-3-pro") == "gemini-3-pro")
        #expect(WindowLabels.modelFamily("") == "")
    }

    /// Beside both chips, English: what used to read `cl…-5` for all three.
    @Test func modelsOfOneVendorStayApartInTheRoomBesideBothChips() {
        let ids = ["claude-opus-5-5", "claude-sonnet-5-5-20261104", "claude-haiku-5-5-20261001"]
        let chips = width("sub-agent") + width("fast") + 4 * 5 + 2 * 5
        let room = LogColumn.model.ideal - chips
        // What a tail cut leaves: as many letters as fit beside the ellipsis.
        let shown = ids.map { id -> String in
            let family = WindowLabels.modelFamily(id)
            var kept = family
            while !kept.isEmpty, width(kept + "…") > room { kept.removeLast() }
            return kept
        }
        #expect(Set(shown).count == ids.count, "\(shown)")
        #expect(shown.allSatisfy { !$0.isEmpty })
    }

    @Test func oneRequestIsSingular() {
        #expect(WindowLabels.requests(1) == "1 request")
        #expect(WindowLabels.requests(2) == "2 requests")
        #expect(WindowLabels.requests(1_204) == "1,204 requests")
    }

    @Test func dayAndMonthAxesLabelOnlySomeColumns() {
        let labelled = { (range: DetailRange, count: Int) in
            (0..<count).filter { WindowLabels.axisLabel(now, index: $0, range: range) != nil }
        }
        #expect(labelled(.day, 24) == [0, 6, 12, 18])
        #expect(labelled(.week, 7).count == 7)
        #expect(labelled(.month, 30) == [2, 9, 16, 23])
        #expect(labelled(.year, 12).count == 12)
    }

    @Test func theDayAxisCountsHours() {
        #expect(WindowLabels.axisLabel(now, index: 6, range: .day) == "06")
    }

    @Test func aDaysCostKeepsItsCents() {
        #expect(WindowLabels.dayCost(DayCell(day: now, tokens: 100, costUSD: 98.74)) == "$98.74")
    }

    @Test func aDayOfTokensWithNoPriceSaysSo() {
        #expect(WindowLabels.dayCost(DayCell(day: now, tokens: 100, costUSD: 0)) == "no price")
    }

    @Test func aDayWithNothingInItIsZero() {
        #expect(WindowLabels.dayCost(DayCell(day: now, tokens: 0, costUSD: 0)) == "$0.00")
    }

    @Test func aUsualRangeInMoneyKeepsItsCents() {
        let band = UsualRange(p25: 14.6, median: 20, p75: 98.74)
        let bands = UsualBands(daily: band, now: band)
        #expect(WindowLabels.usual(bands, range: .week, isCost: true, daysOfUse: 14, todayHasUse: false, isReading: false) == "$14.60 to $98.74 a day")
        #expect(WindowLabels.usual(bands, range: .day, isCost: true, daysOfUse: 14, todayHasUse: false, isReading: false) == "$14.60 to $98.74")
    }

    @Test func everyPinnedCardHasATitle() {
        #expect(PinnedCard.allCases.allSatisfy { !WindowLabels.title(of: $0).isEmpty })
    }
}
