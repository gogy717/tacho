import Foundation

/// US dollars per million tokens. `output` already includes reasoning.
public struct Price: Codable, Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite5m: Double, cacheWrite1h: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }
}

/// A second card for requests with a long prompt.
public struct LongContextPrice: Codable, Equatable, Sendable {
    /// The card applies to a request whose prompt (`input + cacheRead + cache writes`) is more than this many tokens.
    /// A provider that bills "200k and above" at the higher rate is written as 199999.
    public var abovePromptTokens: Int
    public var price: Price

    public init(abovePromptTokens: Int, price: Price) {
        self.abovePromptTokens = abovePromptTokens
        self.price = price
    }
}

/// One row of the price table: what a model, and its dated snapshots, cost.
public struct PriceEntry: Codable, Equatable, Sendable {
    /// The model id, lowercase. The row also prices that model's snapshots ("claude-opus-5-5-20261001").
    public var id: String
    /// The provider's id as `UsageEvent.provider` spells it: "anthropic", "openai", "xai". Picks the geo multipliers.
    public var provider: String
    public var price: Price
    /// Fast mode (Claude `usage.speed == "fast"`), when the provider prices it.
    public var fast: Price?
    public var longContext: LongContextPrice?
    /// The page the price was read from, or in words where it came from when no page prices it. nil for a row the user set.
    public var source: String?
    /// The day of `source`, "yyyy-MM-dd". nil for a row the user set.
    public var asOf: String?

    public init(
        id: String, provider: String, price: Price, fast: Price? = nil, longContext: LongContextPrice? = nil,
        source: String? = nil, asOf: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.price = price
        self.fast = fast
        self.longContext = longContext
        self.source = source
        self.asOf = asOf
    }
}

/// What tokens would cost on the API: a price per model, in US dollars per million tokens.
///
/// The person is on a subscription, so every figure made from this is an estimate of the same tokens at API list prices.
/// A model without a row costs nothing and is said to have no price; no price is ever guessed.
public struct PriceTable: Equatable, Sendable {
    /// The rows, sorted by provider, then id.
    public let entries: [PriceEntry]
    /// The distinct `longContext.abovePromptTokens` of the rows, ascending: the edges of `PricingGroup.promptBand`.
    public let longContextThresholds: [Int]
    /// `geoMultipliers[provider][geo]`: the factor on every rate of a request that ran in that region.
    let geoMultipliers: [String: [String: Double]]

