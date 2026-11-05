import Foundation
import Testing
@testable import TachoKit

struct LineReaderTests {
    /// Every line `LineReader` reports for `url`, as text, and its outcome.
    private func readLines(
        _ url: URL,
        from cursor: FileCursor? = nil,
        chunkSize: Int = LineReader.defaultChunkSize
    ) throws -> (lines: [String], outcome: LineReadOutcome) {
        var lines: [String] = []
        let outcome = try LineReader.read(url, from: cursor, chunkSize: chunkSize) { lines.append(String(decoding: $0, as: UTF8.self)) }
        return (lines, outcome)
    }

    private func newFile(_ name: String = "a.jsonl") throws -> URL {
        try makeTempDir().appendingPathComponent(name)
    }

    /// Appends raw bytes, which may end inside a multi-byte character.
    private func appendBytes(_ bytes: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }

    @Test func readsCompleteLinesAndHoldsPartialTail() throws {
        let file = try newFile()
        try write(["a", "b"], to: file)
        try append("part", to: file)
        let first = try readLines(file)
        #expect(first.lines == ["a", "b"])
        #expect(first.outcome.cursor.offset == 4)
        #expect(first.outcome.lines == 2)
        #expect(!first.outcome.restarted)

        try append("ial\n", to: file)
        let second = try readLines(file, from: first.outcome.cursor)
        #expect(second.lines == ["partial"])
        #expect(second.outcome.cursor.offset == 12)
        #expect(second.outcome.lines == 1)
        #expect(!second.outcome.restarted)
    }

    @Test func readsLinesLargerThanTheChunk() throws {
        let file = try newFile()
        try write([String(repeating: "x", count: 10_000_000), "y"], to: file)
        var lines: [Data] = []
        let outcome = try LineReader.read(file, from: nil, chunkSize: 1_048_576) { lines.append($0) }
        #expect(lines.count == 2)
        #expect(lines[0].count == 10_000_000)
        // Compared as one boolean: a failing `==` on 10 MB would print both sides.
        let firstIsAllX = lines[0] == Data(repeating: UInt8(ascii: "x"), count: 10_000_000)
        #expect(firstIsAllX)
        #expect(lines[1] == Data("y".utf8))
        #expect(outcome.cursor.offset == 10_000_003)
        #expect(outcome.lines == 2)
    }

    @Test func restartsWhenTruncated() throws {
        let file = try newFile()
        try write(["abcd", "efgh"], to: file)
        var stale = try readLines(file).outcome.cursor
        stale.offset = 100
        stale.size = 100
        let result = try readLines(file, from: stale)
        #expect(result.outcome.restarted)
        #expect(result.lines == ["abcd", "efgh"])
        #expect(result.outcome.cursor.offset == 10)
        #expect(result.outcome.cursor.size == 10)
    }

    @Test func restartsWhenTheSameFileIsRewrittenShorter() throws {
        let file = try newFile()
        try write(["first line", "second line"], to: file)
        let before = try readLines(file).outcome.cursor

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("new\n".utf8))
        try handle.close()

