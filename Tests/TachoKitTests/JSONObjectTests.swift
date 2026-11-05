import Foundation
import Testing
import os
@testable import TachoKit

struct JSONObjectTests {
    private func object(_ json: String) throws -> JSONObject {
        try #require(JSONObject(Data(json.utf8)), "not a JSON object: \(json)")
    }

    /// 2026-11-03T09:20:00Z
    private let nineTwenty = 1_793_697_600.0

    private func isInstant(_ date: Date?, _ epochSeconds: Double, tolerance: Double = 1e-6) -> Bool {
        guard let date else { return false }
        return abs(date.timeIntervalSince1970 - epochSeconds) < tolerance
    }

    // MARK: Timestamps

    @Test func parsesTimestampsOfEveryCLI() throws {
        let record = try object(#"""
        {"claude":"2026-10-31T18:22:33.235Z","grok":"2026-11-03T09:20:00.709695+00:00","omp":1793682935820,"codex":1792555400}
        """#)
        #expect(record.date("claude") == date("2026-10-31T18:22:33.235Z"))
        let grok = try #require(record.date("grok"))
        // 1e-6 is stricter than the 1e-3 the brief asks for: dropping the microseconds would already miss it.
        #expect(abs(grok.timeIntervalSince1970 - 1_793_697_600.709695) < 1e-6)
        #expect(record.date("omp") == ms(1_793_682_935_820))
        #expect(record.date("codex") == Date(timeIntervalSince1970: 1_792_555_400))
    }

    @Test func wholeSecondsAndThreeDigitFractionsAreExactlyWhatTheFormatterGives() throws {
        let record = try object(#"{"whole":"2026-11-03T10:00:00Z","millis":"2026-11-03T09:20:00.500Z","offset":"2026-11-03T14:50:00+05:30"}"#)
        #expect(record.date("whole") == date("2026-11-03T10:00:00Z"))
        #expect(record.date("millis") == date("2026-11-03T09:20:00.500Z"))
        #expect(record.date("offset") == date("2026-11-03T14:50:00+05:30"))
    }

    @Test func keepsFractionsOfEveryLength() throws {
        let record = try object(#"""
        {"one":"2026-11-03T09:20:00.5Z","two":"2026-11-03T09:20:00.25Z","three":"2026-11-03T09:20:00.125Z",
         "six":"2026-11-03T09:20:00.709695Z","nine":"2026-11-03T09:20:00.123456789Z","thirteen":"2026-11-03T09:20:00.1234567891234Z"}
        """#)
        #expect(isInstant(record.date("one"), nineTwenty + 0.5))
        #expect(isInstant(record.date("two"), nineTwenty + 0.25))
        #expect(isInstant(record.date("three"), nineTwenty + 0.125))
        #expect(isInstant(record.date("six"), nineTwenty + 0.709695))
        #expect(isInstant(record.date("nine"), nineTwenty + 0.123456789))
        #expect(isInstant(record.date("thirteen"), nineTwenty + 0.1234567891))
    }

    @Test func appliesZoneOffsetsWithAndWithoutFractions() throws {
        let record = try object(#"""
        {"utc":"2026-11-03T09:20:00+00:00","east":"2026-11-03T14:50:00+05:30","west":"2026-11-03T01:20:00-08:00",
         "eastFraction":"2026-11-03T14:50:00.709695+05:30","westFraction":"2026-11-03T01:20:00.5-08:00"}
        """#)
        #expect(isInstant(record.date("utc"), nineTwenty))
        #expect(isInstant(record.date("east"), nineTwenty))
        #expect(isInstant(record.date("west"), nineTwenty))
        #expect(isInstant(record.date("eastFraction"), nineTwenty + 0.709695))
        #expect(isInstant(record.date("westFraction"), nineTwenty + 0.5))
    }

    @Test func numbersFromOneE11UpAreMillisecondsAndSmallerOnesAreSeconds() throws {
        let record = try object(#"""
        {"justBelow":99999999999,"threshold":100000000000,"seconds":1792555400,"fractionalSeconds":1792555400.25,
         "millis":1793682935820,"fractionalMillis":1793682935820.5,"zero":0,"negative":-86400}
        """#)
        #expect(record.date("justBelow") == Date(timeIntervalSince1970: 99_999_999_999))
        #expect(record.date("threshold") == ms(100_000_000_000))
        #expect(record.date("seconds") == Date(timeIntervalSince1970: 1_792_555_400))
        #expect(record.date("fractionalSeconds") == Date(timeIntervalSince1970: 1_792_555_400.25))
        #expect(record.date("millis") == ms(1_793_682_935_820))
        #expect(record.date("fractionalMillis") == ms(1_793_682_935_820.5))
        #expect(record.date("zero") == Date(timeIntervalSince1970: 0))
        #expect(record.date("negative") == Date(timeIntervalSince1970: -86_400))
    }

    @Test func dateReadsNestedPaths() throws {
        let record = try object(#"{"message":{"time":{"completed":1793474007189},"at":"2026-11-03T09:20:00Z"}}"#)
        #expect(record.date("message", "time", "completed") == ms(1_793_474_007_189))
        #expect(isInstant(record.date("message", "at"), nineTwenty))
    }

    @Test func valuesThatAreNotTimestampsAreNil() throws {
        let record = try object(#"""
        {"empty":"","words":"yesterday","dateOnly":"2026-11-03","noZone":"2026-11-03T09:20:00","noSeconds":"2026-11-03T09:20Z",
         "emptyFraction":"2026-11-03T09:20:00.Z","monthThirteen":"2026-13-03T09:20:00Z","hour25":"2026-11-03T25:00:00Z",
         "numberText":"1793682935820","yes":true,"no":false,"nothing":null,"list":[1],"nested":{"a":1}}
        """#)
        for key in ["empty", "words", "dateOnly", "noZone", "noSeconds", "emptyFraction", "monthThirteen", "hour25",
                    "numberText", "yes", "no", "nothing", "list", "nested", "missing"] {
            #expect(record.date(key) == nil, "\(key)")
        }
        #expect(record.date("words", "deeper") == nil)
    }

    @Test func parsesTimestampsFromManyThreadsAtOnce() {
        let line = Data(#"{"fraction":"2026-11-03T09:20:00.709695+00:00","plain":"2026-11-03T14:50:00+05:30"}"#.utf8)
        let wrong = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 400) { _ in
            guard let record = JSONObject(line),
                  let fraction = record.date("fraction")?.timeIntervalSince1970,
                  let plain = record.date("plain")?.timeIntervalSince1970,
                  abs(fraction - 1_793_697_600.709695) < 1e-6, plain == 1_793_697_600
            else {
                wrong.withLock { $0 += 1 }
                return
            }
        }
        #expect(wrong.withLock { $0 } == 0)
    }

    // MARK: Typed lookups

    @Test func readsTypedValuesAtNestedPaths() throws {
        let record = try object(#"""
        {"type":"assistant","message":{"ok":true,"usage":{"input_tokens":2,"speed":"standard","cost":0.25}},"tags":["a","b"]}
        """#)
        #expect(record.string("type") == "assistant")
        #expect(record.string("message", "usage", "speed") == "standard")
        #expect(record.int("message", "usage", "input_tokens") == 2)
        #expect(record.double("message", "usage", "cost") == 0.25)
        #expect(record.double("message", "usage", "input_tokens") == 2)
        #expect(record.bool("message", "ok") == true)
        #expect(record.object("message", "usage")?.int("input_tokens") == 2)
        #expect(record.object("message")?.object("usage")?.string("speed") == "standard")
        #expect(record.array("tags")?.compactMap { $0 as? String } == ["a", "b"])
    }

    @Test func missingKeysAndWrongTypesAreNil() throws {
        let record = try object(#"{"s":"x","n":5,"b":true,"nothing":null,"o":{"k":1},"a":[1]}"#)
        // Missing keys, also behind a value that is not an object.
        #expect(record.string("nope") == nil)
        #expect(record.string("o", "nope") == nil)
        #expect(record.string("s", "deeper") == nil)
        #expect(record.int("n", "deeper") == nil)
        #expect(record.object("a", "deeper") == nil)
        // Another JSON type than asked for.
        #expect(record.string("n") == nil)
        #expect(record.string("o") == nil)
        #expect(record.int("s") == nil)
        #expect(record.double("s") == nil)
        #expect(record.bool("s") == nil)
        #expect(record.object("a") == nil)
        #expect(record.object("s") == nil)
        #expect(record.array("o") == nil)
        #expect(record.array("s") == nil)
        // null is a value of no type.
        #expect(record.string("nothing") == nil)
        #expect(record.int("nothing") == nil)
        #expect(record.object("nothing") == nil)
    }

    @Test func booleansAreNotNumbersAndNumbersAreNotBooleans() throws {
        let record = try object(#"{"yes":true,"no":false,"one":1,"zero":0}"#)
        #expect(record.bool("yes") == true)
        #expect(record.bool("no") == false)
        #expect(record.bool("one") == nil)
        #expect(record.bool("zero") == nil)
        #expect(record.int("yes") == nil)
        #expect(record.int("no") == nil)
        #expect(record.double("yes") == nil)
        #expect(record.int("one") == 1)
        #expect(record.int("zero") == 0)
    }

    @Test func integersMustBeWholeAndFit() throws {
        let record = try object(#"""
        {"whole":3.0,"fraction":1.5,"exponent":2e3,"negative":-7,"max":9223372036854775807,"over":18446744073709551615,"huge":1e30}
        """#)
        #expect(record.int("whole") == 3)
        #expect(record.int("fraction") == nil)
        #expect(record.int("exponent") == 2000)
        #expect(record.int("negative") == -7)
        #expect(record.int("max") == Int.max)
        #expect(record.int("over") == nil)
        #expect(record.int("huge") == nil)
        #expect(record.double("fraction") == 1.5)
        #expect(record.double("negative") == -7)
        #expect(record.double("huge") == 1e30)
    }

    @Test func anEmptyPathIsTheObjectItself() throws {
        let record = try object(#"{"a":1}"#)
        #expect(record.object()?.int("a") == 1)
        #expect(record.string() == nil)
        #expect(record.int() == nil)
        #expect(record.array() == nil)
    }

    // MARK: Construction

    @Test func onlyAJSONObjectOnTheTopLevelParses() {
        for text in ["[1,2]", "[]", #""text""#, "12", "true", "null", "", "   ", "{", #"{"a":}"#, "not json", #"{"a":1} {"b":2}"#] {
            #expect(JSONObject(Data(text.utf8)) == nil, "\(text)")
        }
        #expect(JSONObject(Data([0xFF, 0xFE, 0x00])) == nil)
        #expect(JSONObject(Data("{}".utf8)) != nil)
        #expect(JSONObject(Data(" {\"a\" : 1}\n".utf8)) != nil)
    }

    @Test func parsesADataSliceThatDoesNotStartAtZero() throws {
        let line = Data(#"junk{"a":1}"#.utf8).dropFirst(4)
        #expect(line.startIndex == 4)
        #expect(JSONObject(line)?.int("a") == 1)
    }

    @Test func wrapsAnExistingDictionary() throws {
        let record = try object(#"{"items":[{"k":"v1"},{"k":"v2"},"stray"]}"#)
        let items = try #require(record.array("items"))
        let values = items.compactMap { $0 as? [String: Any] }.map { JSONObject($0).string("k") }
        #expect(values == ["v1", "v2"])
        #expect(JSONObject(["a": ["b": 1]]).int("a", "b") == 1)
    }

    // MARK: dataContains

    @Test func dataContainsFindsABytePatternAnywhere() {
        let line = Data(#"{"type":"assistant","message":{"usage":{"input_tokens":2}}}"#.utf8)
        #expect(dataContains(line, #""usage""#))
        #expect(dataContains(line, #""type":"assistant""#))
        #expect(!dataContains(line, #""type":"user""#))
        #expect(dataContains(line, #"{"type""#))
        #expect(dataContains(line, "2}}}"))
        #expect(!dataContains(line, "2}}}}"))
        #expect(dataContains(line, "{"))
    }

    @Test func dataContainsHandlesTheEdgesOfTheSize() {
        #expect(dataContains(Data("abc".utf8), "abc"))
        #expect(!dataContains(Data("ab".utf8), "abc"))
        #expect(dataContains(Data("abc".utf8), ""))
        #expect(dataContains(Data(), ""))
        #expect(!dataContains(Data(), "a"))
    }

    @Test func dataContainsComparesBytesAndRespectsSlices() {
        let text = Data("xxéyy".utf8)
        #expect(dataContains(text, "é"))
        let slice = text.dropFirst(2)
        #expect(slice.startIndex == 2)
        #expect(dataContains(slice, "yy"))
        #expect(dataContains(slice, "é"))
        #expect(!dataContains(slice, "xx"))
        #expect(!dataContains(text.dropLast(2), "yy"))
    }
}
