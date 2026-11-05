import Foundation
import Testing
@testable import Tacho
import TachoKit

/// What a tick moves, and what it leaves. Whatever reads `dashboard` is redrawn when it is assigned, so a tick with nothing to show
/// must not assign it; and whatever reads `pageClock` is redrawn when it moves, so that must move no oftener than a page can say.
@MainActor @Suite(.serialized)
struct TickTests {
    private static let start = WindowSamples.now

    private func model(_ sandbox: Sandbox) -> AppModel {
        AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in }
    }

    private func forecast(_ seconds: TimeInterval, percent: Double = 64) -> Projection {
        WindowSamples.projection(percent: percent, outcome: .runsOut(at: Self.start + 4_200 + seconds, beforeReset: 5_100 - seconds))
    }

    private func figures(_ quotas: [Projection], usd: Double = 1) -> Dashboard {
        WindowSamples.dashboard(quotas: quotas, usd: usd)
    }

    // MARK: Forecasts

    @Test func aForecastThatOnlySlidesIsNotAChange() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        let first = figures([forecast(0)])
        model.tick(first, at: Self.start)
        for second in 1...59 {
            model.tick(figures([forecast(Double(second))]), at: Self.start + Double(second))
        }
        #expect(model.dashboard == first)
    }

    /// Real figures have several limits, and one left to slide would make every tick a change again.
    @Test func forecastsThatOnlySlideTogetherAreNotAChange() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        func both(_ seconds: TimeInterval) -> Dashboard {
            let weekly = WindowSamples.projection(
                window: .weekly,
                percent: 41,
                outcome: .runsOut(at: Self.start + 9_000 + seconds, beforeReset: 300 - seconds)
            )
            return figures([forecast(seconds), weekly])
        }
        let first = both(0)
        model.tick(first, at: Self.start)
        for second in 1...59 {
            model.tick(both(Double(second)), at: Self.start + Double(second))
        }
        #expect(model.dashboard == first)
    }

    @Test func aForecastIsNeverAMinuteBehind() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        model.tick(figures([forecast(0)]), at: Self.start)
        for second in 1...600 {
            let latest = forecast(Double(second))
            model.tick(figures([latest]), at: Self.start + Double(second))
            guard case .runsOut(let at, _) = latest.outcome, case .runsOut(let shown, _)? = model.dashboard?.quotas.first?.outcome else {
                Issue.record("no forecast")
                return
            }
            #expect(at.timeIntervalSince(shown) < 60)
        }
    }

    @Test func anythingElseIsTakenAtOnce() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        model.tick(figures([forecast(0)]), at: Self.start)
        model.tick(figures([forecast(1)], usd: 2), at: Self.start + 1)
        #expect(model.dashboard?.today.cost.usd == 2)
    }

    /// Only the moment waits. What else the limit says comes through with the tick, though its forecast has barely moved.
    @Test func aPercentThatMovesIsTakenWithAForecastThatDoesNot() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        model.tick(figures([forecast(0)]), at: Self.start)
        var higher = forecast(1)
        higher.estimatedPercent = 70
        model.tick(figures([higher]), at: Self.start + 1)
        #expect(model.dashboard?.quotas.first?.estimatedPercent == 70)
        #expect(model.dashboard?.quotas.first?.outcome == forecast(0).outcome)
    }

    @Test func aForecastThatMovesAMinuteIsTakenAtOnce() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        model.tick(figures([forecast(0)]), at: Self.start)
        let later = figures([forecast(60)])
        model.tick(later, at: Self.start + 1)
        #expect(model.dashboard == later)
    }

    @Test func aForecastThatMovesBackIsTreatedTheSame() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        model.tick(figures([forecast(0)]), at: Self.start)
        let sooner = figures([forecast(-60)])
        model.tick(sooner, at: Self.start + 1)
        #expect(model.dashboard == sooner)
    }

    @Test func aForecastThatEndsIsTakenAtOnce() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        model.tick(figures([forecast(0)]), at: Self.start)
        let safe = figures([WindowSamples.projection(percent: 64)])
        model.tick(safe, at: Self.start + 1)
        #expect(model.dashboard == safe)
    }

    @Test func aForecastThatBeginsIsTakenAtOnce() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        model.tick(figures([WindowSamples.projection(percent: 64)]), at: Self.start)
        let burning = figures([forecast(0)])
        model.tick(burning, at: Self.start + 1)
        #expect(model.dashboard == burning)
    }

    /// Another limit's forecast is not this one's, however close the two moments are.
    @Test func aForecastIsNotCarriedToAnotherLimit() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        model.tick(figures([forecast(0)]), at: Self.start)
        var other = forecast(1)
        other.snapshot.usedPercent = 70
        let latest = figures([other])
        model.tick(latest, at: Self.start + 1)
        #expect(model.dashboard == latest)
    }

    /// Across a reset `beforeReset` means another window, though the snapshot is the same and the moment has hardly moved.
    @Test func aForecastIsNotCarriedAcrossAReset() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        model.tick(figures([forecast(0)]), at: Self.start)
        var after = forecast(1)
        after.resetsAt += after.snapshot.window.length
        after.outcome = .runsOut(at: Self.start + 4_201, beforeReset: 17_963)
        let latest = figures([after])
        model.tick(latest, at: Self.start + 1)
        #expect(model.dashboard == latest)
    }

    @Test func aLimitThatComesOrGoesIsTakenAtOnce() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        let weekly = WindowSamples.projection(window: .weekly, percent: 41)
        model.tick(figures([forecast(0)]), at: Self.start)
        let more = figures([forecast(1), weekly])
        model.tick(more, at: Self.start + 1)
        #expect(model.dashboard == more)
        let fewer = figures([weekly])
        model.tick(fewer, at: Self.start + 2)
        #expect(model.dashboard == fewer)
    }

    /// Each limit's forecast holds or moves on its own.
    @Test func forecastsSettleOneByOne() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        func weekly(_ seconds: TimeInterval) -> Projection {
            WindowSamples.projection(window: .weekly, percent: 41, outcome: .runsOut(at: Self.start + 9_000 + seconds, beforeReset: 300 - seconds))
        }
        model.tick(figures([forecast(0), weekly(0)]), at: Self.start)
        model.tick(figures([forecast(1), weekly(90)]), at: Self.start + 1)
        #expect(model.dashboard?.quotas.map(\.outcome) == [forecast(0).outcome, weekly(90).outcome])
    }

    // MARK: What the pages take from a tick

    @Test func theLogsAreBeingReadUntilTheFiguresSayNot() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        #expect(model.isReadingLogs)
        var reading = figures([])
        reading.progress.phase = .history
        model.tick(reading, at: Self.start)
        #expect(model.isReadingLogs)
        model.tick(figures([]), at: Self.start + 1)
        #expect(!model.isReadingLogs)
    }

    /// As `dashboard?.progress.phase != .live` said it.
    @Test func withNoFiguresTheLogsCountAsBeingRead() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        model.tick(figures([]), at: Self.start)
        model.tickFailed(at: Self.start + 1)
        #expect(model.dashboard == nil)
        #expect(model.isReadingLogs)
        #expect(model.isFailing)
    }

    @Test func aFailedReadStillMovesTheClocks() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        let minute = Date(timeIntervalSinceReferenceDate: 60_000_000)
        model.tick(figures([]), at: minute)
        model.tickFailed(at: minute + 61)
        #expect(model.refreshedAt == minute + 61)
        #expect(model.pageClock == minute + 61)
    }

    /// A look at this has nothing to see, and a page spares itself building a state to compare.
    @Test func aTickThatChangesNothingMovesNoInputOfAPage() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        let minute = Date(timeIntervalSinceReferenceDate: 60_000_000)
        model.tick(figures([]), at: minute)
        let before = model.pageInputs
        model.tick(figures([]), at: minute + 1)
        #expect(model.pageInputs == before)
    }

    @Test func newFiguresMoveAnInputOfAPage() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        let minute = Date(timeIntervalSinceReferenceDate: 60_000_000)
        model.tick(figures([]), at: minute)
        let before = model.pageInputs
        model.tick(figures([], usd: 2), at: minute + 1)
        #expect(model.pageInputs > before)
    }

    @Test func theNextMinuteMovesAnInputOfAPage() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        let minute = Date(timeIntervalSinceReferenceDate: 60_000_000)
        model.tick(figures([]), at: minute)
        let before = model.pageInputs
        model.tick(figures([]), at: minute + 60)
        #expect(model.pageInputs > before)
    }

    @Test func aFailedReadMovesAnInputOfAPage() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        model.tick(figures([]), at: Self.start)
        let before = model.pageInputs
        model.tickFailed(at: Self.start + 1)
        #expect(model.pageInputs > before)
    }

    @Test func theMenuBarBeingBlockedMovesAnInputOfAPage() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        let before = model.pageInputs
        model.menuBarBlocked = true
        #expect(model.pageInputs > before)
    }

    @Test func aLookIsDueOnceForEachMove() {
        let looks = PageLook()
        #expect(looks.isDue(0))
        #expect(!looks.isDue(0))
        #expect(looks.isDue(1))
        #expect(!looks.isDue(1))
    }

    // MARK: The pages' clock

    @Test func thePagesClockHoldsThroughAMinute() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        let minute = Date(timeIntervalSinceReferenceDate: 60_000_000)
        model.tick(figures([]), at: minute)
        for second in 1...59 {
            model.tick(figures([]), at: minute + Double(second))
        }
        #expect(model.pageClock == minute)
        #expect(model.refreshedAt == minute + 59)
    }

    @Test func thePagesClockMovesWithTheFirstTickOfTheNextMinute() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        let minute = Date(timeIntervalSinceReferenceDate: 60_000_000)
        model.tick(figures([]), at: minute + 30)
        model.tick(figures([]), at: minute + 59.9)
        #expect(model.pageClock == minute + 30)
        model.tick(figures([]), at: minute + 60.4)
        #expect(model.pageClock == minute + 60.4)
    }

    /// The requirement: a relative time on a page may not visibly lag by more than a minute. With a tick a second, and one a second late.
    @Test func thePagesClockIsNeverMoreThanAMinuteAndATickBehind() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        var now = Date(timeIntervalSinceReferenceDate: 60_000_000.25)
        for tick in 0..<600 {
            now += tick % 7 == 0 ? 2 : 1
            model.tick(figures([]), at: now)
            #expect(now.timeIntervalSince(model.pageClock) <= 62)
        }
    }

    /// Set back, by hand or by the network, it must not wait for the old time to come round again.
    @Test func thePagesClockFollowsAClockSetBack() throws {
        let sandbox = try Sandbox()
        let model = model(sandbox)
        let minute = Date(timeIntervalSinceReferenceDate: 60_000_000)
        model.tick(figures([]), at: minute)
        model.tick(figures([]), at: minute - 3_600)
        #expect(model.pageClock == minute - 3_600)
    }
}
