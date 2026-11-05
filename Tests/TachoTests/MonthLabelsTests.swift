import AppKit
import Foundation
import Testing
@testable import Tacho
import TachoKit

/// Charts cuts a label short at the plot's edge, so a month that starts in the last columns read `…`, as November does this week.
struct MonthLabelsTests {
    private let columns = 53

    private func calendar(_ locale: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: locale)
        return calendar
    }

    /// The last 365 days to `end`.
    private func days(to end: Date, _ calendar: Calendar) -> [DayCell] {
        (0..<365).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: end).map { DayCell(day: $0, tokens: 1, costUSD: 0) }
        }
    }

    private func offset(_ days: [DayCell], _ calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: days[0].day) - calendar.firstWeekday + 7) % 7
    }

    private func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
    }

    /// One column at the narrowest: a minimum window, less the sidebar, the page's inset and the row labels.
    private let narrowest: CGFloat = (820 - 201 - 40 - 30) / 53

    @Test(arguments: ["en_US", "en_AU", "zh_Hans_AU"])
    func everyMonthHasRoomForItsName(locale: String) throws {
        let calendar = calendar(locale)
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        // Every end of a year's window, so every position a month can start in.
        for dayOfYear in 0..<365 {
            let end = try #require(calendar.date(byAdding: .day, value: dayOfYear, to: start))
            let days = days(to: end, calendar)
            for label in MonthLabels.of(days, offset: offset(days, calendar), columns: columns, calendar: calendar) {
                let room = (Double(columns) - label.column) * narrowest
                #expect(width(label.text) <= room, "\(label.text) at column \(label.column), to \(end)")
            }
        }
    }

    @Test func aMonthWellInsideStaysAboveTheWeekItStartsIn() throws {
        let calendar = calendar("en_US")
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))
        let days = days(to: end, calendar)
        let offset = offset(days, calendar)
        let labels = MonthLabels.of(days, offset: offset, columns: columns, calendar: calendar)
        let june = try #require(labels.first { $0.text == "Jun" })
        let first = try #require(days.firstIndex { calendar.component(.month, from: $0.day) == 6 && calendar.component(.day, from: $0.day) == 1 })
        #expect(june.column == Double((first + offset) / 7))
    }

    @Test func labelsNeverCrossEachOther() throws {
        let calendar = calendar("en_US")
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))
        let days = days(to: end, calendar)
        let columns = MonthLabels.of(days, offset: offset(days, calendar), columns: self.columns, calendar: calendar).map(\.column)
        #expect(columns == columns.sorted())
        #expect(Set(columns).count == columns.count)
    }
}