        let result = try readLines(file, from: before)
        #expect(result.outcome.cursor.inode == before.inode, "the rewrite must keep the inode for this test to exercise the length rule")
        #expect(result.outcome.restarted)
        #expect(result.lines == ["new"])
    }

    @Test func restartsWhenInodeChanges() throws {
        let file = try newFile()
        try write(["old"], to: file)
        let first = try readLines(file).outcome
        // Longer than the old offset, so only the inode tells the files apart.
        let replacement = file.deletingLastPathComponent().appendingPathComponent("replacement.tmp")
        try write(["new1", "new2"], to: replacement)
        #expect(rename(replacement.path, file.path) == 0)

        let second = try readLines(file, from: first.cursor)
        #expect(second.outcome.restarted)
        #expect(second.lines == ["new1", "new2"])
        #expect(second.outcome.cursor.inode != first.cursor.inode)
        #expect(second.outcome.cursor.offset == 10)
    }

    @Test func skipsEmptyLines() throws {
        let file = try newFile()
        try write(["a", "", "", "b"], to: file)
        let result = try readLines(file)
        #expect(result.lines == ["a", "b"])
        #expect(result.outcome.lines == 2)
        // The empty lines are consumed, not held back.
        #expect(result.outcome.cursor.offset == 6)
    }

    @Test func firstReadWithoutACursorIsNotARestart() throws {
        let file = try newFile()
        try write(["a"], to: file)
        let outcome = try readLines(file).outcome
        #expect(!outcome.restarted)
        #expect(outcome.cursor.state == nil)
        #expect(!outcome.cursor.complete)
    }

    @Test func cursorRecordsInodeSizeAndModificationTimeOfTheFile() throws {
        let file = try newFile()
        try write(["a", "b"], to: file)
        try append("part", to: file)
        let cursor = try readLines(file).outcome.cursor

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(cursor.inode == (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        #expect(cursor.size == 8)
        #expect(cursor.size == (attributes[.size] as? NSNumber)?.uint64Value)
        let modified = try #require(attributes[.modificationDate] as? Date)
        #expect(abs(cursor.mtime.timeIntervalSince(modified)) < 0.001)
    }

    @Test func aCursorSurvivesAJSONRoundTripUnchanged() throws {
        let file = try newFile()
        try write(["a", "b"], to: file)
        try append("part", to: file)
        var cursor = try readLines(file).outcome.cursor
        cursor.state = Data(#"{"pendingStart":1793697600.709}"#.utf8)
        cursor.complete = true

        // The store keeps cursors as JSON; the modification time must come back exactly, or an unchanged file would look changed.
        let decoded = try JSONDecoder().decode(FileCursor.self, from: JSONEncoder().encode(cursor))
        #expect(decoded == cursor)
        #expect(decoded.mtime == cursor.mtime)
    }

    @Test func readingAgainWithoutNewDataChangesNothing() throws {
        let file = try newFile()
        try write(["a", "b"], to: file)
        try append("part", to: file)
        let first = try readLines(file).outcome
        let second = try readLines(file, from: first.cursor)
        #expect(second.lines.isEmpty)
        #expect(second.outcome.lines == 0)
        #expect(!second.outcome.restarted)
        #expect(second.outcome.cursor == first.cursor)
    }

    @Test func emptyFileHasNothingToRead() throws {
        let file = try newFile()
        try Data().write(to: file)
        let outcome = try readLines(file).outcome
        #expect(outcome.lines == 0)
        #expect(outcome.cursor.offset == 0)
        #expect(outcome.cursor.size == 0)
    }

    @Test func readerStateAndCompleteFlagSurviveAContinuedRead() throws {
        let file = try newFile()
        try write(["a"], to: file)
        var cursor = try readLines(file).outcome.cursor
        cursor.state = Data(#"{"pending":1}"#.utf8)
        cursor.complete = true
        try append("b\n", to: file)

        let result = try readLines(file, from: cursor)
        #expect(result.lines == ["b"])
        #expect(result.outcome.cursor.state == Data(#"{"pending":1}"#.utf8))
        #expect(result.outcome.cursor.complete)
    }

    @Test func restartDropsReaderStateAndCompleteFlag() throws {
        let file = try newFile()
        try write(["abcd", "efgh"], to: file)
        var stale = try readLines(file).outcome.cursor
        stale.offset = 100
        stale.state = Data(#"{"pending":1}"#.utf8)
        stale.complete = true

        let result = try readLines(file, from: stale)
        #expect(result.outcome.restarted)
        #expect(result.outcome.cursor.state == nil)
        #expect(!result.outcome.cursor.complete)
    }

    @Test func chunkSizeDoesNotChangeTheResult() throws {
        let file = try newFile()
        // Multi-byte characters, empty lines and an unfinished last line, cut at every possible place.
        let text = "héllo wörld ✓\n\nsecond\n\n\n{\"k\":\"ü\"}\nlast complete line\npartial tail ✓"
        try Data(text.utf8).write(to: file)
        let expected = try readLines(file)
        #expect(expected.lines == ["héllo wörld ✓", "second", "{\"k\":\"ü\"}", "last complete line"])
        #expect(expected.outcome.cursor.offset == UInt64(text.utf8.count - "partial tail ✓".utf8.count))
        for chunkSize in 1...(text.utf8.count + 2) {
            let result = try readLines(file, chunkSize: chunkSize)
            #expect(result.lines == expected.lines, "chunk size \(chunkSize)")
            #expect(result.outcome == expected.outcome, "chunk size \(chunkSize)")
        }
    }

    @Test func tailingAtAnyByteBoundaryYieldsEveryLineExactlyOnce() throws {
        let text = Data("alpha\nβ\n\ngamma ✓\ndelta\nepsilon".utf8)
        let dir = try makeTempDir()
        let whole = dir.appendingPathComponent("whole.jsonl")
        try text.write(to: whole)
        let expected = try readLines(whole).lines
        #expect(expected == ["alpha", "β", "gamma ✓", "delta"])

        for cut in 0...text.count {
            let file = dir.appendingPathComponent("cut-\(cut).jsonl")
            try text.prefix(cut).write(to: file)
            let first = try readLines(file, chunkSize: 4)
            try appendBytes(text.dropFirst(cut), to: file)
            let second = try readLines(file, from: first.outcome.cursor, chunkSize: 4)
            #expect(first.lines + second.lines == expected, "cut at byte \(cut)")
            #expect(!second.outcome.restarted, "cut at byte \(cut)")
        }
    }

    @Test func aPartialLineLongerThanTheChunkIsHeldUntilItsNewlineArrives() throws {
        let file = try newFile()
        try Data(String(repeating: "z", count: 5_000).utf8).write(to: file)
        let first = try readLines(file, chunkSize: 64)
        #expect(first.lines.isEmpty)
        #expect(first.outcome.cursor.offset == 0)

        try append("\nnext\n", to: file)
        let second = try readLines(file, from: first.outcome.cursor, chunkSize: 64)
        #expect(second.lines == [String(repeating: "z", count: 5_000), "next"])
        #expect(second.outcome.cursor.offset == 5_006)
    }

    @Test func leavesBytesAppendedDuringTheReadForTheNextRead() throws {
        let file = try newFile()
        try write(["a", "b"], to: file)
        var seen: [String] = []
        var appended = false
        let first = try LineReader.read(file, from: nil, chunkSize: 2) { line in
            seen.append(String(decoding: line, as: UTF8.self))
            if !appended {
                appended = true
                try append("c\n", to: file)
            }
        }
        #expect(seen == ["a", "b"])
        // The snapshot taken on opening: the cursor never claims bytes the read did not see.
        #expect(first.cursor.size == 4)
        #expect(first.cursor.offset == 4)

        let second = try readLines(file, from: first.cursor)
        #expect(second.lines == ["c"])
    }

    @Test func anErrorThrownByTheClosureStopsTheRead() throws {
        struct Stop: Error {}
        let file = try newFile()
        try write(["a", "b", "c"], to: file)
        var seen = 0
        #expect(throws: Stop.self) {
            try LineReader.read(file, from: nil) { _ in
                seen += 1
                if seen == 2 { throw Stop() }
            }
        }
        #expect(seen == 2)
    }

    @Test func aMissingFileThrows() throws {
        let missing = try newFile("missing.jsonl")
        #expect(throws: (any Error).self) {
            try LineReader.read(missing, from: nil) { _ in }
        }
    }
}
