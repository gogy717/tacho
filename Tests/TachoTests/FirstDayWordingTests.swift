import Foundation
import Testing
@testable import Tacho
import TachoKit

/// What a stranger reads on a first day, in both languages.
struct FirstDayWordingTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Tacho/Resources")

    private func strings(_ language: String) throws -> [String: String] {
        let data = try Data(contentsOf: Self.resources.appendingPathComponent("\(language).lproj/Localizable.strings"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    private let now = Date(timeIntervalSince1970: 1_793_800_000)

    @Test(arguments: ["en", "zh-Hans"])
    func theAdviceForOtherCLIsNamesNoneOfThem(language: String) throws {
        let said = try #require(try strings(language)["limit.say.noQuotaOther"])
        #expect(!said.contains("Claude"))
    }

    @Test func aMacWithoutClaudeHearsNothingAboutClaude() throws {
        let said = try #require(Labels.limitSay(LimitsInsight(rule: .l9, limit: nil), now: now).0)
        #expect(!said.contains("Claude"))
        #expect(!said.isEmpty)
    }

    /// `week.needsDays` is drawn on a page this lane does not touch, with today in its count: on the 14th day it reads "14 so far" with no
    /// comparison yet, so "needs 14" would be false and "after 14" stays true.
    @Test func aFourteenthDayIsNotCalledShort() throws {
        let said = try #require(try strings("en")["week.needsDays"])
        #expect(said.contains("after 14 days"))
    }

    @Test func aFailedPanelSaysNothingWasLost() throws {
        #expect(try #require(try strings("en")["popover.unavailable"]).contains("Nothing has been deleted"))
        #expect(try #require(try strings("zh-Hans")["popover.unavailable"]).contains("没有删除"))
    }

    /// The old file is kept and the logs are read again, and the sentence must not claim that nothing is lost: logs a CLI has
    /// since deleted cannot be read again.
    @Test(arguments: ["en", "zh-Hans"])
    func aSetAsideIndexSaysWhatHappened(language: String) throws {
        let said = try #require(try strings(language)["popover.indexSetAside"])
        #expect(said.contains(language == "en" ? "old file is kept" : "旧文件还在"))
        #expect(!said.contains("Nothing"))
    }

    @Test(arguments: [("highlight.h2Tomorrow", "常见范围"), ("limit.say.noQuotaOther", "额度")])
    func chineseKeepsTheUsersTerms(key: String, term: String) throws {
        #expect(try #require(try strings("zh-Hans")[key]).contains(term))
    }

    // The clock.

    @Test func aClockSetBackIsNamed() {
        #expect(Labels.clockBehind(newestEvent: now.addingTimeInterval(3_600), now: now) != nil)
    }

    /// A CLI's stamp can run a little ahead of this Mac's clock, and that is no reason to worry anyone.
    @Test func aFewSecondsAheadIsNothing() {
        #expect(Labels.clockBehind(newestEvent: now.addingTimeInterval(30), now: now) == nil)
        #expect(Labels.clockBehind(newestEvent: now.addingTimeInterval(-3_600), now: now) == nil)
        #expect(Labels.clockBehind(newestEvent: nil, now: now) == nil)
    }
}
