import Foundation
import TachoKit

/// The pinned cards, worded. Which rule fires is the insights' answer, and until it is in a card makes no comparison.
extension PanelState.Tile {
    /// - Parameter limit: the panel has room for four. The main window passes nil, for every one.
    static func pinned(_ cards: [PinnedCard], dashboard: Dashboard, insights: PanelInsights?, limit: Int? = 4) -> [PanelState.Tile] {
        let tokens = dashboard.today.tokens
        return cards.prefix(limit ?? cards.count).map { card in
            switch card {
            case .output: output(tokens, insights?.results.output)
            case .cache: cache(tokens, insights)
            case .speed: speed(dashboard.today.speeds, insights?.results.speed)
            case .clis: clis(inUse: dashboard.sources.filter { $0.today.total > 0 }.count, insights)
            case .tokens: allTokens(tokens, insights?.results.cacheReadPercent)
            case .when: when(insights?.results.when)
            }
        }
    }

    /// Says `No data yet`, with no mini view and no say.
    private static func noData(_ id: String, _ title: String, _ route: Route) -> PanelState.Tile {
        PanelState.Tile(id: id, title: title, value: String(localized: "card.noData", bundle: .tacho), say: nil, mark: .none, route: route)
    }

    /// A scale where there is a range to draw it on.
    private static func needle(_ value: Double, _ range: UsualRange?) -> Mark {
        range.map { .needle(value: value, p25: $0.p25, p75: $0.p75) } ?? .none
    }

    private static func output(_ tokens: TokenCounts, _ insight: OutputInsight?) -> PanelState.Tile {
        let title = String(localized: "card.outputToday", bundle: .tacho)
        let route = Route(page: .tokens, metric: .output, range: .day)
        guard tokens.output > 0 else { return noData("output", title, route) }
        return PanelState.Tile(
            id: "output",
            title: title,
            value: TokenFormat.compact(tokens.output),
            say: insight.map { Labels.say($0.rule) },
            mark: insight.map { needle($0.value, $0.range) } ?? .none,
            route: route
        )
    }

    private static func cache(_ tokens: TokenCounts, _ insights: PanelInsights?) -> PanelState.Tile {
        let title = String(localized: "card.cache", bundle: .tacho)
        let route = Route(page: .cache, range: .day)
        guard let rate = tokens.cacheHitRate else { return noData("cache", title, route) }
        let hit = String(format: "%.1f%%", rate * 100)
        let days = insights?.cache.dailyHitRates ?? []
        return PanelState.Tile(
            id: "cache",
            title: title,
            value: String(format: String(localized: "card.cache.value", bundle: .tacho), hit),
            say: insights?.results.cache.map { Labels.say($0) },
            mark: days.count >= 2 ? .spark(days) : .none,
            route: route
        )
    }

    /// With an answer, the model it chose: the most samples in 24 hours, which may not be today's busiest.
    private static func speed(_ speeds: [ModelSpeed], _ insight: SpeedInsight?) -> PanelState.Tile {
        let title = String(localized: "card.speed", bundle: .tacho)
        if let insight {
            return PanelState.Tile(
                id: "speed",
                title: title,
                // With no row to say how it was timed, it does not claim to be exact.
                value: speeds.first { $0.model == insight.model }.map(Labels.speed) ?? Labels.tokensPerSecond(insight.value, approximate: true),
                say: Labels.say(insight.rule, model: insight.model),
                mark: needle(insight.value, insight.range),
                route: Route(page: .speed, model: insight.model)
            )
        }
        let route = Route(page: .speed)
        guard let top = speeds.max(by: { $0.samples < $1.samples }) else { return noData("speed", title, route) }
        return PanelState.Tile(id: "speed", title: title, value: Labels.speed(top), say: Labels.modelShort(top.model), mark: .none, route: route)
    }

    private static func clis(inUse: Int, _ insights: PanelInsights?) -> PanelState.Tile {
        let title = String(localized: "card.clis", bundle: .tacho)
        let route = Route(page: .cost, range: .day)
        guard inUse > 0 else { return noData("clis", title, route) }
        let shares = insights?.clis.shares.map(\.fraction) ?? []
        return PanelState.Tile(
            id: "clis",
            title: title,
            value: String(inUse),
            say: insights?.results.clis.map(WindowLabels.share),
            mark: shares.isEmpty ? .none : .shares(shares),
            route: route
        )
    }

    private static func allTokens(_ tokens: TokenCounts, _ cacheReadPercent: Int?) -> PanelState.Tile {
        let title = String(localized: "card.tokens", bundle: .tacho)
        let route = Route(page: .tokens, metric: .allTokens, range: .day)
        guard tokens.total > 0 else { return noData("tokens", title, route) }
        return PanelState.Tile(
            id: "tokens",
            title: title,
            value: TokenFormat.compact(tokens.total),
            say: cacheReadPercent.map(Labels.cacheReads),
            mark: .layers(Theme.stackOrder.map { Double($0.tokens(in: tokens)) / Double(tokens.total) }),
            route: route
        )
    }

    /// The hour grid does not fit in the panel, so this card is its sentence alone.
    private static func when(_ rule: WhenRule?) -> PanelState.Tile {
        let title = String(localized: "card.when", bundle: .tacho)
        let route = Route(page: .calendar)
        guard let rule else { return noData("when", title, route) }
        return PanelState.Tile(id: "when", title: title, value: nil, say: Labels.say(rule), mark: .none, route: route)
    }
}
