import Foundation

/// One local day, cumulative at the end of each of its 96 quarter hours: direction B, section 8.1.
public struct DayCurve: Equatable, Sendable {
    public static let quarterHours = 96

    public var day: Date
    /// Priced tokens only.
    public var cost: [Double]
    public var output: [Double]
    public var tokens: [Double]

    /// `groups` are the day's 96 quarter hours, as `LocalBuckets.quarterHours` gives them.
    public init(day: Date, quarterHours groups: [[PricingGroup]], prices: PriceTable) {
        self.day = day
        cost = []
        output = []
        tokens = []
        var usd = 0.0
        var counts = TokenCounts.zero
        for slot in groups {
            usd += prices.cost(of: slot).usd
            counts = slot.reduce(counts) { $0 + $1.tokens }
            cost.append(usd)
            output.append(Double(counts.output))
            tokens.append(Double(counts.total))
        }
    }

    /// Where `values` stood `fraction` through the day: at the quarter hour containing it, by how much of that quarter has gone.
    public static func value(of values: [Double], at fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let position = min(max(fraction, 0), 1) * Double(values.count)
        let slot = min(Int(position), values.count - 1)
        let before = slot > 0 ? values[slot - 1] : 0
        return before + (values[slot] - before) * (position - Double(slot))
    }

    /// How far through its local day `date` is, 0 to 1, by the clock. Quarter hours go by the clock too, so noon lines up with noon
    /// on the day of a clock change, whatever the hours since midnight.
    public static func fraction(of date: Date, calendar: Calendar) -> Double {
        let clock = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let seconds = Double(clock.hour ?? 0) * 3_600 + Double(clock.minute ?? 0) * 60 + Double(clock.second ?? 0)
        return (seconds + Double(clock.nanosecond ?? 0) / 1_000_000_000) / 86_400
    }
}
