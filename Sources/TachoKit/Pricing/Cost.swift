import Foundation

/// Events summed by everything that changes their price.
public struct PricingGroup: Equatable, Sendable {
    public var model: String?
    /// Claude `usage.speed`: "standard" or "fast".
    public var speed: String?
    /// Claude `usage.inference_geo`: "global", "us", …
    public var geo: String?
    /// Where the requests' prompts (`input + cacheRead + cache writes`) fall against `PriceTable.longContextThresholds`:
    /// 0 when at most `thresholds[0]`, `b` when more than `thresholds[b - 1]`. Counted against the thresholds of the table that prices the group.
    public var promptBand: Int
    public var tokens: TokenCounts

    public init(model: String? = nil, speed: String? = nil, geo: String? = nil, promptBand: Int, tokens: TokenCounts) {
        self.model = model
        self.speed = speed
        self.geo = geo
        self.promptBand = promptBand
        self.tokens = tokens
    }
}

/// A cost figure: what the priced tokens would cost, and what it leaves out.
public struct CostSummary: Equatable, Sendable {
    /// USD of the tokens that have a price.
    public var usd: Double
    /// The models that used tokens and have no price, sorted, each once. `usd` leaves them out.
    public var unpricedModels: [String]
    /// The tokens `usd` leaves out: those of the unpriced models and those of requests that name no model.
    public var unpricedTokens: Int

    public init(usd: Double, unpricedModels: [String], unpricedTokens: Int) {
        self.usd = usd
        self.unpricedModels = unpricedModels
        self.unpricedTokens = unpricedTokens
    }

    public static let zero = CostSummary(usd: 0, unpricedModels: [], unpricedTokens: 0)
}

extension PriceTable {
    /// USD for the group: each kind of token times the rate of the card that applies, over a million, times the geo multiplier.
    /// The card is the fast one for fast mode, else the long-context one when the group's prompts are over that card's threshold,
    /// else the standard one. nil when the model has no price.
    public func usd(_ group: PricingGroup) -> Double? {
        guard let entry = entry(for: group.model) else { return nil }
        return usd(of: group.tokens, at: entry, speed: group.speed, geo: group.geo, band: group.promptBand)
    }

    /// The cost of the groups, and the models and tokens it leaves out for want of a price.
    public func cost(of groups: [PricingGroup]) -> CostSummary {
        // However the same requests were grouped (one by one, by quarter hour, by day), the dollars come out the same to the last digit.
        var total = 0.0
        var unpricedTokens = 0
        var unpricedModels: [String] = []
        var currentModel: String?  // the keys come model by model, so each model is looked up once
        var currentEntry: PriceEntry?
        for (key, tokens) in merged(groups) {
            if key.model != currentModel {
                currentModel = key.model
                currentEntry = entry(for: key.model)
            }
            if let currentEntry {
                total += usd(of: tokens, at: currentEntry, speed: key.speed, geo: key.geo, band: key.band)
            } else {
                unpricedTokens += tokens.total
                if !key.model.isEmpty, unpricedModels.last != key.model { unpricedModels.append(key.model) }
            }
        }
        return CostSummary(usd: total, unpricedModels: unpricedModels, unpricedTokens: unpricedTokens)
    }

    /// `cost(of:).usd` by the chart's four layers. Unpriced models are in none of them, and `unpricedTokens` says how much that leaves out.
    public func usdByCategory(of groups: [PricingGroup]) -> CategoryCost {
        var total = CategoryCost.zero
        var currentModel: String?
        var currentEntry: PriceEntry?
        for (key, tokens) in merged(groups) {
            if key.model != currentModel {
                currentModel = key.model
                currentEntry = entry(for: key.model)
            }
            guard let currentEntry else {
                total.unpricedTokens += tokens.total
                continue
            }
            let card = card(of: currentEntry, speed: key.speed, band: key.band)
            let scale = multiplier(of: currentEntry, geo: key.geo) / 1_000_000
            total.input += Double(tokens.input) * card.input * scale
            total.output += Double(tokens.output) * card.output * scale
            total.cacheRead += Double(tokens.cacheRead) * card.cacheRead * scale
            total.cacheWrite += (Double(tokens.cacheWrite5m) * card.cacheWrite5m + Double(tokens.cacheWrite1h) * card.cacheWrite1h) * scale
        }
        return total
    }

