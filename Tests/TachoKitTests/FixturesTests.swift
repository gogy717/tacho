import Foundation
import Testing

struct FixturesTests {
    @Test func jsonLineIsCompactWithSortedKeys() {
        let line = jsonLine(["b": 1, "a": ["z": true, "y": "x"], "c": [1, 2]])
        #expect(line == #"{"a":{"y":"x","z":true},"b":1,"c":[1,2]}"#)
    }

    @Test func makeTempDirReturnsAFreshExistingDirectoryEachTime() throws {
        let first = try makeTempDir()
        let second = try makeTempDir()
        #expect(first != second)
        for url in [first, second] {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }

    @Test func writeEndsEveryLineWithANewline() throws {
        let file = try makeTempDir().appendingPathComponent("a.jsonl")
        try write(["one", "two"], to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one\ntwo\n")
    }

    @Test func writeReplacesPreviousContentAndCreatesParentDirectories() throws {
        let file = try makeTempDir().appendingPathComponent("projects/p/s.jsonl")
        try write(["a long first line"], to: file)
        try write(["x"], to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "x\n")
    }

    @Test func appendAddsTextAtTheEndWithoutAddingANewline() throws {
        let file = try makeTempDir().appendingPathComponent("a.jsonl")
        try write(["a"], to: file)
        try append("par", to: file)
        try append("tial\n", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "a\npartial\n")
    }

    @Test func dateParsesWholeAndFractionalSeconds() {
        #expect(date("2026-11-03T10:00:00Z") == Date(timeIntervalSince1970: 1_793_700_000))
        #expect(date("2026-11-03T09:20:00.500Z") == Date(timeIntervalSince1970: 1_793_697_600.5))
        #expect(date("2026-11-03T14:50:00+05:30") == Date(timeIntervalSince1970: 1_793_697_600))
    }

    @Test func msIsEpochMilliseconds() {
        #expect(ms(1_793_697_600_000) == Date(timeIntervalSince1970: 1_793_697_600))
        #expect(ms(1_793_697_600_500) == Date(timeIntervalSince1970: 1_793_697_600.5))
    }

    @Test func dateAndMsAgreeOnTheSameInstant() {
        #expect(date("2026-10-31T18:22:35.360Z") == ms(1_793_470_955_360))
    }
}
