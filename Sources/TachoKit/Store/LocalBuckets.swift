import Foundation

/// Sorts quarter-hour groups into the user's calendar.
///
/// The store groups by UTC quarter hour because that is as coarse as it can go without knowing the time zone: every UTC offset
/// and DST change in use falls on a quarter hour (India +05:30, Nepal +05:45), so no group straddles a local day or hour.
public enum LocalBuckets {
    /// The groups of each local day, keyed by `calendar.startOfDay`.
    public static func days(_ groups: [QuarterHourGroup], calendar: Calendar) -> [Date: [PricingGroup]] {
        var days: [Date: [PricingGroup]] = [:]
        for group in groups {
            days[calendar.startOfDay(for: group.start), default: []].append(group.group)
        }
        return days
    }

    /// The groups of each local day in its 96 quarter hours by the clock, keyed by `calendar.startOfDay`. The day of a clock change
    /// keeps its 96 too: an hour that happens twice adds to its slots, and one that never happens leaves them empty.
    public static func quarterHours(_ groups: [QuarterHourGroup], calendar: Calendar) -> [Date: [[PricingGroup]]] {
        var days: [Date: [[PricingGroup]]] = [:]
        for group in groups {
            let local = calendar.dateComponents([.hour, .minute], from: group.start)
            guard let hour = local.hour, let minute = local.minute else { continue }
            days[calendar.startOfDay(for: group.start), default: Array(repeating: [], count: 96)][hour * 4 + minute / 15].append(group.group)
        }
        return days
    }

    /// Total tokens by local weekday and hour: 7 rows of 24, row 0 being `calendar.firstWeekday`.
    public static func hourOfWeek(_ groups: [QuarterHourGroup], calendar: Calendar) -> [[Int]] {
        var cells = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 7)
        for group in groups {
            let local = calendar.dateComponents([.weekday, .hour], from: group.start)
            guard let weekday = local.weekday, let hour = local.hour else { continue }
            cells[(weekday - calendar.firstWeekday + 7) % 7][hour] += group.group.tokens.total
        }
        return cells
    }
}