    /// What the cache reads of `groups` kept off the bill: those reads at the input rate, less what they cost, on each model's card.
    /// A what-if. `usd` covers the priced models, `unpricedTokens` is the cache reads of the others, and `unpricedModels` names those
    /// that have any. With no model priced and no cache read, that would read as a saving of $0 for nothing priced, which direction B
    /// 12.4 forbids: then every token is left out, as in `cost(of:)`.
    public func cacheSaving(of groups: [PricingGroup]) -> CostSummary {
        var saved = 0.0
        var isPriced = false
        var unpricedTokens = 0
        var unpricedModels: [String] = []
        var currentModel: String?
        var currentEntry: PriceEntry?
        let byPrice = merged(groups)
        for (key, tokens) in byPrice {
            if key.model != currentModel {
                currentModel = key.model
                currentEntry = entry(for: key.model)
            }
            if let currentEntry {
                isPriced = true
                let card = card(of: currentEntry, speed: key.speed, band: key.band)
                saved += Double(tokens.cacheRead) * (card.input - card.cacheRead) / 1_000_000 * multiplier(of: currentEntry, geo: key.geo)
            } else if tokens.cacheRead > 0 {
                unpricedTokens += tokens.cacheRead
                if !key.model.isEmpty, unpricedModels.last != key.model { unpricedModels.append(key.model) }
            }
        }
        if !isPriced, unpricedTokens == 0, !byPrice.isEmpty {
            return cost(of: groups)
        }
        return CostSummary(usd: saved, unpricedModels: unpricedModels, unpricedTokens: unpricedTokens)
    }

    /// The tokens of each price, in a fixed order. They are whole numbers, so adding them first is exact, and each price is then
    /// used once.
    private func merged(_ groups: [PricingGroup]) -> [(key: PriceKey, value: TokenCounts)] {
        var merged: [PriceKey: TokenCounts] = [:]
        for group in groups where group.tokens.total > 0 {
            merged[PriceKey(group), default: .zero] += group.tokens
        }
        return merged.sorted { $0.key < $1.key }
    }

    private func multiplier(of entry: PriceEntry, geo: String?) -> Double {
        geo.flatMap { geoMultipliers[entry.provider]?[$0] } ?? 1
    }

    private func usd(of tokens: TokenCounts, at entry: PriceEntry, speed: String?, geo: String?, band: Int) -> Double {
        let card = card(of: entry, speed: speed, band: band)
        var perMillion = Double(tokens.input) * card.input
        perMillion += Double(tokens.output) * card.output
        perMillion += Double(tokens.cacheRead) * card.cacheRead
        perMillion += Double(tokens.cacheWrite5m) * card.cacheWrite5m
        perMillion += Double(tokens.cacheWrite1h) * card.cacheWrite1h
        return perMillion / 1_000_000 * multiplier(of: entry, geo: geo)
    }

    private func card(of entry: PriceEntry, speed: String?, band: Int) -> Price {
        if speed == "fast", let fast = entry.fast { return fast }
        // Band b is past thresholds[b - 1], so it is past the row's threshold when b is more than that threshold's index.
        if let long = entry.longContext, let index = longContextThresholds.firstIndex(of: long.abovePromptTokens), band > index {
            return long.price
        }
        return entry.price
    }
}

/// What `cost(of:)` merges groups by. No model, speed or geo prices like an empty one, so they are the same key.
private struct PriceKey: Hashable, Comparable {
    var model: String
    var speed: String
    var geo: String
    var band: Int

    init(_ group: PricingGroup) {
        model = group.model ?? ""
        speed = group.speed ?? ""
        geo = group.geo ?? ""
        band = group.promptBand
    }

    static func < (l: PriceKey, r: PriceKey) -> Bool {
        (l.model, l.speed, l.geo, l.band) < (r.model, r.speed, r.geo, r.band)
    }
}
