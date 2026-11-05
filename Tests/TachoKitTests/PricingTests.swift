import Foundation
import Testing
import TachoKit

struct PricingTests {
    /// A local table, not the bundled one, so the math tests survive price updates.
    let table: PriceTable
    let big = TokenCounts(input: 1_000_000, output: 100_000, cacheRead: 2_000_000, cacheWrite5m: 100_000, cacheWrite1h: 50_000)

    init() throws {
        table = try PriceTable(json: Data(#"""
        {"geoMultipliers":{"anthropic":{"us":1.1}},"models":[
         {"id":"claude-opus-5-5","provider":"anthropic","price":{"input":4,"output":20,"cacheRead":0.2,"cacheWrite5m":5,"cacheWrite1h":8},
          "fast":{"input":8,"output":40,"cacheRead":0.4,"cacheWrite5m":10,"cacheWrite1h":16}},
         {"id":"claude-opus-5","provider":"anthropic","price":{"input":5,"output":25,"cacheRead":0.5,"cacheWrite5m":6.25,"cacheWrite1h":10}},
         {"id":"claude-haiku-5-5","provider":"anthropic","price":{"input":0.1,"output":0.5,"cacheRead":0.01,"cacheWrite5m":0.125,"cacheWrite1h":0.2},
          "longContext":{"abovePromptTokens":100000,"price":{"input":0.5,"output":2.5,"cacheRead":0.05,"cacheWrite5m":0.625,"cacheWrite1h":1}}}]}
        """#.utf8))
    }

    private func group(_ model: String?, _ tokens: TokenCounts, speed: String? = "standard", geo: String? = "global", band: Int = 0) -> PricingGroup {
        PricingGroup(model: model, speed: speed, geo: geo, promptBand: band, tokens: tokens)
    }

    private func flat(_ rate: Double) -> Price {
        Price(input: rate, output: rate, cacheRead: rate, cacheWrite5m: rate, cacheWrite1h: rate)
    }

    // MARK: Matching

    @Test func matchesLongestSameModelId() {
        for model in ["claude-opus-5-5", "claude-opus-5-5-20261001", "claude-opus-5-5[1m]", "us.anthropic.claude-opus-5-5-v1:0"] {
            #expect(table.entry(for: model)?.id == "claude-opus-5-5", "\(model)")
        }
        #expect(table.entry(for: "anthropic/claude-opus-5")?.id == "claude-opus-5")
        let other: [String?] = ["claude-opus-5-6", "gemma4:12b", "opus", nil]
        for model in other {
            #expect(table.entry(for: model) == nil, "\(model ?? "nil")")
        }
    }

    /// After a row's id only a snapshot date (in either spelling), "-latest", Vertex's "@date", Bedrock's "-v1:0" or a ":" tag still names that model.
    @Test func onlyDatesLatestVertexBedrockAndTagSuffixesNameTheSameModel() {
        for suffix in ["-20261001", "-2026-10-01", "-latest", "@20261001", "-v1", "-v2:0", ":thinking"] {
            #expect(table.entry(for: "claude-opus-5-5" + suffix)?.id == "claude-opus-5-5", "\(suffix)")
        }
        for suffix in ["-5", "-preview", "-1234567", "-v", "x", "-2026-10", "-2026-1-01", "-2026-10-1", "-26-10-01", "-2026/10/01", "."] {
            #expect(table.entry(for: "claude-opus-5-5" + suffix) == nil, "\(suffix)")
        }
    }

    /// OpenAI spells a snapshot's date with dashes: "gpt-6.1-sol-2026-09-10".
    @Test func datedOpenAISnapshotNamesItsBaseModel() throws {
        let local = table.applying(overrides: ["gpt-6.1-sol": PriceEntry(id: "gpt-6.1-sol", provider: "openai", price: flat(2))])
        #expect(local.entry(for: "gpt-6.1-sol-2026-09-10")?.id == "gpt-6.1-sol")
        #expect(try PriceTable.bundled().entry(for: "gpt-6.1-sol-2026-09-10")?.id == "gpt-6.1-sol")
    }

    @Test func bareModelIdStripsPathVendorRegionAndContextTag() {
        let cases: [(model: String, bare: String)] = [
            ("  Claude-Opus-5-5  ", "claude-opus-5-5"),
            ("anthropic/claude-opus-5", "claude-opus-5"),
            ("openrouter/anthropic/claude-opus-5-5", "claude-opus-5-5"),
            ("claude-opus-5-5[1m]", "claude-opus-5-5"),
            ("anthropic.claude-opus-5-5-v1:0", "claude-opus-5-5-v1:0"),
            ("us.anthropic.claude-opus-5-5-v1:0", "claude-opus-5-5-v1:0"),
            ("global.anthropic.claude-opus-5-5", "claude-opus-5-5"),
            ("claude-opus-4-1@20250805", "claude-opus-4-1@20250805"),
            ("gpt-5.6-sol", "gpt-5.6-sol"),
            ("gemma4:12b", "gemma4:12b"),
            ("us.claude-opus-5-5", "us.claude-opus-5-5"),                     // a region without the vendor stays
            ("toolongregion.anthropic.claude", "toolongregion.anthropic.claude"), // seven letters or more is no region
            ("x[a]y", "x[a]y"),                                                // a tag only counts at the end
            ("x[a]y[b]", "x[a]y"),
            ("x[1m", "x[1m"),
        ]
        for c in cases {
            #expect(PriceTable.bareModelId(c.model) == c.bare, "\(c.model)")
        }
    }

    // MARK: Dollars

    @Test func costOfStandardRequest() throws {
        let usd = try #require(table.usd(PricingGroup(model: "claude-opus-5-5", speed: "standard", geo: "global", promptBand: 0, tokens: big)))
        #expect(abs(usd - 7.3) < 1e-9)
    }

    @Test func fastModeUsesTheFastCard() throws {
        let usd = try #require(table.usd(PricingGroup(model: "claude-opus-5-5", speed: "fast", geo: "global", promptBand: 0, tokens: big)))
        #expect(abs(usd - 14.6) < 1e-9)
    }

    @Test func fastWithoutAFastCardUsesTheStandardCard() throws {
        let fast = try #require(table.usd(group("claude-opus-5", big, speed: "fast")))
        let standard = try #require(table.usd(group("claude-opus-5", big, speed: "standard")))
        #expect(fast == standard)
        #expect(abs(standard - 9.625) < 1e-9) // 5 + 2.5 + 1 + 0.625 + 0.5
    }

    @Test func usGeoMultipliesAnthropic() throws {
        let usd = try #require(table.usd(PricingGroup(model: "claude-opus-5-5", speed: "standard", geo: "us", promptBand: 0, tokens: big)))
        #expect(abs(usd - 8.03) < 1e-9)
        // it stacks on the fast card and on a long-context card
        let fast = try #require(table.usd(group("claude-opus-5-5", big, speed: "fast", geo: "us")))
        #expect(abs(fast - 16.06) < 1e-9)
        let haiku = try #require(table.usd(group("claude-haiku-5-5", TokenCounts(input: 1_000_000), geo: "us", band: 1)))
        #expect(abs(haiku - 0.55) < 1e-9)
    }

    @Test func geoMultiplierNeedsItsProviderAndItsGeo() throws {
        let local = table.applying(overrides: ["local-model": PriceEntry(id: "local-model", provider: "local", price: flat(1))])
        for geo: String? in ["global", "not_available", "eu", "", nil] {
            let usd = try #require(local.usd(group("claude-opus-5-5", big, geo: geo)))
            #expect(abs(usd - 7.3) < 1e-9, "\(geo ?? "nil")")
        }
        let usd = try #require(local.usd(group("local-model", TokenCounts(input: 1_000_000), geo: "us")))
        #expect(abs(usd - 1) < 1e-9)
    }

    @Test func noSpeedAndNoGeoPriceAtTheStandardCard() throws {
        let usd = try #require(table.usd(PricingGroup(model: "claude-opus-5-5", promptBand: 0, tokens: big)))
        #expect(abs(usd - 7.3) < 1e-9)
    }

    @Test func reasoningIsNeverPricedOnTopOfOutput() throws {
        let usd = try #require(table.usd(group("claude-opus-5-5", TokenCounts(output: 1_000_000, reasoning: 900_000))))
        #expect(abs(usd - 20) < 1e-9)
    }

    @Test func aModelWithoutAPriceHasNoDollars() {
        #expect(table.usd(group("gemma4:12b", big)) == nil)
        #expect(table.usd(group(nil, big)) == nil)
    }

    // MARK: Long context

    @Test func longContextCardAboveThreshold() throws {
        #expect(table.longContextThresholds == [100_000])
        let million = TokenCounts(input: 1_000_000)
        let above = try #require(table.usd(PricingGroup(model: "claude-haiku-5-5", speed: "standard", geo: "global", promptBand: 1, tokens: million)))
        let below = try #require(table.usd(PricingGroup(model: "claude-haiku-5-5", speed: "standard", geo: "global", promptBand: 0, tokens: million)))
        #expect(abs(above - 0.5) < 1e-9)
        #expect(abs(below - 0.1) < 1e-9)
    }

    /// Bands count every threshold in the table; a row's own card applies once the band is past that row's threshold.
    @Test func eachRowsLongContextCardStartsAtItsOwnThreshold() throws {
        let local = table.applying(overrides: [
            "tier-two": PriceEntry(id: "tier-two", provider: "anthropic", price: flat(1), longContext: LongContextPrice(abovePromptTokens: 200_000, price: flat(3))),
            "tier-one": PriceEntry(id: "tier-one", provider: "anthropic", price: flat(2), longContext: LongContextPrice(abovePromptTokens: 100_000, price: flat(4))),
        ])
        #expect(local.longContextThresholds == [100_000, 200_000])
        let million = TokenCounts(input: 1_000_000)
        let expected: [(model: String, band: Int, usd: Double)] = [
            ("claude-haiku-5-5", 0, 0.1), ("claude-haiku-5-5", 1, 0.5), ("claude-haiku-5-5", 2, 0.5),
            ("tier-one", 0, 2), ("tier-one", 1, 4), ("tier-one", 2, 4),
            ("tier-two", 0, 1), ("tier-two", 1, 1), ("tier-two", 2, 3),
            ("claude-opus-5", 0, 5), ("claude-opus-5", 1, 5), ("claude-opus-5", 2, 5),
        ]
        for e in expected {
            let usd = try #require(local.usd(group(e.model, million, band: e.band)))
            #expect(abs(usd - e.usd) < 1e-9, "\(e.model) band \(e.band)")
        }
    }

    @Test func fastModeWinsOverTheLongContextCard() throws {
        let local = table.applying(overrides: [
            "both": PriceEntry(id: "both", provider: "anthropic", price: flat(1), fast: flat(2), longContext: LongContextPrice(abovePromptTokens: 100_000, price: flat(3))),
        ])
        let million = TokenCounts(input: 1_000_000)
        #expect(abs(try #require(local.usd(group("both", million, speed: "fast", band: 1))) - 2) < 1e-9)
        #expect(abs(try #require(local.usd(group("both", million, speed: "standard", band: 1))) - 3) < 1e-9)
    }

    @Test func thresholdsAreDistinctAndAscendingWhateverTheRowOrder() throws {
        let p = #"{"input":1,"output":2,"cacheRead":0.1,"cacheWrite5m":1.25,"cacheWrite1h":2}"#
        let t = try PriceTable(json: Data(#"""
        {"models":[
         {"id":"grok-x","provider":"xai","price":\#(p),"longContext":{"abovePromptTokens":272000,"price":\#(p)}},
         {"id":"b-model","provider":"anthropic","price":\#(p),"longContext":{"abovePromptTokens":100000,"price":\#(p)}},
         {"id":"a-model","provider":"openai","price":\#(p),"longContext":{"abovePromptTokens":272000,"price":\#(p)}},
         {"id":"a-model-2","provider":"anthropic","price":\#(p)}]}
        """#.utf8))
        #expect(t.longContextThresholds == [100_000, 272_000])
        #expect(t.entries.map(\.id) == ["a-model-2", "b-model", "a-model", "grok-x"]) // by provider, then id
    }

    // MARK: Summing

    @Test func unpricedModelsAreListedNotCounted() {
        let cost = table.cost(of: [
            PricingGroup(model: "claude-opus-5-5", speed: "standard", geo: "global", promptBand: 0, tokens: TokenCounts(input: 1_000_000)),
            PricingGroup(model: "gemma4:12b", speed: nil, geo: nil, promptBand: 0, tokens: TokenCounts(input: 5_000)),
        ])
        #expect(abs(cost.usd - 4) < 1e-9)
        #expect(cost.unpricedModels == ["gemma4:12b"])
        #expect(cost.unpricedTokens == 5_000)
    }

    @Test func unpricedModelsAreSortedOnceEachAndEmptyGroupsAreSkipped() {
        let cost = table.cost(of: [
            group("zeta", TokenCounts(input: 1)),
            group("alpha", TokenCounts(output: 2), band: 0),
            group("alpha", TokenCounts(cacheRead: 3), band: 1),
            group("never-used", .zero),
            group(nil, TokenCounts(cacheWrite1h: 4)),
        ])
        #expect(cost.unpricedModels == ["alpha", "zeta"]) // no model, no name; no tokens, no mention
        #expect(cost.unpricedTokens == 1 + 2 + 3 + 4)
        #expect(cost.usd == 0)
    }

    @Test func noGroupsCostNothing() {
        #expect(table.cost(of: []) == .zero)
        #expect(CostSummary.zero == CostSummary(usd: 0, unpricedModels: [], unpricedTokens: 0))
    }

    /// Tokens are whole numbers, so the same requests give the same dollars to the last digit however they were grouped or ordered.
    @Test func costDoesNotDependOnHowTheGroupsAreCutOrOrdered() {
        var pieces: [PricingGroup] = []
        for i in 1...60 {
            let n = i * 7_919
            pieces.append(group("claude-haiku-5-5", TokenCounts(input: n, output: n / 3), band: i % 2))
            pieces.append(group("claude-opus-5-5", TokenCounts(input: n, cacheRead: 3 * n, cacheWrite1h: n / 7), speed: i % 3 == 0 ? "fast" : "standard", geo: i % 5 == 0 ? "us" : "global"))
            pieces.append(group("claude-opus-5", TokenCounts(output: n, cacheWrite5m: n / 11)))
        }
        // The same tokens cut coarser: one group for each price that applies.
        let whole = Dictionary(grouping: pieces) { [$0.model ?? "", $0.speed ?? "", $0.geo ?? "", "\($0.promptBand)"] }.values.map { cut in
            PricingGroup(model: cut[0].model, speed: cut[0].speed, geo: cut[0].geo, promptBand: cut[0].promptBand, tokens: cut.reduce(.zero) { $0 + $1.tokens })
        }
        #expect(whole.count == 7)

        let naive = pieces.compactMap { table.usd($0) }.reduce(0, +)
        let naiveReversed = pieces.reversed().compactMap { table.usd($0) }.reduce(0, +)
        let naiveWhole = whole.compactMap { table.usd($0) }.reduce(0, +)
        #expect(naive != naiveReversed && naive != naiveWhole) // plain sums of per-group dollars drift: this data can tell the ways of summing apart

        let exact = table.cost(of: pieces).usd
        #expect(table.cost(of: pieces.reversed()).usd == exact)
        #expect(table.cost(of: pieces.shuffled()).usd == exact)
        #expect(table.cost(of: whole).usd == exact)
        #expect(abs(exact - naive) < 1e-6)
    }

    // MARK: Editing and loading

    // MARK: By category

    @Test func eachLayerIsItsOwnTokensAtItsOwnRate() {
        let split = table.usdByCategory(of: [group("claude-opus-5-5", big)])

        #expect(abs(split.input - 4) < 1e-9)
        #expect(abs(split.output - 2) < 1e-9)
        #expect(abs(split.cacheRead - 0.4) < 1e-9)
        #expect(abs(split.cacheWrite - 0.9) < 1e-9) // 0.5 for the 5-minute writes, 0.4 for the 1-hour ones
    }

    /// Whatever the card and the multiplier, the layers are the same dollars as the total.
    @Test func theLayersAddUpToTheCost() {
        let groups = [
            group("claude-opus-5-5", big),
            group("claude-opus-5-5", big, speed: "fast"),
            group("claude-opus-5-5", big, geo: "us"),
            group("claude-haiku-5-5", big, band: 1),
            group("claude-opus-5", big, speed: "fast", geo: "us"),
            group("nothing-like-it", big),
            group(nil, big),
        ]

        #expect(abs(table.usdByCategory(of: groups).total - table.cost(of: groups).usd) < 1e-9)
    }

    @Test func theFastCardAndTheMultiplierReachEveryLayer() {
        let split = table.usdByCategory(of: [group("claude-opus-5-5", big, speed: "fast", geo: "us")])

        #expect(abs(split.input - 8.8) < 1e-9)
        #expect(abs(split.output - 4.4) < 1e-9)
        #expect(abs(split.cacheRead - 0.88) < 1e-9)
        #expect(abs(split.cacheWrite - 1.98) < 1e-9)
    }

    @Test func theLongContextCardReachesEveryLayer() {
        let tokens = TokenCounts(input: 1_000_000, output: 1_000_000)

        #expect(abs(table.usdByCategory(of: [group("claude-haiku-5-5", tokens, band: 1)]).input - 0.5) < 1e-9)
        #expect(abs(table.usdByCategory(of: [group("claude-haiku-5-5", tokens, band: 1)]).output - 2.5) < 1e-9)
        #expect(abs(table.usdByCategory(of: [group("claude-haiku-5-5", tokens, band: 0)]).input - 0.1) < 1e-9)
    }

    @Test func thinkingIsNotALayerOnTopOfOutput() {
        let tokens = TokenCounts(output: 1_000_000, reasoning: 600_000)

        #expect(abs(table.usdByCategory(of: [group("claude-opus-5-5", tokens)]).output - 20) < 1e-9)
    }

    @Test func anUnpricedModelIsInNoLayer() {
        #expect(table.usdByCategory(of: [group("nothing-like-it", big), group(nil, big)]).total == 0)
    }

    /// Dollars cannot say what they leave out, and a minute of the chart has nothing else to say it with.
    @Test func theTokensLeftOutOfTheLayersAreCounted() {
        let groups = [group("nothing-like-it", big), group(nil, big), group("claude-opus-5-5", big)]
        #expect(table.usdByCategory(of: groups).unpricedTokens == 2 * big.total)
        #expect(table.usdByCategory(of: groups).unpricedTokens == table.cost(of: groups).unpricedTokens)
    }

    @Test func nothingIsLeftOutWhenEverythingHasAPrice() {
        #expect(table.usdByCategory(of: [group("claude-opus-5-5", big)]).unpricedTokens == 0)
    }

    @Test func noGroupsHaveNoLayers() {
        #expect(table.usdByCategory(of: []) == .zero)
    }

    @Test func layersDoNotDependOnHowTheGroupsAreCut() {
        let half = TokenCounts(input: 500_000, output: 50_000, cacheRead: 1_000_000, cacheWrite5m: 50_000, cacheWrite1h: 25_000)

        let whole = table.usdByCategory(of: [group("claude-opus-5-5", big)])
        let cut = table.usdByCategory(of: [group("claude-opus-5-5", half), group("claude-opus-5-5", half)])

        #expect(whole == cut)
    }

    // MARK: Cache saving

    /// 2M cache reads at the input rate of 4, against the cache rate of 0.2.
    @Test func cacheSavingIsCacheReadsAtTheInputRateLessWhatTheyCost() {
        let saving = table.cacheSaving(of: [group("claude-opus-5-5", big)])

        #expect(abs(saving.usd - 7.6) < 1e-9)
        #expect(saving.unpricedModels.isEmpty)
        #expect(saving.unpricedTokens == 0)
    }

    @Test func cacheSavingUsesTheCardOfEachGroup() {
        let reads = TokenCounts(cacheRead: 1_000_000)

        #expect(abs(table.cacheSaving(of: [group("claude-opus-5-5", reads, speed: "fast")]).usd - 7.6) < 1e-9)
        #expect(abs(table.cacheSaving(of: [group("claude-opus-5-5", reads, geo: "us")]).usd - 4.18) < 1e-9)
        #expect(abs(table.cacheSaving(of: [group("claude-haiku-5-5", reads, band: 1)]).usd - 0.45) < 1e-9)
        #expect(abs(table.cacheSaving(of: [group("claude-haiku-5-5", reads, band: 0)]).usd - 0.09) < 1e-9)
    }

    /// Only cache reads count, so what is left out is counted in cache reads, and a model with none of them is not left out.
    @Test func cacheSavingNamesWhatItCannotPrice() {
        let saving = table.cacheSaving(of: [
            group("claude-opus-5-5", TokenCounts(cacheRead: 1_000_000)),
            group("nothing-like-it", TokenCounts(input: 900, cacheRead: 40)),
            group("no-reads-at-all", TokenCounts(input: 900)),
            group(nil, TokenCounts(cacheRead: 2)),
        ])

        #expect(abs(saving.usd - 3.8) < 1e-9)
        #expect(saving.unpricedModels == ["nothing-like-it"])
        #expect(saving.unpricedTokens == 42)
    }

    @Test func noCacheReadsSaveNothing() {
        #expect(table.cacheSaving(of: [group("claude-opus-5-5", TokenCounts(input: 1_000_000))]) == .zero)
        #expect(table.cacheSaving(of: []) == .zero)
    }

    /// Direction B 12.4: with nothing priced, Kept reads "no price" beside Writes, never $0.00, cache reads or not.
    @Test func nothingPricedSavesNoTellableAmount() {
        let saving = table.cacheSaving(of: [group("nothing-like-it", TokenCounts(input: 900)), group(nil, TokenCounts(output: 5))])

        #expect(saving == CostSummary(usd: 0, unpricedModels: ["nothing-like-it"], unpricedTokens: 905))
    }

    @Test func overridesReplaceAndAddRows() {
        let mine = Price(input: 1, output: 2, cacheRead: 0.1, cacheWrite5m: 1.25, cacheWrite1h: 2)
        let patched = table.applying(overrides: [
            "claude-opus-5-5": PriceEntry(id: "claude-opus-5-5", provider: "anthropic", price: mine),
            "my-model": PriceEntry(id: "my-model", provider: "local", price: mine),
        ])
        #expect(patched.entry(for: "claude-opus-5-5")?.price.input == 1)
        #expect(patched.entry(for: "my-model") != nil)
        #expect(patched.entry(for: "claude-opus-5-5")?.fast == nil) // a row is replaced whole
        #expect(patched.entry(for: "my-model")?.source == nil)
        #expect(patched.entry(for: "claude-opus-5")?.price.input == 5) // the rest is untouched
        #expect(table.entry(for: "claude-opus-5-5")?.price.input == 4) // and so is the table it came from
        #expect(table.entry(for: "my-model") == nil)
    }

    @Test func overridesReachDollarsAndThresholds() throws {
        let patched = table.applying(overrides: [
            "claude-haiku-5-5": PriceEntry(id: "claude-haiku-5-5", provider: "anthropic", price: flat(1)),
        ])
        #expect(patched.longContextThresholds == [])
        let usd = try #require(patched.usd(group("claude-haiku-5-5", TokenCounts(input: 1_000_000), band: 1)))
        #expect(abs(usd - 1) < 1e-9)
    }

    @Test func overrideIdsMatchWhateverTheirCase() throws {
        let patched = table.applying(overrides: ["Claude-Opus-5-5": PriceEntry(id: "Claude-Opus-5-5", provider: "anthropic", price: flat(1))])
        #expect(patched.entries.filter { $0.id == "claude-opus-5-5" }.count == 1)
        #expect(patched.entry(for: "claude-opus-5-5-20261001")?.price.input == 1)
    }

    @Test func aTableNamingAModelTwiceIsRejected() {
        let p = #"{"input":1,"output":2,"cacheRead":0.1,"cacheWrite5m":1.25,"cacheWrite1h":2}"#
        #expect(throws: (any Error).self) {
            try PriceTable(json: Data(#"{"models":[{"id":"a","provider":"x","price":\#(p)},{"id":"A","provider":"y","price":\#(p)}]}"#.utf8))
        }
    }

    @Test func aTableWithoutGeoMultipliersPricesAtListRates() throws {
        let p = #"{"input":1,"output":2,"cacheRead":0.1,"cacheWrite5m":1.25,"cacheWrite1h":2}"#
        let plain = try PriceTable(json: Data(#"{"models":[{"id":"a","provider":"anthropic","price":\#(p)}]}"#.utf8))
        let usd = try #require(plain.usd(group("a", TokenCounts(input: 1_000_000), geo: "us")))
        #expect(abs(usd - 1) < 1e-9)
    }

    @Test func anIncompleteCardIsRejected() {
        #expect(throws: (any Error).self) {
            try PriceTable(json: Data(#"{"models":[{"id":"a","provider":"x","price":{"input":1,"output":2}}]}"#.utf8))
        }
        #expect(throws: (any Error).self) { try PriceTable(json: Data("[]".utf8)) }
    }

    @Test func priceEntriesRoundTripThroughJSON() throws {
        let entry = PriceEntry(
            id: "my-model", provider: "local", price: flat(1), fast: flat(2),
            longContext: LongContextPrice(abovePromptTokens: 150_000, price: flat(3)), source: nil, asOf: nil
        )
        let data = try JSONEncoder().encode(["my-model": entry])
        #expect(try JSONDecoder().decode([String: PriceEntry].self, from: data) == ["my-model": entry])
    }

    @Test func bundledTableLoadsAndIsSourced() throws {
        let bundled = try PriceTable.bundled()
        #expect(bundled.entry(for: "claude-opus-5-5") != nil)
        #expect(!bundled.entries.isEmpty)
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        for entry in bundled.entries {
            // The two rows no page prices say so in words: `grokBuildSaysWhereItsPriceCameFrom` and its neighbour.
            if !["grok-4.7-build", "grok-4.7-build-fast"].contains(entry.id) {
                #expect(entry.source?.hasPrefix("https://") == true, "\(entry.id) has no source")
            }
            #expect(entry.asOf.flatMap { day.date(from: $0) } != nil, "\(entry.id) has no asOf day")
        }
    }

    /// The models the official pages price that this machine used on 2026-11-03 resolve, with the two Grok Build ids the user priced;
    /// what no one has priced stays without a price.
    @Test func bundledTableCoversTheModelsItsSourcesPrice() throws {
        let bundled = try PriceTable.bundled()
        let priced = [
            "claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-opus-5", "claude-haiku-5-5",
            "claude-opus-4-8", "claude-sonnet-5", "claude-mythos-5", "claude-mythos-5-1",
            "gpt-5.6-sol", "gpt-6.1-sol", "gpt-6-luna", "grok-4.7", "grok-4.7-build", "grok-4.7-build-fast",
        ]
        for model in priced {
            #expect(bundled.entry(for: model)?.id == model, "\(model)")
        }
        for model in ["codex-auto-review"] {
            #expect(bundled.entry(for: model) == nil, "\(model)")
        }
        // The dated snapshot ids the CLIs record still resolve.
        #expect(bundled.entry(for: "claude-3-5-haiku-20241022")?.id == "claude-3-5-haiku")
        #expect(bundled.entry(for: "claude-opus-4-1-20250805")?.id == "claude-opus-4-1")
        #expect(bundled.entry(for: "claude-sonnet-4-5-20250929")?.id == "claude-sonnet-4-5")
    }

    /// One Grok event of `model`, through a store, so that the event's own prompt picks its card.
    private func grokCost(of model: String, input: Int) throws -> CostSummary {
        let bundled = try PriceTable.bundled()
        let store = try EventStore.inMemory()
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let tokens = TokenCounts(input: input, output: 2_000, reasoning: 0, cacheRead: 3_000, cacheWrite5m: 400, cacheWrite1h: 500)
        try store.upsert([UsageEvent(source: .grok, dedupKey: "grok:\(model)", model: model, time: time, tokens: tokens)])
        let range = TimeRange(start: time.addingTimeInterval(-1), end: time.addingTimeInterval(1))
        return bundled.cost(of: try store.pricingGroups(in: range, thresholds: bundled.longContextThresholds))
    }

    /// Grok 4.7's card, worked by hand, so that two wrong rows cannot agree.
    private func grok47Figure(input: Int) -> Double {
        let isLong = input + 3_900 > 199_999
        let rates = isLong ? (input: 4.0, output: 12.0, read: 1.0, write: 4.0) : (input: 2.0, output: 6.0, read: 0.5, write: 2.0)
        return (Double(input) * rates.input + 2_000 * rates.output + 3_000 * rates.read + 900 * rates.write) / 1_000_000
    }

    /// The maintainer's decision of 2026-11-05.
    @Test(arguments: [1_000, 250_000]) func aGrokBuildEventCostsWhatTheSameGrok47EventCosts(input: Int) throws {
        let build = try grokCost(of: "grok-4.7-build", input: input)
        #expect(build.unpricedTokens == 0)
        #expect(abs(build.usd - (try grokCost(of: "grok-4.7", input: input)).usd) < 1e-12)
        #expect(abs(build.usd - grok47Figure(input: input)) < 1e-12)
    }

    /// The maintainer's reading of the Grok CLI on 2026-11-05: twice the price, on both cards.
    @Test(arguments: [1_000, 250_000]) func aGrokBuildFastEventCostsTwiceTheSameGrok47Event(input: Int) throws {
        let fast = try grokCost(of: "grok-4.7-build-fast", input: input)
        #expect(fast.unpricedTokens == 0)
        #expect(abs(fast.usd - 2 * (try grokCost(of: "grok-4.7", input: input)).usd) < 1e-12)
        #expect(abs(fast.usd - 2 * grok47Figure(input: input)) < 1e-12)
    }

    @Test func grokBuildSaysWhereItsPriceCameFrom() throws {
        let row = try #require(try PriceTable.bundled().entry(for: "grok-4.7-build"))
        #expect(row.id == "grok-4.7-build")
        #expect(row.provider == "xai")
        #expect(row.asOf == "2026-11-05")
        // The app is public, so "the user" would mean whoever runs it.
        #expect(row.source?.hasPrefix("The maintainer's decision of 2026-11-05") == true)
        #expect(row.source?.hasPrefix("https://") == false)
    }

    @Test func grokBuildFastSaysWhereItsPriceCameFrom() throws {
        let row = try #require(try PriceTable.bundled().entry(for: "grok-4.7-build-fast"))
        #expect(row.id == "grok-4.7-build-fast")
        #expect(row.provider == "xai")
        #expect(row.asOf == "2026-11-05")
        #expect(row.source?.hasPrefix("The maintainer's reading of the Grok CLI on 2026-11-05") == true)
        #expect(row.source?.hasPrefix("https://") == false)
    }

    @Test func grokBuild01KeepsItsOwnPrice() throws {
        let row = try #require(try PriceTable.bundled().entry(for: "grok-build-0.1"))
        #expect(row.id == "grok-build-0.1")
        #expect(row.price.input == 1)
        #expect(row.price.output == 2)
    }

    /// Catches a swapped column or a slipped decimal in a price row: a hit is cheaper than a miss, a write costs at least a plain input token.
    @Test func bundledRatesAreInTheirUsualOrder() throws {
        let bundled = try PriceTable.bundled()
        for entry in bundled.entries {
            var cards: [(name: String, price: Price)] = [("price", entry.price)]
            if let fast = entry.fast { cards.append(("fast", fast)) }
            if let long = entry.longContext { cards.append(("longContext", long.price)) }
            for (name, p) in cards {
                #expect(p.cacheRead > 0 && p.cacheRead < p.input, "\(entry.id) \(name): cacheRead")
                #expect(p.cacheWrite5m >= p.input, "\(entry.id) \(name): cacheWrite5m")
                #expect(p.cacheWrite1h >= p.cacheWrite5m, "\(entry.id) \(name): cacheWrite1h")
                #expect(p.output > p.input, "\(entry.id) \(name): output")
            }
            if let fast = entry.fast {
                #expect(fast.input > entry.price.input && fast.output > entry.price.output, "\(entry.id): fast is dearer")
            }
            if let long = entry.longContext {
                #expect(long.abovePromptTokens > 0, "\(entry.id): threshold")
                #expect(long.price.input >= entry.price.input && long.price.output >= entry.price.output, "\(entry.id): long context is not cheaper")
            }
        }
        #expect(bundled.longContextThresholds == Set(bundled.entries.compactMap { $0.longContext?.abovePromptTokens }).sorted())
    }
}
