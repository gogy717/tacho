import Foundation
import Observation
import Testing
@testable import Tacho

/// Cost's rate reaches the page apart from the rest of it, by a place held in the stats.
@MainActor
struct RangeRateTests {
    private final class Flag: @unchecked Sendable {
        var isSet = false
    }

    private let now = String(localized: "stat.now", bundle: .tacho)

    private func stats() -> [Stat] {
        [Stat(label: "Total", value: "$12"), Stat(label: now, value: RangeRate.place), Stat(label: "Usual", value: "")]
    }

    @Test func theWordsGoInTheRatesPlace() {
        let rate = RangeRate()
        rate.take("$1.20/min")
        #expect(rate.filling(stats()).map(\.value) == ["$12", "$1.20/min", ""])
    }

    /// With no figures there is no rate to give, and the page has never said it was empty.
    @Test func withNoWordsThePlaceGoes() {
        #expect(RangeRate().filling(stats()).map(\.label) == ["Total", "Usual"])
    }

    /// A stat with nothing to say is not the rate.
    @Test func anEmptyStatIsLeftAlone() {
        let rate = RangeRate()
        rate.take("$1.20/min")
        #expect(rate.filling(stats()).last?.value == "")
    }

    @Test func theSameWordsTellNoOne() {
        let rate = RangeRate()
        rate.take("$1.20/min")
        let flag = Flag()
        withObservationTracking { _ = rate.words } onChange: { flag.isSet = true }
        rate.take("$1.20/min")
        #expect(!flag.isSet)
    }

    @Test func otherWordsTellTheStats() {
        let rate = RangeRate()
        rate.take("$1.20/min")
        let flag = Flag()
        withObservationTracking { _ = rate.words } onChange: { flag.isSet = true }
        rate.take("$1.30/min")
        #expect(flag.isSet)
    }
}
