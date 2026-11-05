import TachoKit
import Testing

struct TokenFormatTests {
    @Test func compactCounts() {
        #expect(TokenFormat.compact(999) == "999")
        #expect(TokenFormat.compact(1_234) == "1.2k")
        #expect(TokenFormat.compact(12_400) == "12.4k")
        #expect(TokenFormat.compact(123_456) == "123k")
        #expect(TokenFormat.compact(1_234_567) == "1.2M")
        #expect(TokenFormat.compact(12_345_678) == "12.3M")
        #expect(TokenFormat.compact(2_500_000_000) == "2.5B")
    }

    @Test func compactStartsAtAThousand() {
        #expect(TokenFormat.compact(0) == "0")
        #expect(TokenFormat.compact(1_000) == "1.0k")
    }

    /// Rounding decides the unit and the decimals, never the other way round: not "100.0k", and not "1000k".
    @Test func compactRollsOverWhenRoundingReachesTheNextStep() {
        #expect(TokenFormat.compact(99_940) == "99.9k")
        #expect(TokenFormat.compact(99_950) == "100k")
        #expect(TokenFormat.compact(999_499) == "999k")
        #expect(TokenFormat.compact(999_500) == "1.0M")
        #expect(TokenFormat.compact(999_950) == "1.0M")
        #expect(TokenFormat.compact(999_500_000) == "1.0B")
    }

    @Test func compactRoundsHalvesUp() {
        #expect(TokenFormat.compact(124_500) == "125k")
    }

    /// Nothing above billions, so a very large count stays in them.
    @Test func compactStopsAtBillions() {
        #expect(TokenFormat.compact(2_500_000_000_000) == "2500B")
    }

    @Test func ratePerMinute() {
        #expect(TokenFormat.rate(perMinute: 12_400, unit: .perMinute) == "12.4k/min")
        #expect(TokenFormat.rate(perMinute: 999, unit: .perMinute) == "999/min")
    }

    @Test func ratePerSecond() {
        #expect(TokenFormat.rate(perMinute: 12_400, unit: .perSecond) == "207/s")
        #expect(TokenFormat.rate(perMinute: 30, unit: .perSecond) == "0.5/s")
    }

    @Test func ratePerSecondKeepsADecimalBelowTen() {
        #expect(TokenFormat.rate(perMinute: 594, unit: .perSecond) == "9.9/s")
        #expect(TokenFormat.rate(perMinute: 598, unit: .perSecond) == "10/s")
    }

    @Test func ratePerSecondIsCompactWhenLarge() {
        #expect(TokenFormat.rate(perMinute: 90_000, unit: .perSecond) == "1.5k/s")
    }

    @Test func usdAmounts() {
        #expect(TokenFormat.usd(0.004) == "<$0.01")
        #expect(TokenFormat.usd(0.83) == "$0.83")
        #expect(TokenFormat.usd(12.4) == "$12")
        #expect(TokenFormat.usd(1_234.5) == "$1,235")
    }

    /// Nothing spent is not the same as less than a cent.
    @Test func usdOfNothing() {
        #expect(TokenFormat.usd(0) == "$0.00")
    }

    @Test func usdAroundACent() {
        #expect(TokenFormat.usd(0.0099) == "<$0.01")
        #expect(TokenFormat.usd(0.01) == "$0.01")
    }

    @Test func usdDropsTheCentsFromTenDollars() {
        #expect(TokenFormat.usd(9.99) == "$9.99")
        #expect(TokenFormat.usd(9.996) == "$10")
        #expect(TokenFormat.usd(10) == "$10")
    }

    @Test func usdGroupsThousands() {
        #expect(TokenFormat.usd(1_000_000) == "$1,000,000")
    }

    @Test func costRateIsAlwaysPerMinute() {
        #expect(TokenFormat.costRate(1.2) == "$1.20/min")
        #expect(TokenFormat.costRate(0) == "$0.00/min")
        #expect(TokenFormat.costRate(9.99) == "$9.99/min")
        #expect(TokenFormat.costRate(14.4) == "$14/min")
        #expect(TokenFormat.costRate(1_234.5) == "$1,235/min")
    }

    /// The raw value says whether it is under a cent, and the rest goes by the value rounded to cents.
    @Test func costRateTestsTheRawValueThenTheCents() {
        #expect(TokenFormat.costRate(0.004) == "<$0.01/min")
        #expect(TokenFormat.costRate(0.0099) == "<$0.01/min")
        #expect(TokenFormat.costRate(0.01) == "$0.01/min")
        #expect(TokenFormat.costRate(9.994) == "$9.99/min")
        #expect(TokenFormat.costRate(9.996) == "$10/min")
    }

    @Test func aPartialCostRateHasAPlusBeforeTheSlash() {
        #expect(TokenFormat.costRate(1.2, partial: true) == "$1.20+/min")
        #expect(TokenFormat.costRate(0.004, partial: true) == "<$0.01+/min")
        #expect(TokenFormat.costRate(14.4, partial: true) == "$14+/min")
    }

    @Test func usdFigureKeepsCentsBelowOneHundredDollars() {
        #expect(TokenFormat.usdFigure(0) == "$0.00")
        #expect(TokenFormat.usdFigure(0.62) == "$0.62")
        #expect(TokenFormat.usdFigure(12.3) == "$12.30")
        #expect(TokenFormat.usdFigure(98.74) == "$98.74")
    }

    @Test func usdFigureDropsCentsFromOneHundredDollars() {
        #expect(TokenFormat.usdFigure(375) == "$375")
        #expect(TokenFormat.usdFigure(374.6) == "$375")
        #expect(TokenFormat.usdFigure(1_630) == "$1,630")
        #expect(TokenFormat.usdFigure(1_234_567) == "$1,234,567")
    }

    @Test func usdFigureTestsTheRawValueThenTheCents() {
        #expect(TokenFormat.usdFigure(0.004) == "<$0.01")
        #expect(TokenFormat.usdFigure(0.01) == "$0.01")
        #expect(TokenFormat.usdFigure(99.994) == "$99.99")
        #expect(TokenFormat.usdFigure(99.996) == "$100")
    }

    /// `usd` stays as it was, for per-request costs in the log.
    @Test func usdStillDropsCentsFromTenDollars() {
        #expect(TokenFormat.usd(12.3) == "$12")
        #expect(TokenFormat.usd(9.99) == "$9.99")
    }
}
