import Foundation
import Testing
import TachoKit

struct PreferencesTests {
    private let home = URL(fileURLWithPath: "/nowhere")

    private func loaded(pinnedCards: Any) throws -> Preferences {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences.defaults(home: home))) as? [String: Any])
        object["pinnedCards"] = pinnedCards
        return try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// A later version's card is lost on its own, and the rest of what the user pinned stays in their order.
    @Test func aCardThisBuildDoesNotKnowIsLeftOut() throws {
        #expect(try loaded(pinnedCards: ["when", "hologram", "cache"]).pinnedCards == [.when, .cache])
    }

    /// Any user can unpin all six, and that is not the same as never having chosen.
    @Test func noPinnedCardsStaysNone() throws {
        #expect(try loaded(pinnedCards: [String]()).pinnedCards.isEmpty)
    }

    @Test func aCardListedTwiceShowsOnce() throws {
        #expect(try loaded(pinnedCards: ["cache", "output", "cache"]).pinnedCards == [.cache, .output])
    }

    @Test func pinnedCardsOfAnotherShapeAreTheDefault() throws {
        #expect(try loaded(pinnedCards: "cache").pinnedCards == PinnedCard.allCases)
        #expect(try loaded(pinnedCards: [1, 2]).pinnedCards == PinnedCard.allCases)
    }

    @Test func nobodyHasBeenAskedAtFirst() {
        #expect(!Preferences.defaults(home: home).askedAboutSources)
    }

    @Test func settingsSavedBeforeTheFieldExistedStillLoad() throws {
        // What an earlier version wrote: everything but the new key, and the choices in it must survive.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences.defaults(home: home))) as? [String: Any])
        object["askedAboutSources"] = nil
        object["askedAboutAnthropicQuery"] = true
        let loaded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!loaded.askedAboutSources)
        #expect(loaded.askedAboutAnthropicQuery)
    }

    @Test func aValueThatCannotBeReadTakesTheDefaultAlone() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences.defaults(home: home))) as? [String: Any])
        object["askedAboutSources"] = "yes"
        object["askedAboutAnthropicQuery"] = true
        let loaded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!loaded.askedAboutSources)
        #expect(loaded.askedAboutAnthropicQuery)
    }

    @Test func theAnswerSurvivesARoundTrip() throws {
        var preferences = Preferences.defaults(home: home)
        preferences.askedAboutSources = true
        let loaded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        #expect(loaded.askedAboutSources)
    }
}
