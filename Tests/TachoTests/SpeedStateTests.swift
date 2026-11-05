import Foundation
import Testing
@testable import Tacho
import TachoKit

/// What the Speed page says: spec section 12.6.
struct SpeedStateTests {
    private let opus = SpeedFigures.Model(
        speed: ModelSpeed(model: "claude-opus-5-5", tokensPerSecond: 71, samples: 300, approximate: true),
        usual: UsualRange(p25: 60, median: 70, p75: 80),
        speedDays: 12
    )
    private let sonnet = SpeedFigures.Model(
        speed: ModelSpeed(model: "claude-sonnet-5-5", tokensPerSecond: 96, samples: 80, approximate: true),
        speedDays: 3
    )

    /// Timed exactly, as omp and Copilot are.
    private let exact = SpeedFigures.Model(
        speed: ModelSpeed(model: "gpt-6.1-sol", tokensPerSecond: 50, samples: 40, approximate: false),
        usual: UsualRange(p25: 45, median: 50, p75: 55),
        speedDays: 12
    )

    private func figures(range: DetailRange = .week, points: [Double?] = [70, 72], extra: [SpeedFigures.Model] = []) -> SpeedFigures {
        SpeedFigures(
            range: range,
            models: [opus, sonnet] + extra,
            columns: points.enumerated().map {
                .init(start: WindowSamples.now.addingTimeInterval(Double($0.offset) * 86_400), tokensPerSecond: $0.element, samples: 10)
            }
        )
    }

    @Test func withNoChoiceItIsTheModelWithTheMostSamples() {
        let state = SpeedState(figures: figures(), chosen: nil)
        #expect(state.chosen == "claude-opus-5-5")
        #expect(state.stats.first?.value == "≈ 71 tok/s")
    }

    @Test func aChosenModelsFiguresAreThatModels() {
        // `models` keeps the most samples first whichever is chosen, so taking the first would show the wrong one's figures.
        let state = SpeedState(figures: figures(), chosen: "claude-sonnet-5-5")
        #expect(state.chosen == "claude-sonnet-5-5")
        #expect(state.stats.first?.value == "≈ 96 tok/s")
        #expect(state.stats.last?.value == "80")
        #expect(state.stats[1].value == "needs 4 more days of use")
    }

    /// As the panel's Speed card has it.
    @Test func todayCountsTowardsASpeedsDaysOnceThereIsUse() {
        var used = figures()
        used.todayHasUse = true
        #expect(SpeedState(figures: used, chosen: "claude-sonnet-5-5").stats[1].value == "needs 3 more days of use")
    }

    @Test func theEnginesSentenceIsOnlyForTheModelItChose() {
        let insight = SpeedInsight(rule: .p8, model: "claude-opus-5-5", value: 71, range: nil)
        #expect(SpeedState(figures: figures(), chosen: nil, insight: insight).highlights.count == 1)
        #expect(SpeedState(figures: figures(), chosen: "claude-sonnet-5-5", insight: insight).highlights.isEmpty)
    }

    /// Once, at the front: `60 to ≈ 80 tok/s` would say that only the top of the range is approximate.
    @Test func anApproximateModelsUsualRangeIsMarkedOnce() {
        #expect(SpeedState(figures: figures(), chosen: nil).stats[1].value == "≈ 60 to 80 tok/s")
    }

    @Test func anExactModelsUsualRangeIsNotMarked() {
        #expect(SpeedState(figures: figures(extra: [exact]), chosen: "gpt-6.1-sol").stats[1].value == "45 to 55 tok/s")
    }

    @Test func anApproximateModelsChartReadoutIsMarked() throws {
        let state = SpeedState(figures: figures(), chosen: nil)
        let point = try #require(state.points?.first)
        #expect(try #require(state.readout(of: point)).hasSuffix("≈ 70 tok/s"))
    }

    @Test func anExactModelsChartReadoutIsNotMarked() throws {
        let state = SpeedState(figures: figures(extra: [exact]), chosen: "gpt-6.1-sol")
        let point = try #require(state.points?.first)
        let readout = try #require(state.readout(of: point))
        #expect(readout.hasSuffix("70 tok/s"))
        #expect(!readout.contains("≈"))
    }

    @Test func aColumnWithNoSamplesHasNoReadout() throws {
        let state = SpeedState(figures: figures(points: [nil, 72]), chosen: nil)
        #expect(state.readout(of: try #require(state.points?.first)) == nil)
    }

    @Test func aChoiceStaysWhileItHasSamples() {
        #expect(SpeedState.keptChoice("claude-sonnet-5-5", in: figures()) == "claude-sonnet-5-5")
    }

    @Test func aModelGoneFromTheRangeIsLetGoSoItsChartIsNotDrawnUnderAnothersFigures() {
        #expect(SpeedState.keptChoice("claude-haiku-5-5", in: figures()) == nil)
        #expect(SpeedState.keptChoice(nil, in: figures()) == nil)
    }

    @Test func aModelGoneFromTheRangeFallsBack() {
        #expect(SpeedState(figures: figures(), chosen: "claude-haiku-5-5").chosen == "claude-opus-5-5")
    }

    @Test func whileOlderLogsAreComingNoDayIsCalledMissing() {
        #expect(SpeedState(figures: figures(), chosen: "claude-sonnet-5-5", isReading: true).stats[1].value == "still reading logs")
    }

    @Test func theBandIsForWeeksAndMonths() {
        #expect(SpeedState(figures: figures(range: .week), chosen: nil).usual == 60...80)
        #expect(SpeedState(figures: figures(range: .month), chosen: nil).usual == 60...80)
        #expect(SpeedState(figures: figures(range: .day), chosen: nil).usual == nil)
        #expect(SpeedState(figures: figures(range: .year), chosen: nil).usual == nil)
    }

    @Test func aColumnWithNoSamplesKeepsItsPlaceWithNothingToPlot() throws {
        let points = try #require(SpeedState(figures: figures(points: [70, nil, 72]), chosen: nil).points)
        #expect(points.count == 3)
        #expect(points[1].tokensPerSecond == nil)
        #expect(points[1].axis != nil)
    }

    @Test func everyModelSaysHowManyRequestsItRestsOn() {
        let state = SpeedState(figures: figures(), chosen: nil)
        #expect(state.models.map(\.name) == ["Opus 5.5", "Sonnet 5.5"])
        #expect(state.models.map(\.note) == ["300 requests", "80 requests"])
        #expect(state.models.allSatisfy { $0.fraction == nil })
    }
}
