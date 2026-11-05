import Foundation
import SwiftUI
import Testing
@testable import Tacho

struct DesignGeometryTests {
    // The usual-range chart: spec §3.3.
    private func day() -> UsualRangeSeries {
        UsualRangeSeries(
            band: [.init(hour: 0, low: 0, high: 0), .init(hour: 12, low: 20, high: 60), .init(hour: 24, low: 40, high: 100)],
            line: [.init(hour: 0, value: 0), .init(hour: 6, value: 10), .init(hour: 12, value: 80)]
        )
    }

    @Test func theScaleCoversTheWholeDayWhateverTheHour() {
        // p75 at 24:00 is 100, so a morning at 80 sits low on the chart, and that is true.
        #expect(day().top == 105)
    }

    @Test func aDayAboveTheRangeSetsTheScale() {
        var series = day()
        series.line.append(.init(hour: 13, value: 400))
        #expect(series.top == 420)
    }

    @Test func aNewInstallIsScaledToItsLine() {
        let series = UsualRangeSeries(line: [.init(hour: 0, value: 0), .init(hour: 9, value: 5)])
        #expect(series.top == 5.25)
    }

    @Test func nothingAtAllStillHasAScale() {
        #expect(UsualRangeSeries().top > 0)
        #expect(UsualRangeSeries(line: [.init(hour: 9, value: 0)]).top > 0)
    }

    @Test func theDotIsWhereTheLineEnds() {
        #expect(day().now == .init(hour: 12, value: 80))
        #expect(UsualRangeSeries().now == nil)
    }

    // The needle: spec §3.1.
    @Test func theDomainKeepsTheBandInTheLeftHalf() {
        #expect(NeedleGeometry(value: 10, p25: 20, p75: 40, width: 52).domain == 80)
    }

    @Test func aHugeDaySqueezesTheBandAndKeepsTheNeedleOn() {
        let geometry = NeedleGeometry(value: 1_000, p25: 20, p75: 40, width: 52)
        #expect(geometry.domain == 1_150)
        #expect(geometry.needleRect.maxX <= 52)
        #expect(geometry.bandRect.maxX < 26)
    }

    @Test func aNarrowScaleHasFewerTicks() {
        #expect(NeedleGeometry(value: 1, p25: 1, p75: 2, width: 52).ticks == 11)
        #expect(NeedleGeometry(value: 1, p25: 1, p75: 2, width: 99).ticks == 11)
        #expect(NeedleGeometry(value: 1, p25: 1, p75: 2, width: 100).ticks == 21)
    }

    @Test func theBandAndNeedleSitWhereTheSpecPutsThem() {
        let geometry = NeedleGeometry(value: 40, p25: 20, p75: 40, width: 80)
        #expect(geometry.bandRect == CGRect(x: 20, y: 1, width: 20, height: 7))
        #expect(geometry.needleRect == CGRect(x: 39, y: 0, width: 2, height: 13))
    }

    @Test func aRangeOfOnePointIsStillSeen() {
        let geometry = NeedleGeometry(value: 10, p25: 20, p75: 20, width: 80)
        #expect(geometry.bandRect.width == 2)
    }

    @Test func reduceMotionDropsTheMotion() {
        #expect(Theme.motion(.easeOut(duration: 0.25), reduceMotion: true) == nil)
        #expect(Theme.motion(.easeOut(duration: 0.25), reduceMotion: false) == .easeOut(duration: 0.25))
    }

    @Test func nothingYetIsTicksOnly() {
        #expect(!NeedleGeometry(value: 0, p25: 0, p75: 0, width: 80).hasMarks)
        #expect(NeedleGeometry(value: 1, p25: 0, p75: 0, width: 80).hasMarks)
    }

    @Test func aThinBandIsNeverNarrowerThanTwoPoints() {
        let geometry = NeedleGeometry(value: 10_000, p25: 20, p75: 21, width: 80)
        #expect(geometry.bandRect.width == 2)
    }
}
