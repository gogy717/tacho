import Foundation

public enum RateUnit: String, Codable, Sendable { case perMinute, perSecond }
public enum MenuBarStyle: String, Codable, Sendable { case rate, iconOnly, fiveHourPercent }
public enum AppLanguage: String, Codable, Sendable { case system, en, zhHans }
/// What the rate shows: output tokens, every token, or the API-equivalent cost.
public enum RateMode: String, Codable, Sendable { case output, allTokens, cost }
/// A card that can be pinned, in its default order. Direction B, section 7.
public enum PinnedCard: String, Codable, CaseIterable, Sendable { case output, cache, speed, clis, tokens, when }

public struct Preferences: Codable, Equatable, Sendable {
    public var rateUnit: RateUnit
    public var menuBarStyle: MenuBarStyle
    public var enabledSources: Set<Source>
    public var quotaSources: Set<Source>
    public var roots: SourceRoots
    public var anthropicQueryEnabled: Bool
    public var askedAboutAnthropicQuery: Bool
    public var priceOverrides: [String: PriceEntry]
    public var language: AppLanguage
    /// The first-launch chooser was answered. Until it is, the app reads nothing.
    public var askedAboutSources: Bool
    public var rateMode: RateMode
    /// In the order they show. The panel shows the first four.
    public var pinnedCards: [PinnedCard]

    public init(
        rateUnit: RateUnit,
        menuBarStyle: MenuBarStyle,
        enabledSources: Set<Source>,
        quotaSources: Set<Source>,
        roots: SourceRoots,
        anthropicQueryEnabled: Bool,
        askedAboutAnthropicQuery: Bool,
        priceOverrides: [String: PriceEntry],
        language: AppLanguage,
        askedAboutSources: Bool = false,
        rateMode: RateMode = .output,
        pinnedCards: [PinnedCard] = PinnedCard.allCases
    ) {
        self.rateUnit = rateUnit
        self.menuBarStyle = menuBarStyle
        self.enabledSources = enabledSources
        self.quotaSources = quotaSources
        self.roots = roots
        self.anthropicQueryEnabled = anthropicQueryEnabled
        self.askedAboutAnthropicQuery = askedAboutAnthropicQuery
        self.priceOverrides = priceOverrides
        self.language = language
        self.askedAboutSources = askedAboutSources
        self.rateMode = rateMode
        self.pinnedCards = pinnedCards
    }

    /// Settings saved by another version must survive it: a key that is missing, or holds what this build cannot read, takes its
    /// default on its own. Failing here would throw every other setting away with it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences.defaults(home: FileManager.default.homeDirectoryForCurrentUser)
        func value<Value: Decodable>(_ key: CodingKeys, _ fallback: Value) -> Value {
            (try? container.decodeIfPresent(Value.self, forKey: key)) ?? fallback
        }
        // One by one: a card this build does not know must not throw away the ones it does, or their order.
        var cards: [PinnedCard] = []
        for card in value(.pinnedCards, defaults.pinnedCards.map(\.rawValue)).compactMap(PinnedCard.init(rawValue:)) where !cards.contains(card) {
            cards.append(card)
        }
        self.init(
            rateUnit: value(.rateUnit, defaults.rateUnit),
            menuBarStyle: value(.menuBarStyle, defaults.menuBarStyle),
            enabledSources: value(.enabledSources, defaults.enabledSources),
            quotaSources: value(.quotaSources, defaults.quotaSources),
            roots: value(.roots, defaults.roots),
            anthropicQueryEnabled: value(.anthropicQueryEnabled, defaults.anthropicQueryEnabled),
            askedAboutAnthropicQuery: value(.askedAboutAnthropicQuery, defaults.askedAboutAnthropicQuery),
            priceOverrides: value(.priceOverrides, defaults.priceOverrides),
            language: value(.language, defaults.language),
            askedAboutSources: value(.askedAboutSources, defaults.askedAboutSources),
            rateMode: value(.rateMode, defaults.rateMode),
            pinnedCards: cards
        )
    }

    public static func defaults(home: URL) -> Preferences {
        Preferences(
            rateUnit: .perMinute,
            menuBarStyle: .rate,
            enabledSources: Set(Source.allCases),
            quotaSources: Set(Source.allCases),
            roots: .defaults(home: home),
            anthropicQueryEnabled: false,
            askedAboutAnthropicQuery: false,
            priceOverrides: [:],
            language: .system
        )
    }
}
