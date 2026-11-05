import Foundation
import Testing

/// Both languages, read from the files themselves. A key missing from one shows its raw name to the person reading it.
struct LocalizationTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Tacho")

    private static func strings(_ language: String) throws -> [String: String] {
        let url = sources.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        let list = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(list as? [String: String])
    }

    /// What the code asks for by a literal key.
    private static func keysInCode() throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"(?:localized: |item\(|localized: [^"\n]*\? |localized: [^"\n]*\? "[A-Za-z0-9_.]+" : )"([A-Za-z0-9_.]+)""#)
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var keys = Set<String>()
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                keys.insert(String(text[try #require(Range(match.range(at: 1), in: text))]))
            }
        }
        return keys
    }

    /// `%@`, `%ld`, `%1$@`: `String(format:)` crashes or prints nonsense when the two languages differ.
    private static func placeholders(_ text: String) throws -> [String] {
        let pattern = try NSRegularExpression(pattern: #"%(?:(\d)\$)?(@|ld)"#)
        let range = NSRange(text.startIndex..., in: text)
        return try pattern.matches(in: text, range: range).enumerated().map { index, match in
            let position = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? String(index + 1)
            return position + String(text[try #require(Range(match.range(at: 2), in: text))])
        }.sorted()
    }

    @Test func bothLanguagesHaveTheSameKeys() throws {
        #expect(Set(try Self.strings("en").keys) == Set(try Self.strings("zh-Hans").keys))
    }

    /// The parser keeps one and says nothing, and two lanes add to these files: `more.count` once meant two different things.
    @Test(arguments: ["en", "zh-Hans"])
    func noKeyIsDefinedTwice(language: String) throws {
        let url = Self.sources.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"^"([^"]+)"\s*="#, options: .anchorsMatchLines)
        let keys = try pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[try #require(Range($0.range(at: 1), in: text))])
        }
        #expect(Dictionary(grouping: keys) { $0 }.filter { $0.value.count > 1 }.keys.sorted() == [])
    }

    @Test func everyKeyTheCodeAsksForExists() throws {
        let english = try Self.strings("en")
        #expect(try Self.keysInCode().subtracting(english.keys).sorted() == [])
    }

    @Test func aStringTakesTheSameValuesInBothLanguages() throws {
        let chinese = try Self.strings("zh-Hans")
        for (key, text) in try Self.strings("en") {
            #expect(try Self.placeholders(text) == Self.placeholders(chinese[key] ?? ""), "\(key)")
        }
    }

    @Test func noneOfClaudeBarsWordingCameAcross() throws {
        let banned = ["Runs out in", "Lasts until", "Resets in", "On track", "Running hot", "Room to spare", "Saved $", "% from cache"]
        for text in try Self.strings("en").values {
            #expect(!banned.contains { text.contains($0) }, "\(text)")
        }
    }
}
