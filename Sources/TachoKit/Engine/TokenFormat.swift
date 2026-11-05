import Foundation

/// The numbers as the interface shows them. Fixed formats, so that the same figure reads the same in every language.
public enum TokenFormat {
    private static let units = ["k", "M", "B"]

    /// `999`, `1.2k`, `123k`, `1.2M`, `2.5B`: one decimal below 100 of a unit, none above.
    public static func compact(_ n: Int) -> String {
        guard n >= 1_000 else { return String(n) }
        var scaled = Double(n) / 1_000
        var unit = 0
        while scaled.rounded() >= 1_000, unit < units.count - 1 {
            scaled /= 1_000
            unit += 1
        }
        return figure(scaled, decimalBelow: 100) + units[unit]
    }

    /// `12.4k/min`, or per second `207/s`, `0.5/s`. Per second is `perMinute` ÷ 60, so the two read the same on screen, even where the
    /// whole number of `perMinute` puts it a last digit from the window's exact figure.
    public static func rate(perMinute: Int, unit: RateUnit) -> String {
        switch unit {
        case .perMinute:
            return compact(perMinute) + "/min"
        case .perSecond:
            let perSecond = Double(perMinute) / 60
            guard perSecond.rounded() < 1_000 else { return compact(Int(perSecond.rounded())) + "/s" }
            return figure(perSecond, decimalBelow: 10) + "/s"
        }
    }

    /// `<$0.01`, `$0.83`, `$12`, `$1,235`: cents below ten dollars, none from there. For per-request costs in the log.
    public static func usd(_ amount: Double) -> String {
        money(amount, centsBelow: 10)
    }

    /// `$0.00`, `<$0.01`, `$0.62`, `$98.74`, `$375`, `$1,630`: cents below a hundred dollars, none from there. For a figure from a
    /// `CostSummary`.
    public static func usdFigure(_ amount: Double) -> String {
        money(amount, centsBelow: 100)
    }

    /// `$1.20/min`, `$14/min`, `<$0.01/min`, and `$1.20+/min` when `partial`: some models are left out. Always per minute, whatever
    /// the unit setting.
    public static func costRate(_ usdPerMinute: Double, partial: Bool = false) -> String {
        usd(usdPerMinute) + (partial ? "+" : "") + "/min"
    }

    /// The raw value says whether it is under a cent; the rest goes by the value rounded to cents, so 99.996 is `$100`.
    private static func money(_ amount: Double, centsBelow limit: Double) -> String {
        if amount > 0, amount < 0.01 { return "<$0.01" }
        if (amount * 100).rounded() < limit * 100 { return "$" + String(format: "%.2f", amount) }
        return "$" + amount.rounded().formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
    }

    /// `value` with one decimal, or none if it rounds to `limit` or more. Rounding comes first, so 99.95 is "100", not "100.0".
    private static func figure(_ value: Double, decimalBelow limit: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        return tenths < limit ? String(format: "%.1f", tenths) : String(Int(value.rounded()))
    }
}
