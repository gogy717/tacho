import Foundation
import Testing
@testable import Tacho
import TachoKit

/// What a row of the Settings price table says of where its price came from.
struct PricesEditorTests {
    private func row(source: String?, asOf: String? = nil) -> PriceEntry {
        PriceEntry(id: "a-model", provider: "xai", price: Price(input: 1, output: 1, cacheRead: 1, cacheWrite5m: 1, cacheWrite1h: 1), source: source, asOf: asOf)
    }

    @Test func aPageIsALinkNamedForItsHost() throws {
        let page = "https://docs.x.ai/docs/models"
        #expect(PriceOrigin(row(source: page)) == .page(try #require(URL(string: page)), name: "docs.x.ai"))
    }

    /// Saying "Set by you" of a price the person never set would be false, and so would a link to nowhere.
    @Test func aSourceThatIsNoPageIsSaidInWords() {
        let note = "The maintainer's decision of 2026-11-05: priced as grok-4.7. Not from xAI's page."
        #expect(PriceOrigin(row(source: note)) == .note(note))
    }

    @Test func aSentenceThatParsesAsAURLIsStillNoPage() {
        #expect(PriceOrigin(row(source: "note:not-a-page")) == .note("note:not-a-page"))
    }

    @Test func aRowWithNoSourceIsThePersons() {
        #expect(PriceOrigin(row(source: nil)) == .yours)
    }

    /// The rows the table must show, and what each must say of itself.
    @Test(arguments: ["grok-4.7-build", "grok-4.7-build-fast"]) func theTableShowsGrokBuildAndSaysItIsNoPagesPrice(id: String) throws {
        let table = try PriceTable.bundled()
        let row = try #require(table.entries.first { $0.id == id })
        #expect(PriceOrigin(row) == .note(try #require(row.source)))
    }
}
