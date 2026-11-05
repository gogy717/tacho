import Foundation
import Testing
@testable import TachoKit

/// A detail chart stacked by model or by CLI: what the columns hold, and what they must add up to.
struct DetailGroupingTests {
    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        return calendar
    }

    private let utc = Self.calendar("UTC")
    /// Midday on a Wednesday, UTC.
    private let now = date("2026-06-17T12:30:00Z")

    /// Input by the million reads as whole dollars, and `mystery` has no price.
    private let prices: PriceTable

    init() throws {
        func model(_ id: String, _ dollars: Int) -> String {
            #"{"id":"\#(id)","provider":"anthropic","price":{"input":\#(dollars),"output":\#(dollars),"cacheRead":\#(dollars),"cacheWrite5m":\#(dollars),"cacheWrite1h":\#(dollars)}}"#
        }
        let models = [("dear", 30), ("a", 6), ("b", 5), ("c", 4), ("d", 3), ("e", 2), ("f", 1), ("bulk", 1)].map(model).joined(separator: ",")
        prices = try PriceTable(json: Data(#"{"geoMultipliers":{},"models":[\#(models)]}"#.utf8))
    }

    private func reports(_ store: EventStore, sources: Set<Source> = Set(Source.allCases)) -> Reports {
        Reports(store: store, prices: prices, sources: sources, phase: .live)
    }

    private func use(_ name: String, _ time: String, source: Source = .claudeCode, model: String? = "a", input: Int = 1_000_000, output: Int = 0) -> UsageEvent {
        UsageEvent(
            source: source, client: nil, dedupKey: "\(source.rawValue):\(name)", project: "p", isSubagent: false, model: model,
            time: date(time), generationMs: nil, tokens: TokenCounts(input: input, output: output)
        )
    }

    private func storing(_ events: [UsageEvent]) throws -> EventStore {
        let store = try EventStore.inMemory()
        try store.upsert(events)
        return store
    }

    private func figures(_ range: DetailRange, _ grouping: DetailGrouping?, _ events: [UsageEvent], calendar: Calendar? = nil, now: Date? = nil) async throws -> DetailFigures {
        try await reports(storing(events)).detail(range: range, grouping: grouping, curves: [], now: now ?? self.now, calendar: calendar ?? utc)
    }

    /// Eight models and three CLIs, today so far and back past a year's reach, an unpriced model and a request that names none.
    private var everything: [UsageEvent] {
        let models: [String?] = ["dear", "a", "b", "c", "d", "e", "f", "bulk", "mystery", nil]
        let sources: [Source] = [.claudeCode, .codex, .grok]
        let times = ["2026-06-17T09:15:00Z", "2026-06-17T00:05:00Z", "2026-06-16T23:55:00Z", "2026-06-13T12:00:00Z", "2026-05-20T06:00:00Z", "2026-02-01T18:00:00Z", "2025-07-02T03:00:00Z"]
        return times.enumerated().flatMap { day, time in
            models.enumerated().map { index, model in
                use("\(day)-\(index)", time, source: sources[(day + index) % 3], model: model, input: 100_000 * (index + 1), output: 7_000 * (10 - index))
            }
        }
    }

    private func figure(_ column: DetailColumn, _ measure: DetailMeasure) -> Double {
        switch measure {
        case .cost: column.cost.usd
        case .allTokens: Double(column.tokens.total)
        case .output: Double(column.tokens.output)
        }
    }

    private func total(_ totals: PeriodTotals, _ measure: DetailMeasure) -> Double {
        switch measure {
        case .cost: totals.cost.usd
        case .allTokens: Double(totals.tokens.total)
        case .output: Double(totals.tokens.output)
        }
    }

    /// Tokens are whole, so they must be exact. Dollars are added in another order, so they may differ in the last bits of a double, which is
    /// millionths of a cent at most: they can never reach a printed figure.
    private func same(_ first: Double, _ second: Double, _ measure: DetailMeasure) -> Bool {
        measure == .cost ? abs(first - second) < 1e-9 : first == second
    }

    // MARK: Today

    @Test func aSpeedReadSaysWhetherTodayHasUse() async throws {
        let used = try await reports(storing([use("today", "2026-06-17T09:15:00Z")])).speed(range: .week, model: nil, medians: [:], now: now, calendar: utc)
        #expect(used.todayHasUse)
        let idle = try await reports(storing([use("before", "2026-06-16T09:15:00Z")])).speed(range: .week, model: nil, medians: [:], now: now, calendar: utc)
        #expect(!idle.todayHasUse)
    }

    // MARK: Adding up

    @Test(arguments: DetailRange.allCases, DetailGrouping.allCases)
    func everyColumnAddsUpToTheColumnAndThePeriodToItsTotal(range: DetailRange, grouping: DetailGrouping) async throws {
        let figures = try await figures(range, grouping, everything)
        #expect(figures.totals.tokens.total > 0)
        for measure in DetailMeasure.allCases {
            let layers = figures.layers(of: measure)
            #expect(!layers.isEmpty)
            for layer in layers { #expect(layer.values.count == figures.columns.count) }
            for (index, column) in figures.columns.enumerated() {
                let stacked = layers.reduce(0) { $0 + $1.values[index] }
                #expect(same(stacked, figure(column, measure), measure), "column \(index) of \(range) by \(grouping), \(measure)")
            }
            let whole = layers.reduce(0) { $0 + $1.values.reduce(0, +) }
            #expect(same(whole, total(figures.totals, measure), measure), "\(range) by \(grouping), \(measure)")
        }
    }

    /// A day whose repeated hour falls in one column, as the page has it.
    @Test func theDayClocksGoBackAddsUpToo() async throws {
        let sydney = Self.calendar("Australia/Sydney")
        let events = [
            use("first", "2026-04-04T15:30:00Z", model: "a"), use("repeat", "2026-04-04T16:30:00Z", source: .codex, model: "b"),
            use("after", "2026-04-04T17:30:00Z", model: "c"),
        ]
        let figures = try await figures(.day, .model, events, calendar: sydney, now: date("2026-04-05T02:00:00Z"))
        let layers = figures.layers(of: .allTokens)
        for (index, column) in figures.columns.enumerated() {
            #expect(layers.reduce(0) { $0 + $1.values[index] } == Double(column.tokens.total))
        }
        #expect(layers.reduce(0) { $0 + $1.values.reduce(0, +) } == 3_000_000)
    }

    @Test(arguments: [DetailRange.week, .month])
    func todaySoFarIsTheLastColumn(range: DetailRange) async throws {
        let figures = try await figures(range, .model, [use("today", "2026-06-17T09:15:00Z"), use("before", "2026-06-16T09:15:00Z", model: "b")])
        let layers = figures.layers(of: .allTokens)
        #expect(layers.first { $0.key == "a" }?.values.last == 1_000_000)
        #expect(layers.first { $0.key == "b" }?.values.last == 0)
    }

    // MARK: What a read leaves alone

    /// The grouped read takes its columns and totals from another query, and no figure of the page may move for it.
    @Test(arguments: DetailRange.allCases, DetailGrouping.allCases)
    func groupingMovesNoOtherFigure(range: DetailRange, grouping: DetailGrouping) async throws {
        let store = try storing(everything)
        var grouped = try await reports(store).detail(range: range, grouping: grouping, curves: [], now: now, calendar: utc)
        let plain = try await reports(store).detail(range: range, curves: [], now: now, calendar: utc)
        #expect(!grouped.series.isEmpty)
        #expect(grouped.grouping == grouping)
        grouped.series = []
        grouped.grouping = nil
        #expect(grouped == plain)
    }

    @Test func withNoGroupingThereAreNoSeries() async throws {
        #expect(try await figures(.week, nil, everything).series.isEmpty)
    }

    @Test func onlyEnabledSourcesCount() async throws {
        let store = try storing([use("on", "2026-06-17T09:15:00Z"), use("off", "2026-06-17T09:15:00Z", source: .grok, model: "b")])
        let figures = try await reports(store, sources: [.claudeCode]).detail(range: .week, grouping: .model, curves: [], now: now, calendar: utc)
        #expect(figures.series.map(\.key) == ["a"])
        let bySource = try await reports(store, sources: [.claudeCode]).detail(range: .week, grouping: .source, curves: [], now: now, calendar: utc)
        #expect(bySource.series.map(\.key) == [Source.claudeCode.displayName])
    }

    // MARK: Names

    @Test func theKeysAreTheListsKeys() async throws {
        let byModel = try await figures(.year, .model, everything)
        #expect(Set(byModel.series.map(\.key)) == Set(byModel.byModel.map(\.key)))
        #expect(byModel.series.contains { $0.key.isEmpty })
        let bySource = try await figures(.year, .source, everything)
        #expect(Set(bySource.series.map(\.key)) == Set(bySource.bySource.map(\.key)))
    }

    // MARK: The top five

    /// 1M of `dear` is $30, 9M of `bulk` is $9, and `talker` says the most for its input.
    private var ranked: [UsageEvent] {
        [
            use("dear", "2026-06-17T09:00:00Z", model: "dear", input: 1_000_000, output: 0),
            use("bulk", "2026-06-17T09:00:00Z", model: "bulk", input: 9_000_000, output: 100),
            use("talker", "2026-06-17T09:00:00Z", model: "f", input: 0, output: 500_000),
        ]
    }

    @Test func eachMeasureRanksByItsOwnFigure() async throws {
        let figures = try await figures(.week, .model, ranked)
        #expect(figures.layers(of: .cost).map(\.key) == ["dear", "bulk", "f"])
        #expect(figures.layers(of: .allTokens).map(\.key) == ["bulk", "dear", "f"])
        #expect(figures.layers(of: .output).map(\.key) == ["f", "bulk"])
    }

    @Test func theRestMergeIntoOther() async throws {
        let events = ["dear", "a", "b", "c", "d", "e", "f"].enumerated().map { index, model in
            use(model, "2026-06-17T09:00:00Z", model: model, input: 1_000_000 * (7 - index))
        }
        let layers = try await figures(.week, .model, events).layers(of: .allTokens)
        #expect(layers.map(\.key) == ["dear", "a", "b", "c", "d", nil])
        #expect(layers.last?.values.last == 3_000_000)
    }

    @Test func fiveAreAllNamedAndNeedNoOther() async throws {
        let events = ["dear", "a", "b", "c", "d"].map { use($0, "2026-06-17T09:00:00Z", model: $0) }
        let layers = try await figures(.week, .model, events).layers(of: .allTokens)
        #expect(layers.count == 5)
        #expect(!layers.contains { $0.key == nil })
    }

    /// Equal figures must not swap places between two reads, as a colour goes by the place.
    @Test func aTieGoesByName() async throws {
        let events = ["c", "a", "b"].map { use($0, "2026-06-17T09:00:00Z", model: $0) }
        #expect(try await figures(.week, .model, events).layers(of: .allTokens).map(\.key) == ["a", "b", "c"])
    }

    // MARK: No price

    /// `mystery` has the most tokens and no price, so it has no amount: no layer, nothing in Other, and the note still names it.
    @Test func aModelWithNoPriceHasNoLayerOfCostAndTheTotalsStillNameIt() async throws {
        let events = [use("mystery", "2026-06-17T09:00:00Z", model: "mystery", input: 50_000_000), use("a", "2026-06-17T09:00:00Z", model: "a")]
        let figures = try await figures(.week, .model, events)
        #expect(figures.layers(of: .cost).map(\.key) == ["a"])
        #expect(figures.totals.cost.unpricedModels == ["mystery"])
        #expect(figures.layers(of: .allTokens).map(\.key) == ["mystery", "a"])
    }

    /// One more than the five with a price, so that Other would be the place for it to hide as $0.
    @Test func aModelWithNoPriceIsNotCountedIntoOther() async throws {
        let priced = ["dear", "a", "b", "c", "d", "e"].map { use($0, "2026-06-17T09:00:00Z", model: $0) }
        let figures = try await figures(.week, .model, priced + [use("mystery", "2026-06-17T09:00:00Z", model: "mystery")])
        let layers = figures.layers(of: .cost)
        #expect(layers.last?.key == nil)
        #expect(layers.last?.values.last == 2)
        #expect(figures.totals.cost.unpricedModels == ["mystery"])
    }

    /// A CLI's priced use still counts when the rest of it has no price.
    @Test func aCLIKeepsTheCostItHas() async throws {
        let events = [use("priced", "2026-06-17T09:00:00Z", model: "a"), use("mystery", "2026-06-17T09:00:00Z", model: "mystery")]
        let figures = try await figures(.week, .source, events)
        let layer = try #require(figures.layers(of: .cost).first)
        #expect(layer.key == Source.claudeCode.displayName)
        #expect(layer.values.last == 6)
        #expect(figures.totals.cost.unpricedModels == ["mystery"])
    }

    /// A CLI with nothing but unpriced models has no amount either.
    @Test func aCLIWithNoPriceAtAllHasNoLayerOfCost() async throws {
        let events = [use("priced", "2026-06-17T09:00:00Z", model: "a"), use("mystery", "2026-06-17T09:00:00Z", source: .grok, model: "mystery")]
        let figures = try await figures(.week, .source, events)
        #expect(figures.layers(of: .cost).map(\.key) == [Source.claudeCode.displayName])
        #expect(figures.layers(of: .allTokens).count == 2)
    }
}
