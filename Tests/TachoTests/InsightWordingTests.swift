import Foundation
import Testing
@testable import Tacho
import TachoKit

/// Every rule's sentence. The rules themselves are `Insights.compute`'s; here is what each one says.
struct InsightWordingTests {
    private let now = Date(timeIntervalSince1970: 1_793_800_000)

    private func en(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .tacho) }

    private func limit(percent: Double = 40, outcome: Projection.Outcome = .lastsUntilReset) -> Projection {
        let reset = now.addingTimeInterval(7_200)
        let snapshot = QuotaSnapshot(provider: .anthropic, window: .fiveHour, scope: nil, usedPercent: percent, resetsAt: reset, observedAt: now, origin: .claudeCache)
        return Projection(snapshot: snapshot, estimatedPercent: percent, isEstimate: false, method: .calibrated, outcome: outcome, isStale: false, resetsAt: reset)
    }

    // Rules H.
    @Test func theHighlightSentences() {
        #expect(Labels.sentence(.h1) == en("highlight.h1"))
        #expect(Labels.sentence(.h1h) == en("highlight.h1h"))
        #expect(Labels.sentence(.h2(soFar: 2)).contains("2"))
        #expect(Labels.sentence(.h2(soFar: 6)).contains("6"))
        #expect(Labels.sentence(.h2(soFar: 7)) == en("highlight.h2Tomorrow"))
        #expect(Labels.sentence(.h3) == en("highlight.h3"))
        #expect(Labels.sentence(.h4(times: 5.3)).contains("5.3"))
        #expect(Labels.sentence(.h5(percent: 30)).contains("30%"))
        #expect(Labels.sentence(.h5s) == en("highlight.h5s"))
        #expect(Labels.sentence(.h6) == en("highlight.h6"))
        #expect(Labels.sentence(.h7(percent: 61)).contains("61%"))
        #expect(Labels.sentence(.h7s) == en("highlight.h7s"))
        #expect(Labels.sentence(.h7f) == en("highlight.h7f"))
        #expect(Labels.sentence(.h8) == en("highlight.h8"))
        #expect(Labels.sentence(.h9) == en("highlight.h9"))
    }

    @Test func noTwoRulesShareASentence() {
        let rules: [TodayRule] = [.h1, .h1h, .h2(soFar: 2), .h3, .h4(times: 5), .h5(percent: 30), .h5s, .h6, .h7(percent: 61), .h7s, .h7f, .h8, .h9]
        #expect(Set(rules.map(Labels.sentence)).count == rules.count)
    }

    // Rules L.
    @Test func theLimitSentences() throws {
        let at = now.addingTimeInterval(1_800)
        let used = try #require(Labels.limitSay(LimitsInsight(rule: .l1, limit: limit(percent: 100)), now: now).0)
        #expect(used.contains("Anthropic"))
        #expect(used.contains(Labels.clock(limit().resetsAt)))
        let high = try #require(Labels.limitSay(LimitsInsight(rule: .l2, limit: limit(percent: 92)), now: now).0)
        #expect(high.contains("92%"))
        let pace = try #require(Labels.limitSay(LimitsInsight(rule: .l3, limit: limit(outcome: .runsOut(at: at, beforeReset: 5_400))), now: now).0)
        #expect(pace.contains(Labels.clock(at)))
        #expect(pace.contains(Labels.duration(5_400)))
        #expect(Labels.limitSay(LimitsInsight(rule: .l4, limit: limit()), now: now).0 == en("limit.say.clear"))
        #expect(Labels.limitSay(LimitsInsight(rule: .l5, limit: limit()), now: now).0 == en("limit.say.noRisk"))
        #expect(Labels.limitSay(LimitsInsight(rule: .l6, limit: nil), now: now).0 == en("limit.say.noRecent"))
        #expect(Labels.limitSay(LimitsInsight(rule: .l7, limit: nil), now: now).0 == en("limit.say.noQuota"))
        #expect(Labels.limitSay(LimitsInsight(rule: .l8, limit: nil), now: now).0 == en("limit.say.waiting"))
    }

    /// A sentence that gives two times and the gap between them must not contradict itself.
    @Test func aLimitSentencesGapIsWhatItsTwoTimesSubtractTo() {
        let now = WindowSamples.now
        for gap in WindowSamples.gaps {
            let quota = WindowSamples.projection(empties: gap.empties, resets: gap.resets)
            let empty = Labels.reset(gap.empties, now: now)
            let reset = Labels.reset(gap.resets, now: now)
            #expect(Labels.limitSay(LimitsInsight(rule: .l3, limit: quota), now: now).0 == "Anthropic 5 hours: at this pace empty about \(empty), \(gap.short) before the \(reset) reset.")
        }
    }

    @Test func theToneFollowsTheRule() {
        #expect(Labels.limitSay(LimitsInsight(rule: .l1, limit: limit(percent: 100)), now: now).1 == .critical)
        #expect(Labels.limitSay(LimitsInsight(rule: .l2, limit: limit(percent: 92)), now: now).1 == .critical)
        #expect(Labels.limitSay(LimitsInsight(rule: .l3, limit: limit(outcome: .runsOut(at: now, beforeReset: 60))), now: now).1 == .warning)
        #expect(Labels.limitSay(LimitsInsight(rule: .l4, limit: limit()), now: now).1 == .plain)
        #expect(Labels.limitSay(LimitsInsight(rule: .l7, limit: nil), now: now).1 == .plain)
    }

    @Test func aRuleWithNoLimitToNameSaysNothingFalse() {
        #expect(Labels.limitSay(LimitsInsight(rule: .l1, limit: nil), now: now).0 == nil)
        #expect(Labels.limitSay(LimitsInsight(rule: .l3, limit: limit()), now: now).0 == nil)
    }

    // Rules P.
    @Test func theOutputSays() {
        #expect(Labels.say(.p1) == en("say.output.above"))
        #expect(Labels.say(.p2) == en("say.output.inside"))
        #expect(Labels.say(.p3) == en("say.output.below"))
        #expect(Labels.say(.p4(daysLeft: 5)).contains("5"))
        #expect(Labels.say(.p4s) == en("say.needsDay"))
        #expect(Labels.say(OutputRule.readingLogs) == "still reading logs")
    }

    @Test func theCacheSays() {
        #expect(Labels.say(.p5(usd: 864)).contains("$864"))
        #expect(Labels.say(.p6(usd: 864)).contains("$864+"))
        #expect(Labels.say(.p7) == en("cost.noPrice"))
    }

    @Test func theSpeedSays() {
        let model = "claude-opus-5-5"
        #expect(Labels.say(.p8, model: model) == String(format: en("say.speed.usual"), "Opus 5.5"))
        #expect(Labels.say(.p9, model: model) == "Opus 5.5, faster than usual")
        #expect(Labels.say(.p10, model: model) == "Opus 5.5, slower than usual")
        #expect(Labels.say(.readingLogs, model: model) == "still reading logs")
        #expect(Labels.say(.p4(daysLeft: 3), model: model).contains("3"))
        #expect(Labels.say(.p4s, model: model) == en("say.needsDay"))
    }

    @Test func theWhenSays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let first = Labels.say(.p14(weekdayRow: 0, fromHour: 9, toHour: 12), calendar: calendar)
        #expect(first.hasPrefix("Busiest: Mon, and "))
        #expect(Labels.say(.p14(weekdayRow: 6, fromHour: 9, toHour: 12), calendar: calendar).hasPrefix("Busiest: Sun, and "))
        calendar.firstWeekday = 1
        #expect(Labels.say(.p14(weekdayRow: 0, fromHour: 9, toHour: 12), calendar: calendar).hasPrefix("Busiest: Sun, and "))
        #expect(Labels.say(.needsDays(daysLeft: 4)) == String(format: en("say.needsDays"), 4))
        #expect(Labels.say(.needsDays(daysLeft: 1)) == en("say.needsDay"))
        #expect(Labels.say(WhenRule.readingLogs) == "still reading logs")
    }

    @Test func theBlockRunsFromClockToClock() {
        let text = Labels.say(.p14(weekdayRow: 0, fromHour: 22, toHour: 1))
        let night = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: now) ?? now
        let morning = Calendar.current.date(bySettingHour: 1, minute: 0, second: 0, of: now) ?? now
        #expect(text.hasSuffix("\(Labels.clock(night)) to \(Labels.clock(morning))"))
    }

    @Test func theCacheReadsSay() {
        #expect(Labels.cacheReads(90) == "90% are cache reads")
    }

    @Test func theRetiredWordingIsNowhere() throws {
        let path = try #require(Bundle.tacho.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en"))
        let strings = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
        for phrase in ["Runs out in", "Lasts until", "Resets in", "On track", "Running hot", "Room to spare", "Saved $", "from cache"] {
            #expect(!strings.values.contains { $0.contains(phrase) })
        }
    }
}
