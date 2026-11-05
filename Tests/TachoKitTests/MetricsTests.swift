import Foundation
import TachoKit
import Testing

struct MetricsTests {
    private let now = date("2026-11-03T10:00:00Z")

    /// A local table, not the bundled one, so the tests survive price updates.
    private let table: PriceTable

    init() throws {
        table = try PriceTable(json: Data(#"""
        {"geoMultipliers":{"anthropic":{"us":1.1}},"models":[
         {"id":"claude-opus-5-5","provider":"anthropic","price":{"input":4,"output":20,"cacheRead":0.2,"cacheWrite5m":5,"cacheWrite1h":8}},
         {"id":"claude-haiku-5-5","provider":"anthropic","price":{"input":0.1,"output":0.5,"cacheRead":0.01,"cacheWrite5m":0.125,"cacheWrite1h":0.2},
          "longContext":{"abovePromptTokens":50000,"price":{"input":0.5,"output":2.5,"cacheRead":0.05,"cacheWrite5m":0.625,"cacheWrite1h":1}}}]}
        """#.utf8))
    }

    private func snapshot(
        _ window: QuotaWindow = .fiveHour,
        scope: String? = nil,
        used: Double = 20,
        resetsIn: TimeInterval = 10_800,
        observedAgo: TimeInterval = 600
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: .anthropic,
            window: window,
            scope: scope,
            usedPercent: used,
            resetsAt: now.addingTimeInterval(resetsIn),
            observedAt: now.addingTimeInterval(-observedAgo),
            origin: .claudeCache
        )
    }

    private func project(_ snapshot: QuotaSnapshot, _ calibration: Double, _ afterSnapshot: Double, _ recent: Double) -> Projection {
        ProjectionEngine.project(snapshot, weights: WindowWeights(calibration: calibration, afterSnapshot: afterSnapshot, recent: recent), now: now)
    }

    private func expectRunsOut(
        _ outcome: Projection.Outcome,
        inSeconds expected: TimeInterval,
        beforeReset expectedMargin: TimeInterval,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .runsOut(let at, let beforeReset) = outcome else {
            Issue.record("expected .runsOut, got \(outcome)", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(at.timeIntervalSince(now) - expected) < 1, sourceLocation: sourceLocation)
        #expect(abs(beforeReset - expectedMargin) < 1, sourceLocation: sourceLocation)
    }

    private func sample(
        _ model: String = "m",
        output: Int = 600,
        generationMs: Double? = nil,
        startedAgo: TimeInterval? = nil
    ) -> SpeedSample {
        SpeedSample(model: model, output: output, generationMs: generationMs, startTime: startedAgo.map { now.addingTimeInterval(-$0) }, time: now)
    }

    private func event(
        _ name: String,
        ago: TimeInterval,
        source: Source = .claudeCode,
        provider: String? = nil,
        model: String? = "claude-opus-5-5",
        tokens: TokenCounts
    ) -> UsageEvent {
        UsageEvent(
            source: source, dedupKey: "\(source.rawValue):\(name)", provider: provider, model: model,
            time: now.addingTimeInterval(-ago), tokens: tokens
        )
    }

    private func weights(
        _ events: [UsageEvent],
        for snapshot: QuotaSnapshot? = nil,
        includedSources: Set<Source> = Set(Source.allCases)
    ) throws -> WindowWeights {
        let store = try EventStore.inMemory()
        try store.upsert(events)
        return try QuotaWeights.compute(store: store, prices: table, snapshot: snapshot ?? self.snapshot(), includedSources: includedSources, now: now)
    }

    private func expectClose(_ actual: WindowWeights, _ expected: WindowWeights, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(actual.calibration - expected.calibration) < 1e-9, "calibration \(actual.calibration)", sourceLocation: sourceLocation)
        #expect(abs(actual.afterSnapshot - expected.afterSnapshot) < 1e-9, "afterSnapshot \(actual.afterSnapshot)", sourceLocation: sourceLocation)
        #expect(abs(actual.recent - expected.recent) < 1e-9, "recent \(actual.recent)", sourceLocation: sourceLocation)
    }

    // MARK: Projection

    @Test func calibratedLastsUntilReset() {
        let projection = project(snapshot(), 10, 1, 3)
        #expect(projection.estimatedPercent == 22)
        #expect(projection.method == .calibrated)
        #expect(projection.isEstimate)
        #expect(!projection.isStale)
        #expect(projection.outcome == .lastsUntilReset)
        #expect(projection.resetsAt == now.addingTimeInterval(10_800))
        #expect(projection.snapshot == snapshot())
    }

    @Test func calibratedRunsOutBeforeReset() {
        expectRunsOut(project(snapshot(), 10, 1, 15).outcome, inSeconds: 4_680, beforeReset: 6_120)
    }

    /// k = 2 and recent = 900 make the pace exactly 1% a second, so the last 80% ends on the reset, 80 s from now.
    @Test func runningOutAtTheResetLastsUntilIt() {
        #expect(project(snapshot(resetsIn: 80), 10, 0, 900).outcome == .lastsUntilReset)
    }

    @Test func idleWhenNothingRecent() {
        #expect(project(snapshot(), 10, 1, 0).outcome == .idle)
    }

    @Test func fallsBackToTheWindowAverage() {
        let projection = project(snapshot(used: 60), 0, 0, 3)
        #expect(projection.method == .windowAverage)
        #expect(projection.estimatedPercent == 60)
        expectRunsOut(projection.outcome, inSeconds: 4_400, beforeReset: 6_400)
    }

    @Test func belowOnePercentCannotCalibrate() {
        #expect(project(snapshot(used: 0.5), 10, 0, 3).method == .windowAverage)
    }

    @Test func onePercentCanCalibrate() {
        #expect(project(snapshot(used: 1), 10, 0, 3).method == .calibrated)
    }

    /// Without k there is nothing to scale local use by, so it cannot move the estimate.
    @Test func theWindowAverageIgnoresWhatCameAfterTheSnapshot() {
        let projection = project(snapshot(used: 0.5), 10, 5, 3)
        #expect(projection.estimatedPercent == 0.5)
        #expect(!projection.isEstimate)
    }

    @Test func nothingUsedYetIsIdle() {
        #expect(project(snapshot(used: 0), 0, 0, 3).outcome == .idle)
    }

    @Test func obsoleteSnapshotRestartsFromZero() {
        let projection = project(snapshot(used: 80, resetsIn: -600), 40, 5, 3)
        #expect(projection.estimatedPercent == 10)
        #expect(projection.resetsAt == now.addingTimeInterval(17_400))
        #expect(projection.outcome == .lastsUntilReset)
        #expect(!projection.isStale)
        #expect(projection.isEstimate)
    }

    /// Measured against the next reset, 17,400 s away, not the one that has passed.
    @Test func anObsoleteSnapshotRunsOutAgainstTheNextReset() {
        expectRunsOut(project(snapshot(used: 80, resetsIn: -600), 40, 5, 60).outcome, inSeconds: 1_350, beforeReset: 16_050)
    }

    /// `obsolete = now ≥ resetsAt`, and `while reset ≤ now`: the instant of the reset is already the next window.
    @Test func aSnapshotIsObsoleteAtTheInstantItResets() {
        let projection = project(snapshot(used: 80, resetsIn: 0), 40, 0, 0)
        #expect(projection.estimatedPercent == 0)
        #expect(projection.resetsAt == now.addingTimeInterval(18_000))
    }

    @Test func theResetMovesOnByWholeWindows() {
        #expect(project(snapshot(resetsIn: -40_000), 10, 0, 3).resetsAt == now.addingTimeInterval(14_000))
    }

    @Test func anObsoleteSnapshotThatCannotCalibrateIsUnknown() {
        let projection = project(snapshot(used: 80, resetsIn: -600), 0, 0, 3)
        #expect(projection.outcome == .unknown)
        #expect(projection.method == .windowAverage)
        #expect(projection.estimatedPercent == 0)
    }

    /// Spec §5.5 step 8: past its reset a snapshot says nothing, so whatever is shown is inferred, even with nothing to calibrate from.
    @Test func anObsoleteSnapshotIsAlwaysAnEstimate() {
        #expect(project(snapshot(used: 80, resetsIn: -600), 0, 0, 3).isEstimate)
        #expect(project(snapshot(used: 0.5, resetsIn: -600), 10, 0, 3).isEstimate)
    }

    @Test func aSnapshotWithNothingAfterItIsNotAnEstimate() {
        let projection = project(snapshot(), 10, 0, 3)
        #expect(projection.estimatedPercent == 20)
        #expect(!projection.isEstimate)
    }

    /// An obsolete snapshot's figure is inferred even with no use since the reset.
    @Test func anObsoleteCalibratedSnapshotIsAnEstimateEvenWithNothingAfterIt() {
        #expect(project(snapshot(used: 80, resetsIn: -600), 40, 0, 3).isEstimate)
    }

    @Test func estimateCapsAtHundred() {
        #expect(project(snapshot(), 1, 1_000, 3).estimatedPercent == 100)
    }

    @Test func aFullQuotaRunsOutNow() {
        expectRunsOut(project(snapshot(), 1, 1_000, 3).outcome, inSeconds: 0, beforeReset: 10_800)
    }

    /// Ruling (Task 14): the window average needs time to have passed. Observed as a window opens, with nothing used, it would
    /// be 0 / 0, and NaN would read as "runs out" and raise an amber alert on an unused quota.
    @Test func aSnapshotAtTheWindowStartWithNothingUsedHasNoPace() {
        let projection = project(snapshot(used: 0, resetsIn: 17_400, observedAgo: 600), 0, 0, 3)
        #expect(projection.outcome == .unknown)
        #expect(ProjectionEngine.alert([projection]) == .none)
    }

    @Test func aSnapshotAtTheWindowStartWithSomethingUsedHasNoPace() {
        let projection = project(snapshot(used: 40, resetsIn: 17_400, observedAgo: 600), 0, 0, 3)
        #expect(projection.outcome == .unknown)
        #expect(ProjectionEngine.alert([projection]) == .none)
    }

    /// The window opened 300 s ago, but the snapshot is 600 s old: a negative pace would run out in the past.
    @Test func aSnapshotFromBeforeTheWindowStartHasNoPace() {
        let projection = project(snapshot(used: 40, resetsIn: 17_700, observedAgo: 600), 0, 0, 3)
        #expect(projection.outcome == .unknown)
        #expect(projection.estimatedPercent == 40)
        #expect(ProjectionEngine.alert([projection]) == .none)
    }

    /// The guard is on the window average only: a calibrated pace does not divide by the time elapsed.
    @Test func aCalibratedPaceNeedsNoElapsedTime() {
        let projection = project(snapshot(used: 40, resetsIn: 17_400, observedAgo: 600), 10, 0, 3)
        #expect(projection.method == .calibrated)
        #expect(projection.outcome != .unknown)
    }

    @Test func staleness() {
        #expect(project(snapshot(.fiveHour, observedAgo: 901), 10, 0, 3).isStale)
        #expect(!project(snapshot(.fiveHour, observedAgo: 900), 10, 0, 3).isStale)
        #expect(!project(snapshot(.weekly, observedAgo: 3_599), 10, 0, 3).isStale)
        #expect(project(snapshot(.weekly, observedAgo: 3_601), 10, 0, 3).isStale)
    }

    /// Spec 5.6: past 15 minutes the mark shows, reset or not. Observed 09:00, reset 10:00, now 10:30.
    @Test func anObsoleteSnapshotIsStaleByItsAge() {
        #expect(project(snapshot(used: 80, resetsIn: -1_800, observedAgo: 5_400), 40, 5, 3).isStale)
        #expect(project(snapshot(used: 80, resetsIn: -600, observedAgo: 901), 40, 5, 3).isStale)
        #expect(!project(snapshot(used: 80, resetsIn: -600, observedAgo: 900), 40, 5, 3).isStale)
    }

    @Test func staleAfterFollowsTheWindow() {
        #expect(ProjectionEngine.staleAfter(.fiveHour) == 900)
        #expect(ProjectionEngine.staleAfter(.weekly) == 3_600)
        #expect(ProjectionEngine.recentWindow == 1_800)
    }

    // MARK: No recent data

    /// A snapshot with the weights for a forecast, so that nothing on the wrong side of the limit passes by accident.
    private func expired(_ window: QuotaWindow, by seconds: TimeInterval, afterSnapshot: Double = 5, recent: Double = 60) -> Projection {
        project(snapshot(window, used: 80, resetsIn: -seconds, observedAgo: seconds + 600), 40, afterSnapshot, recent)
    }

    @Test(arguments: [(QuotaWindow.fiveHour, 18_000.0), (QuotaWindow.weekly, 604_800.0)])
    func aFullWindowAfterItsResetASnapshotHasNoRecentData(window: QuotaWindow, length: TimeInterval) {
        for seconds in [length, length + 1, length * 3 + 1] {
            let projection = expired(window, by: seconds)
            #expect(!projection.hasRecentData, "\(seconds)")
            #expect(projection.outcome == .unknown, "\(seconds)")
            #expect(projection.estimatedPercent == 0, "\(seconds)")
            #expect(!projection.isEstimate, "\(seconds)")
            #expect(!projection.isStale, "\(seconds)")
            #expect(projection.method == .windowAverage, "nothing was calibrated, \(seconds)")
        }
    }

    @Test(arguments: [(QuotaWindow.fiveHour, 18_000.0), (QuotaWindow.weekly, 604_800.0)])
    func aSecondShortOfAFullWindowIsStillAForecast(window: QuotaWindow, length: TimeInterval) {
        let projection = expired(window, by: length - 1)
        #expect(projection.hasRecentData)
        #expect(projection.estimatedPercent == 10)
        #expect(projection.isEstimate)
        #expect(projection.outcome == .lastsUntilReset)
        #expect(projection.resetsAt == now.addingTimeInterval(1))
    }

    @Test func aRowWithNoRecentDataStillNamesItsQuota() {
        let old = snapshot(.weekly, scope: "Fable", used: 80, resetsIn: -604_800, observedAgo: 700_000)
        let projection = project(old, 40, 5, 60)
        #expect(!projection.hasRecentData)
        #expect(projection.snapshot == old)
        #expect(projection.resetsAt == now.addingTimeInterval(604_800))
    }

    @Test func noRecentDataAppliesToEveryProviderAndScope() {
        for provider in QuotaProvider.allCases {
            for scope in [nil, "Fable"] as [String?] {
                let old = QuotaSnapshot(
                    provider: provider, window: .weekly, scope: scope, usedPercent: 80,
                    resetsAt: now.addingTimeInterval(-604_800), observedAt: now.addingTimeInterval(-700_000), origin: .claudeCache
                )
                #expect(!project(old, 40, 5, 60).hasRecentData, "\(provider) \(scope ?? "no scope")")
            }
        }
    }

    @Test func aRowWithinOneWindowOfItsResetIsUnchanged() {
        // Step 8 as it stands: from 0, plus what was used since, against the next reset.
        let projection = project(snapshot(used: 80, resetsIn: -600), 40, 5, 60)
        #expect(projection.hasRecentData)
        #expect(projection.estimatedPercent == 10)
        #expect(projection.isEstimate)
        #expect(!projection.isStale)
        #expect(projection.method == .calibrated)
        #expect(projection.resetsAt == now.addingTimeInterval(17_400))
        expectRunsOut(projection.outcome, inSeconds: 1_350, beforeReset: 16_050)
    }

    @Test func aWindowStillOpenHasRecentDataHoweverOldTheObservation() {
        let projection = project(snapshot(.weekly, resetsIn: 3_600, observedAgo: 700_000), 10, 1, 15)
        #expect(projection.hasRecentData)
        #expect(projection.isStale)
    }

    @Test func aProjectionHasRecentDataUnlessToldOtherwise() {
        #expect(projection(percent: 50).hasRecentData)
    }

    // MARK: Alerts

    // MARK: Pace

    /// 20% for 5 of local use is 4 points a unit, so 1.5 in the last half hour is 6 points in 1,800 s.
    @Test func aCalibratedPaceIsRecentUseScaled() throws {
        let projection = project(snapshot(), 5, 0, 1.5)

        #expect(projection.method == .calibrated)
        #expect(abs(try #require(projection.recentPercentPerHour) - 12) < 1e-9)
        #expect(projection.pacePercentPerHour == projection.recentPercentPerHour)
    }

    /// 20% in the 6,600 s between the window opening and the snapshot.
    @Test func theWindowAverageIsUseOverTheTimeOpen() throws {
        let average = 20.0 / 6_600 * 3_600

        let calibrated = project(snapshot(), 5, 0, 1.5)
        #expect(abs(try #require(calibrated.windowPercentPerHour) - average) < 1e-9)

        let uncalibrated = project(snapshot(), 0, 0, 0)
        #expect(uncalibrated.method == .windowAverage)
        #expect(uncalibrated.recentPercentPerHour == nil)
        #expect(abs(try #require(uncalibrated.windowPercentPerHour) - average) < 1e-9)
        #expect(uncalibrated.pacePercentPerHour == uncalibrated.windowPercentPerHour)
    }

    /// `pacePercentPerHour` is the pace the forecast runs on, so the two cannot tell different stories.
    @Test func theForecastRunsOnTheSamePace() throws {
        let projection = project(snapshot(used: 50), 10, 0, 5)
        let pace = try #require(projection.pacePercentPerHour)

        guard case .runsOut(let at, _) = projection.outcome else {
            Issue.record("expected a run-out")
            return
        }
        #expect(abs(at.timeIntervalSince(now) - (100 - projection.estimatedPercent) / pace * 3_600) < 1e-6)
    }

    /// The window it measured is over, and no snapshot says how this one opened.
    @Test func aSnapshotPastItsResetHasNoWindowAverage() {
        let projection = project(snapshot(resetsIn: -600), 5, 1, 1.5)

        #expect(projection.windowPercentPerHour == nil)
        #expect(projection.recentPercentPerHour != nil)
    }

    @Test func aSnapshotFromBeforeItsWindowHasNoWindowAverage() {
        #expect(project(snapshot(observedAgo: 7_200), 0, 0, 0).windowPercentPerHour == nil)
        #expect(project(snapshot(observedAgo: 9_000), 0, 0, 0).windowPercentPerHour == nil)
    }

    @Test func aSnapshotAWindowOldHasNoPace() {
        let projection = project(snapshot(resetsIn: -18_000), 5, 1, 1.5)

        #expect(!projection.hasRecentData)
        #expect(projection.recentPercentPerHour == nil)
        #expect(projection.windowPercentPerHour == nil)
        #expect(projection.pacePercentPerHour == nil)
        #expect(projection.paceFraction(at: now) == nil)
    }

    /// Opened 7,200 s ago, of 18,000.
    @Test func paceFractionIsHowFarThroughTheWindow() throws {
        let projection = project(snapshot(), 5, 0, 1.5)

        #expect(abs(try #require(projection.paceFraction(at: now)) - 0.4) < 1e-9)
        #expect(abs(try #require(projection.paceFraction(at: now.addingTimeInterval(1_800))) - 0.5) < 1e-9)
    }

    @Test func paceFractionStaysOnTheScale() {
        let projection = project(snapshot(), 5, 0, 1.5)

        #expect(projection.paceFraction(at: now.addingTimeInterval(-10_000)) == 0)
        #expect(projection.paceFraction(at: now.addingTimeInterval(20_000)) == 1)
    }

    /// It follows the next reset, the window the row is about.
    @Test func paceFractionOfASnapshotPastItsResetIsOfTheNextWindow() throws {
        let projection = project(snapshot(resetsIn: -3_600), 5, 0, 1.5)

        #expect(abs(try #require(projection.paceFraction(at: now)) - 0.2) < 1e-9)
    }

    private func projection(percent: Double, outcome: Projection.Outcome = .lastsUntilReset, hasRecentData: Bool = true) -> Projection {
        Projection(
            snapshot: snapshot(), estimatedPercent: percent, isEstimate: false, method: .calibrated,
            outcome: outcome, isStale: false, resetsAt: now, hasRecentData: hasRecentData
        )
    }

    @Test func alertLevels() {
        let runsOut = Projection.Outcome.runsOut(at: now, beforeReset: 60)
        #expect(ProjectionEngine.alert([projection(percent: 90)]) == .red)
        #expect(ProjectionEngine.alert([projection(percent: 50, outcome: runsOut)]) == .amber)
        #expect(ProjectionEngine.alert([projection(percent: 90), projection(percent: 50, outcome: runsOut)]) == .red)
        #expect(ProjectionEngine.alert([projection(percent: 50)]) == .none)
        #expect(ProjectionEngine.alert([]) == .none)
    }

    @Test func justBelowNinetyIsNotRed() {
        #expect(ProjectionEngine.alert([projection(percent: 89.99)]) == .none)
    }

    @Test func idleAndUnknownRaiseNoAlert() {
        #expect(ProjectionEngine.alert([projection(percent: 50, outcome: .idle), projection(percent: 50, outcome: .unknown)]) == .none)
    }

    @Test func anAlertIgnoresARowWithNoRecentData() {
        let runsOut = Projection.Outcome.runsOut(at: now, beforeReset: 60)
        #expect(ProjectionEngine.alert([projection(percent: 95, hasRecentData: false)]) == .none)
        #expect(ProjectionEngine.alert([projection(percent: 50, outcome: runsOut, hasRecentData: false)]) == .none)
    }

    @Test func anAlertStillHearsTheRowsBesideOneWithNoRecentData() {
        let runsOut = Projection.Outcome.runsOut(at: now, beforeReset: 60)
        let silent = projection(percent: 95, outcome: runsOut, hasRecentData: false)
        #expect(ProjectionEngine.alert([silent, projection(percent: 90)]) == .red)
        #expect(ProjectionEngine.alert([silent, projection(percent: 50, outcome: runsOut)]) == .amber)
        #expect(ProjectionEngine.alert([silent, projection(percent: 50)]) == .none)
    }

    @Test(arguments: [(QuotaWindow.fiveHour, 18_000.0), (QuotaWindow.weekly, 604_800.0)])
    func aWarningEndsAtTheLimit(window: QuotaWindow, length: TimeInterval) {
        #expect(ProjectionEngine.alert([expired(window, by: length - 1, afterSnapshot: 45)]) == .red)
        #expect(ProjectionEngine.alert([expired(window, by: length, afterSnapshot: 45)]) == .none)
        #expect(ProjectionEngine.alert([expired(window, by: length - 1, recent: 90_000)]) == .amber)
        #expect(ProjectionEngine.alert([expired(window, by: length, recent: 90_000)]) == .none)
    }

    // MARK: Generation speed

    @Test func exactSpeedWins() throws {
        let rate = try #require(GenerationSpeed.rate(sample(output: 600, generationMs: 10_000)))
        #expect(rate.tokensPerSecond == 60)
        #expect(!rate.approximate)

        let both = try #require(GenerationSpeed.rate(sample(output: 600, generationMs: 10_000, startedAgo: 12)))
        #expect(both.tokensPerSecond == 60)
        #expect(!both.approximate)
    }

    @Test func approximateSpeedFromStart() throws {
        let rate = try #require(GenerationSpeed.rate(sample(output: 600, startedAgo: 12)))
        #expect(rate.tokensPerSecond == 50)
        #expect(rate.approximate)
    }

    @Test func filtersShortSamples() {
        #expect(GenerationSpeed.rate(sample(output: 49, generationMs: 10_000)) == nil)
        #expect(GenerationSpeed.rate(sample(output: 49, startedAgo: 12)) == nil)
        #expect(GenerationSpeed.rate(sample(generationMs: 400)) == nil)
        #expect(GenerationSpeed.rate(sample(startedAgo: 0.4)) == nil)
    }

    @Test func theFiltersKeepTheirEdges() throws {
        #expect(GenerationSpeed.minOutputTokens == 50)
        #expect(GenerationSpeed.minSeconds == 0.5)
        let rate = try #require(GenerationSpeed.rate(sample(output: 50, generationMs: 500)))
        #expect(rate.tokensPerSecond == 100)
    }

    /// About 0.4% of Claude events have `startTime` after `time`: the CLI writes the next `api-request` before the last block.
    @Test func aStartAfterTheEndIsNoSpeed() {
        #expect(GenerationSpeed.rate(sample(startedAgo: -3)) == nil)
    }

    /// `duration − ttft` can come out negative on odd records.
    @Test func aNegativeGenerationTimeIsNoSpeed() {
        #expect(GenerationSpeed.rate(sample(generationMs: -3_000)) == nil)
    }

    /// "Exact first" means the exact value decides: a bad one does not fall back to the approximate one.
    @Test func aRejectedExactTimeDoesNotFallBackToTheStart() {
        #expect(GenerationSpeed.rate(sample(generationMs: 400, startedAgo: 12)) == nil)
    }

    @Test func noTimingIsNoSpeed() {
        #expect(GenerationSpeed.rate(sample()) == nil)
    }

    @Test func medianPerModel() {
        let speeds = GenerationSpeed.medians([100, 200, 300, 400].map { sample(output: $0, generationMs: 10_000) })
        #expect(speeds == [ModelSpeed(model: "m", tokensPerSecond: 25, samples: 4, approximate: false)])
    }

    @Test func anOddCountTakesTheMiddleRate() {
        let speeds = GenerationSpeed.medians([900, 100, 200].map { sample(output: $0, generationMs: 10_000) })
        #expect(speeds.map(\.tokensPerSecond) == [20])
    }

    @Test func mediansLeaveOutRejectedSamples() {
        let speeds = GenerationSpeed.medians([
            sample("kept", output: 100, generationMs: 10_000),
            sample("kept", output: 10, generationMs: 10_000),
            sample("kept", startedAgo: -3),
            sample("gone", output: 10, generationMs: 10_000),
        ])
        #expect(speeds == [ModelSpeed(model: "kept", tokensPerSecond: 10, samples: 1, approximate: false)])
    }

    @Test func mediansSortBySampleCountThenModel() {
        let timed = { (model: String) in self.sample(model, generationMs: 10_000) }
        let speeds = GenerationSpeed.medians([timed("b"), timed("c"), timed("c"), timed("a")])
        #expect(speeds.map(\.model) == ["c", "a", "b"])
        #expect(speeds.map(\.samples) == [2, 1, 1])
    }

    /// One model can come through both Claude Code (approximate) and omp (exact). The panel marks a figure "约" if any of it is.
    @Test func aMedianWithAnyApproximateSampleIsApproximate() {
        let mixed = GenerationSpeed.medians([sample(generationMs: 10_000), sample(startedAgo: 12)])
        #expect(mixed.map(\.approximate) == [true])
    }

    // MARK: Weights

    @Test func weightsUseUSDUnlessSomethingIsUnpriced() throws {
        let priced = [
            event("calibration", ago: 3_600, tokens: TokenCounts(output: 1_000_000)),
            event("recent", ago: 900, tokens: TokenCounts(cacheRead: 1_000_000)),
            event("after", ago: 300, tokens: TokenCounts(input: 1_000_000)),
        ]
        expectClose(try weights(priced), WindowWeights(calibration: 20.2, afterSnapshot: 4, recent: 4.2))

        let unpriced = event("local", ago: 3_000, model: "gemma4:12b", tokens: TokenCounts(input: 500_000))
        expectClose(try weights(priced + [unpriced]), WindowWeights(calibration: 2_500_000, afterSnapshot: 1_000_000, recent: 2_000_000))
    }

    /// The window start belongs to it, the snapshot's instant to what it measured (spec §5.5: [S, t₀]), and `now` to nothing yet.
    /// The window starts 7,200 s ago and the snapshot is 600 s old.
    @Test func weightWindowsKeepTheirEdges() throws {
        let found = try weights([
            event("window-start", ago: 7_200, tokens: TokenCounts(output: 1_000_000)),
            event("snapshot", ago: 600, tokens: TokenCounts(output: 2_000_000)),
            event("recent-start", ago: 1_800, tokens: TokenCounts(output: 4_000_000)),
            event("now", ago: 0, tokens: TokenCounts(output: 8_000_000)),
            event("before-the-window", ago: 7_201, tokens: TokenCounts(output: 16_000_000)),
        ])
        expectClose(found, WindowWeights(calibration: 140, afterSnapshot: 0, recent: 120))
    }

    /// `CodexReader` gives a record's event and its snapshot one timestamp, so this is every Codex snapshot, not a corner case.
    /// Real timestamps carry fractions, and `Date` holds them more finely than the store's unix seconds: several are tried so
    /// that some land where the two disagree. The snapshot is also read back from the store, as the dashboard reads it.
    @Test func anEventAtTheInstantOfTheSnapshotIsPartOfWhatItMeasured() throws {
        for millis in 120..<136 {
            var snapshot = self.snapshot()
            snapshot.observedAt = date("2026-11-03T09:50:00.\(millis)Z")
            var same = event("same", ago: 0, tokens: TokenCounts(output: 1_000_000))
            same.time = snapshot.observedAt
            var next = event("next", ago: 0, tokens: TokenCounts(output: 2_000_000))
            next.time = Date(timeIntervalSince1970: snapshot.observedAt.timeIntervalSince1970.nextUp)

            let store = try EventStore.inMemory()
            try store.upsert([same, next])
            try store.record([snapshot])
            for candidate in [snapshot] + (try store.latestSnapshots()) {
                let found = try QuotaWeights.compute(store: store, prices: table, snapshot: candidate, includedSources: Set(Source.allCases), now: now)
                expectClose(found, WindowWeights(calibration: 20, afterSnapshot: 40, recent: 60))
            }
        }
    }

    /// The formula as it stands in the spec, one query for each thing it asks: the window, then each weight.
    private func reference(_ store: EventStore, _ snapshot: QuotaSnapshot) throws -> WindowWeights {
        let filter = EventFilter(sources: Set(Source.allCases), quotaProvider: snapshot.provider, modelContains: snapshot.scope)
        let thresholds = table.longContextThresholds
        let length = snapshot.window.length
        let windowStart = snapshot.resetsAt.addingTimeInterval(-length)
        var nextReset = snapshot.resetsAt
        while nextReset <= now { nextReset += length }
        let lastReset = nextReset.addingTimeInterval(-length)
        let pastSnapshot = Date(timeIntervalSince1970: snapshot.observedAt.timeIntervalSince1970.nextUp)
        let all = try store.pricingGroups(in: TimeRange(start: windowStart, end: now), filter: filter, thresholds: thresholds)
        let allPriced = table.cost(of: all).unpricedTokens == 0
        func weight(from start: Date, to end: Date) throws -> Double {
            let range = TimeRange(start: start, end: end)
            guard allPriced else { return Double(try store.tokens(in: range, filter: filter).total) }
            return table.cost(of: try store.pricingGroups(in: range, filter: filter, thresholds: thresholds)).usd
        }
        return WindowWeights(
            calibration: try weight(from: windowStart, to: pastSnapshot),
            afterSnapshot: try weight(from: max(pastSnapshot, lastReset), to: now),
            recent: try weight(from: now.addingTimeInterval(-ProjectionEngine.recentWindow), to: now)
        )
    }

    /// `compute` makes its long pass once, by reading the window in two parts where the snapshot divides it. So the edges are where the
    /// snapshot does not: it is older than the last reset, or before its window opened, or after `now`; and where only one part has
    /// something unpriced, which turns every weight to tokens.
    @Test(arguments: [0, 1, 2, 3]) func theWeightsAreTheFormulasAtEveryEdge(unpricedIn part: Int) throws {
        let length = QuotaWindow.fiveHour.length
        let events = [100.0, 1_000, 3_000, 6_000, 12_000, 20_000, 40_000, 100_000].enumerated().map { index, ago in
            event("e\(index)", ago: ago, tokens: TokenCounts(input: 1_000 * (index + 1), output: 100_000 * (index + 1)))
        }
        // Before the snapshot, after it, ahead of `now`, or nowhere.
        let unpriced = [event("u", ago: 15_000, model: "no-such-model", tokens: TokenCounts(output: 7_000_000)),
                        event("u", ago: 500, model: "no-such-model", tokens: TokenCounts(output: 7_000_000)),
                        event("u", ago: -100, model: "no-such-model", tokens: TokenCounts(output: 7_000_000))]
        let store = try EventStore.inMemory()
        try store.upsert(events + (part < unpriced.count ? [unpriced[part]] : []))
        let cases: [(resetsIn: TimeInterval, observedAgo: TimeInterval)] = [
            (3_600, 600),               // the usual: inside its window
            (3_600, 0),                 // read this instant
            (3_600, -300),              // after `now`: a clock that disagreed
            (length - 60, 600),         // before its window opened
            (length, 0),                // its window opens now
            (-3_600, 16_000),           // reset an hour ago, older than the reset
            (-3_600, 3_000),            // reset an hour ago, after that reset
            (-(length - 60), length),   // nearly a whole window past
            (10, 18_000),               // read at the moment it opened
        ]
        for (resetsIn, observedAgo) in cases {
            let edge = snapshot(resetsIn: resetsIn, observedAgo: observedAgo)
            let found = try QuotaWeights.compute(store: store, prices: table, snapshot: edge, includedSources: Set(Source.allCases), now: now)
            #expect(found == (try reference(store, edge)), "resets in \(resetsIn), observed \(observedAgo) ago")
        }
    }

    /// The window opened 40 s before this snapshot, whose own reply is the only local use. It calibrates: left out, the forecast
    /// would fall back to the window average, which from 40 s of data says the quota runs out in half an hour.
    @Test func theFirstReplyOfAWindowCalibrates() throws {
        let snapshot = snapshot(used: 2, resetsIn: 17_950, observedAgo: 10)
        let found = try weights([event("first", ago: 10, tokens: TokenCounts(output: 1_000_000))], for: snapshot)

        let projection = ProjectionEngine.project(snapshot, weights: found, now: now)

        #expect(projection.method == .calibrated)
        #expect(projection.outcome == .lastsUntilReset)
        #expect(ProjectionEngine.alert([projection]) == .none)
    }

    @Test func aSnapshotDoesNotCountItsOwnReplyTwice() throws {
        let snapshot = snapshot()
        let found = try weights([
            event("earlier", ago: 3_600, tokens: TokenCounts(output: 1_000_000)),
            event("own", ago: 600, tokens: TokenCounts(output: 1_000_000)),
        ], for: snapshot)

        let projection = ProjectionEngine.project(snapshot, weights: found, now: now)

        #expect(projection.estimatedPercent == 20)
        #expect(!projection.isEstimate)
    }

    /// The window was over 600 s ago, so what came between the snapshot and the reset belongs to it, not to the new one.
    @Test func afterAResetOnlyTheNewWindowCounts() throws {
        let found = try weights([
            event("old-window", ago: 5_000, tokens: TokenCounts(output: 1_000_000)),
            event("before-the-reset", ago: 700, tokens: TokenCounts(output: 2_000_000)),
            event("after-the-reset", ago: 300, tokens: TokenCounts(output: 4_000_000)),
        ], for: snapshot(resetsIn: -600, observedAgo: 4_000))
        expectClose(found, WindowWeights(calibration: 20, afterSnapshot: 80, recent: 120))
    }

    /// Resets 40,000 s, 22,000 s and 4,000 s ago: the last boundary is the latest of them, not `resetsAt`.
    @Test func severalResetsLaterTheLastBoundaryCounts() throws {
        let found = try weights([
            event("before-the-last-reset", ago: 5_000, tokens: TokenCounts(output: 1_000_000)),
            event("after-the-last-reset", ago: 3_000, tokens: TokenCounts(output: 2_000_000)),
        ], for: snapshot(resetsIn: -40_000, observedAgo: 45_000))
        #expect(abs(found.afterSnapshot - 40) < 1e-9)
    }

    @Test func nothingCountsAfterAResetHappeningNow() throws {
        let found = try weights([event("a", ago: 1, tokens: TokenCounts(output: 1_000_000))], for: snapshot(resetsIn: 0, observedAgo: 600))
        #expect(found.afterSnapshot == 0)
    }

    @Test func weightsCountOnlyTheProviderAndTheIncludedSources() throws {
        let events = [
            event("claude", ago: 3_600, tokens: TokenCounts(output: 1_000_000)),
            event("pi", ago: 3_600, source: .pi, provider: "anthropic", tokens: TokenCounts(output: 2_000_000)),
            event("codex", ago: 3_600, source: .codex, provider: "openai", tokens: TokenCounts(output: 4_000_000)),
        ]
        #expect(abs(try weights(events).calibration - 60) < 1e-9)
        #expect(abs(try weights(events, includedSources: [.claudeCode]).calibration - 20) < 1e-9)
        #expect(try weights(events, includedSources: []).calibration == 0)
    }

    @Test func aScopedLimitCountsOnlyItsModel() throws {
        let found = try weights([
            event("haiku", ago: 3_600, model: "claude-haiku-5-5", tokens: TokenCounts(output: 2_000_000)),
            event("opus", ago: 3_600, tokens: TokenCounts(output: 1_000_000)),
        ], for: snapshot(.weekly, scope: "Haiku", resetsIn: 86_400))
        #expect(abs(found.calibration - 1) < 1e-9)
    }

    /// R7: the bands come from this table. Its threshold, 50,000, is not a bundled one, so a literal list could not price this.
    @Test func weightsPriceLongContextFromTheTablesThresholds() throws {
        let found = try weights([event("long", ago: 3_600, model: "claude-haiku-5-5", tokens: TokenCounts(input: 60_000))])
        #expect(abs(found.calibration - 0.03) < 1e-9)
    }

    @Test func anUnpricedEventBeforeTheWindowChangesNothing() throws {
        let found = try weights([
            event("priced", ago: 3_600, tokens: TokenCounts(output: 1_000_000)),
            event("earlier", ago: 7_201, model: "gemma4:12b", tokens: TokenCounts(input: 500_000)),
        ])
        expectClose(found, WindowWeights(calibration: 20, afterSnapshot: 0, recent: 0))
    }

    @Test func anUnpricedEventAfterTheSnapshotAlsoSwitchesToTokens() throws {
        let found = try weights([
            event("priced", ago: 3_600, tokens: TokenCounts(output: 1_000_000)),
            event("local", ago: 300, model: "gemma4:12b", tokens: TokenCounts(input: 500_000)),
        ])
        expectClose(found, WindowWeights(calibration: 1_000_000, afterSnapshot: 500_000, recent: 500_000))
    }

    @Test func anUnpricedEventInTheOldWindowAlsoSwitchesToTokens() throws {
        let found = try weights([
            event("old", ago: 5_000, model: "gemma4:12b", tokens: TokenCounts(input: 500_000)),
            event("new", ago: 300, tokens: TokenCounts(output: 1_000_000)),
        ], for: snapshot(resetsIn: -600, observedAgo: 4_000))
        expectClose(found, WindowWeights(calibration: 500_000, afterSnapshot: 1_000_000, recent: 1_000_000))
    }

    @Test func theTokenUnitKeepsTheFilter() throws {
        let found = try weights([
            event("local", ago: 3_600, model: "gemma4:12b", tokens: TokenCounts(input: 500_000)),
            event("other", ago: 3_600, source: .codex, provider: "openai", tokens: TokenCounts(input: 4_000_000)),
            event("left-out", ago: 3_600, source: .pi, provider: "anthropic", tokens: TokenCounts(input: 8_000_000)),
        ], includedSources: [.claudeCode, .codex])
        #expect(found.calibration == 500_000)
    }

    @Test func anEventWithoutAModelIsUnpriced() throws {
        let found = try weights([
            event("priced", ago: 3_600, tokens: TokenCounts(output: 1_000_000)),
            event("nameless", ago: 300, model: nil, tokens: TokenCounts(input: 500_000)),
        ])
        expectClose(found, WindowWeights(calibration: 1_000_000, afterSnapshot: 500_000, recent: 500_000))
    }

    /// A Codex event on a model with no price is no reason to change how an Anthropic limit is weighed.
    @Test func anUnpricedEventOfAnotherProviderChangesNothing() throws {
        let found = try weights([
            event("priced", ago: 3_600, tokens: TokenCounts(output: 1_000_000)),
            event("other", ago: 300, source: .codex, provider: "openai", model: "gemma4:12b", tokens: TokenCounts(input: 500_000)),
        ])
        expectClose(found, WindowWeights(calibration: 20, afterSnapshot: 0, recent: 0))
    }

    @Test func noEventsWeighNothing() throws {
        #expect(try weights([]) == WindowWeights(calibration: 0, afterSnapshot: 0, recent: 0))
    }
}
