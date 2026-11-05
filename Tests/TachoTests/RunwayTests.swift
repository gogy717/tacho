import Foundation
import Testing
@testable import Tacho
import TachoKit

/// What the runway draws: spec section 12.5.
struct RunwayTests {
    private let now = WindowSamples.now

    @Test func theLineRunsFromTheWindowsStartThroughEveryReadingToNow() {
        let quota = WindowSamples.projection(percent: 64)
        let readings = [LimitHistory.Reading(time: now - 3_000, percent: 20), .init(time: now - 1_000, percent: 50)]
        let runway = Runway(quota, history: readings, now: now)
        #expect(runway.used.map(\.percent) == [0, 20, 50, 64])
        #expect(runway.used.first?.time == quota.resetsAt.addingTimeInterval(-quota.snapshot.window.length))
        #expect(runway.used.last?.time == now)
        #expect(runway.hasReadings)
    }

    @Test func withNoReadingsItMakesNoClaimAboutWhenTheUseCame() {
        // Steps from 0 would put all of it at this moment.
        let runway = Runway(WindowSamples.projection(percent: 64), now: now)
        #expect(runway.used.map(\.percent) == [0, 64])
        #expect(!runway.hasReadings)
    }

    @Test func runningOutShowsWhen() {
        let at = now + 4_200
        let runway = Runway(WindowSamples.projection(percent: 64, outcome: .runsOut(at: at, beforeReset: 5_100)), now: now)
        #expect(runway.forecast == .empties(at: at))
    }

    @Test func lastingShowsWhereItEndsUp() {
        let quota = WindowSamples.projection(percent: 40, outcome: .lastsUntilReset, recentPerHour: 4)
        // 9,300 s to the reset, at 4% an hour.
        #expect(Runway(quota, now: now).forecast == .reaches(percent: 40 + 4 * 9_300 / 3_600))
    }

    @Test func aWindowAverageForecastUsesThatPace() {
        let quota = WindowSamples.projection(percent: 40, outcome: .lastsUntilReset, method: .windowAverage, windowPerHour: 2)
        #expect(Runway(quota, now: now).forecast == .reaches(percent: 40 + 2 * 9_300 / 3_600))
    }

    @Test func noForecastEverPassesAHundred() {
        let quota = WindowSamples.projection(percent: 90, outcome: .lastsUntilReset, recentPerHour: 50)
        #expect(Runway(quota, now: now).forecast == .reaches(percent: 100))
    }

    @Test(arguments: [Projection.Outcome.idle, .unknown])
    func nothingToForecastDrawsNoForecast(outcome: Projection.Outcome) {
        #expect(Runway(WindowSamples.projection(percent: 40, outcome: outcome, recentPerHour: 4), now: now).forecast == .none)
    }

    @Test func usedUpHasNoForecast() {
        let quota = WindowSamples.projection(percent: 100, outcome: .runsOut(at: now, beforeReset: 9_300))
        #expect(Runway(quota, now: now).forecast == .none)
    }
}