    /// The table shipped in the app (`prices.json`).
    public static func bundled() throws -> PriceTable {
        guard let url = TachoKitResources.bundle.url(forResource: "prices", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "prices.json"])
        }
        return try PriceTable(json: Data(contentsOf: url))
    }

    /// Reads `{"geoMultipliers": {"<provider>": {"<geo>": 1.1}}, "models": [PriceEntry…]}`. `geoMultipliers` may be left out.
    /// Throws when a card is incomplete or two rows name the same model.
    public init(json: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: json)
        var rows: [String: PriceEntry] = [:]
        for var entry in file.models {
            entry.id = Self.normalizedId(entry.id)
            guard rows.updateValue(entry, forKey: entry.id) == nil else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "The price table names the model \"\(entry.id)\" twice.")
                )
            }
        }
        self.init(unique: rows, geoMultipliers: file.geoMultipliers ?? [:])
    }

    private struct File: Decodable {
        var geoMultipliers: [String: [String: Double]]?
        var models: [PriceEntry]
    }

    private init(unique rows: [String: PriceEntry], geoMultipliers: [String: [String: Double]]) {
        entries = rows.values.sorted { ($0.provider, $0.id) < ($1.provider, $1.id) }
        longContextThresholds = Set(rows.values.compactMap { $0.longContext?.abovePromptTokens }).sorted()
        self.geoMultipliers = geoMultipliers
    }

    /// This table with the person's own rows over it: keyed by model id, each replaces the row of that id (whole)
    /// or adds one.
    public func applying(overrides: [String: PriceEntry]) -> PriceTable {
        guard !overrides.isEmpty else { return self }
        var rows = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for (id, entry) in overrides.sorted(by: { $0.key < $1.key }) {
            var row = entry
            row.id = Self.normalizedId(id)
            rows[row.id] = row
        }
        return PriceTable(unique: rows, geoMultipliers: geoMultipliers)
    }

    /// Models are looked up by `bareModelId`, so ids are kept the same way.
    private static func normalizedId(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Matching

    /// The row that prices `model`: the longest id that names it. nil when none does.
    public func entry(for model: String?) -> PriceEntry? {
        guard let model else { return nil }
        let bare = Self.bareModelId(model).utf8
        var best: PriceEntry?
        var bestLength = 0
        for entry in entries {
            let length = entry.id.utf8.count
            guard length > bestLength, bare.starts(with: entry.id.utf8), Self.namesSameModel(bare.dropFirst(length)) else { continue }
            best = entry
            bestLength = length
        }
        return best
    }

    /// A model id without what clouds and tools add to it: lowercase and trimmed, without a provider path
    /// ("anthropic/…"), Bedrock's vendor with its region ("us.anthropic.…") and a context-size tag ("…[1m]").
    public static func bareModelId(_ model: String) -> String {
        var id = Substring(model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if let slash = id.lastIndex(of: "/") { id = id[id.index(after: slash)...] }
        return String(withoutContextTag(withoutVendor(id)))
    }

    /// `^([a-z]{2,6}\.)?anthropic\.`
    private static func withoutVendor(_ id: Substring) -> Substring {
        let vendor = "anthropic."
        if id.hasPrefix(vendor) { return id.dropFirst(vendor.count) }
        guard let dot = id.firstIndex(of: "."), (2...6).contains(id.distance(from: id.startIndex, to: dot)),
              id[..<dot].allSatisfy({ $0.isASCII && $0.isLowercase })
        else { return id }
        let rest = id[id.index(after: dot)...]
        return rest.hasPrefix(vendor) ? rest.dropFirst(vendor.count) : id
    }

    /// `\[[^\]]*\]$`
    private static func withoutContextTag(_ id: Substring) -> Substring {
        guard id.last == "]" else { return id }
        let body = id.dropLast()
        let from = body.lastIndex(of: "]").map { body.index(after: $0) } ?? body.startIndex
        guard let open = body[from...].firstIndex(of: "[") else { return id }
        return id[..<open]
    }

    /// What may follow an entry's id in a model id that is still that model: nothing, a snapshot's date ("-20261001",
    /// or OpenAI's "-2026-10-01"), "-latest", Vertex's "@date", Bedrock's "-v1:0", or a ":" tag. Anything else is another model
    /// ("claude-opus-5" is not "claude-opus-5-5"). `^(-\d{8}|-\d{4}-\d{2}-\d{2}|-latest|@|-v\d|:)`
    private static func namesSameModel(_ rest: Substring.UTF8View) -> Bool {
        guard let first = rest.first else { return true }
        switch first {
        case UInt8(ascii: "@"), UInt8(ascii: ":"):
            return true
        case UInt8(ascii: "-"):
            let tail = rest.dropFirst()
            if tail.starts(with: "latest".utf8) { return true }
            if tail.first == UInt8(ascii: "v") { return tail.dropFirst().first.map(isDigit) ?? false }
            return begins(tail, with: "dddddddd") || begins(tail, with: "dddd-dd-dd")
        default:
            return false
        }
    }

    /// Whether `bytes` begin with `shape`, in which "d" stands for a digit and any other character for itself.
    private static func begins(_ bytes: Substring.UTF8View, with shape: String) -> Bool {
        var iterator = bytes.makeIterator()
        for expected in shape.utf8 {
            guard let byte = iterator.next() else { return false }
            if expected == UInt8(ascii: "d") ? !isDigit(byte) : byte != expected { return false }
        }
        return true
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}
