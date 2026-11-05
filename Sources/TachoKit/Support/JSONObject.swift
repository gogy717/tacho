import Foundation
import os

/// A parsed JSON object, read by key path: `object.string("message", "usage", "speed")`.
///
/// A lookup is nil when a key on the path is missing or its value is of another JSON type. A boolean is not a number
/// and a number is not a boolean, so `true` is never read as `1`.
struct JSONObject {
    private let dictionary: [String: Any]

    /// nil unless `data` is one well-formed JSON object: an array or a scalar on the top level does not parse.
    init?(_ data: Data) {
        // What this parses is autoreleased, and a read of a whole file is one job: without a pool of its own it all stays until the end.
        guard let parsed = autoreleasepool(invoking: { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }) else { return nil }
        dictionary = parsed
    }

    init(_ dict: [String: Any]) {
        dictionary = dict
    }

    func string(_ path: String...) -> String? {
        lookup(path) as? String
    }

    /// A number with no fractional part that fits an `Int`.
    func int(_ path: String...) -> Int? {
        Self.number(lookup(path)).flatMap { Int(exactly: $0) }
    }

    func double(_ path: String...) -> Double? {
        Self.number(lookup(path))?.doubleValue
    }

    func bool(_ path: String...) -> Bool? {
        guard let number = lookup(path) as? NSNumber, Self.isBoolean(number) else { return nil }
        return number.boolValue
    }

    func object(_ path: String...) -> JSONObject? {
        (lookup(path) as? [String: Any]).map(JSONObject.init)
    }

    func array(_ path: String...) -> [Any]? {
        lookup(path) as? [Any]
    }

    /// A timestamp: an ISO-8601 string with a `Z` or `±hh:mm` zone and any number of fraction digits,
    /// or a number of epoch milliseconds (from 1e11 up) or of epoch seconds (below).
    func date(_ path: String...) -> Date? {
        let value = lookup(path)
        if let text = value as? String {
            return Self.timestamp(text)
        }
        guard let number = Self.number(value)?.doubleValue, number.isFinite else { return nil }
        return Date(timeIntervalSince1970: number >= 1e11 ? number / 1000 : number)
    }

    /// The value at `path`, nil when a key is missing or a step goes through something that is not an object. No path is the object itself.
    private func lookup(_ path: [String]) -> Any? {
        var current: Any = dictionary
        for key in path {
            guard let object = current as? [String: Any], let next = object[key] else { return nil }
            current = next
        }
        return current
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// `value` as a number that is not a boolean.
    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        return number
    }

    /// `text` as a date, nil when it is not an ISO-8601 timestamp with a zone.
    ///
    /// The formatter is handed a fraction of exactly three digits (padded with zeros or cut) and the digits cut off are added back as a Double,
    /// which keeps the microseconds of "2026-11-03T09:20:00.709695+00:00".
    private static func timestamp(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        let secondsEnd = 19 // after "YYYY-MM-DDTHH:MM:SS"
        guard bytes.count > secondsEnd, bytes[secondsEnd] == UInt8(ascii: ".") else {
            return TimestampFormatters.shared.withLockUnchecked { $0.seconds.date(from: text) }
        }

        let digitsStart = secondsEnd + 1
        var digitsEnd = digitsStart
        while digitsEnd < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[digitsEnd]) {
            digitsEnd += 1
        }
        guard digitsEnd > digitsStart else { return nil }

        let digits = String(decoding: bytes[digitsStart..<digitsEnd], as: UTF8.self)
        let milliseconds = digits.prefix(3) + String(repeating: "0", count: max(0, 3 - digits.count))
        let head = String(decoding: bytes[..<secondsEnd], as: UTF8.self)
        let zone = String(decoding: bytes[digitsEnd...], as: UTF8.self)
        guard let date = TimestampFormatters.shared.withLockUnchecked({ $0.milliseconds.date(from: "\(head).\(milliseconds)\(zone)") }) else {
            return nil
        }

        let dropped = digits.dropFirst(3)
        guard !dropped.isEmpty, let fraction = Double("0.\(dropped)") else { return date }
        return date.addingTimeInterval(fraction / 1000)
    }
}

/// The two formatters `JSONObject.date` needs. Creating an `ISO8601DateFormatter` is costly and it is not `Sendable`,
/// so one pair is shared and only used under the lock.
private struct TimestampFormatters {
    static let shared = OSAllocatedUnfairLock(uncheckedState: TimestampFormatters())

    /// "2026-11-03T09:20:00Z", "2026-11-03T14:50:00+05:30".
    let seconds = TimestampFormatters.formatter([.withInternetDateTime])
    /// The same with a fraction of exactly three digits: "2026-11-03T09:20:00.709Z".
    let milliseconds = TimestampFormatters.formatter([.withInternetDateTime, .withFractionalSeconds])

    private static func formatter(_ options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        return formatter
    }
}

/// Whether `data` contains the bytes of `needle`: a cheap test to run before a line is parsed as JSON.
func dataContains(_ data: Data, _ needle: StaticString) -> Bool {
    needle.withUTF8Buffer { pattern in
        guard !pattern.isEmpty else { return true }
        return data.withUnsafeBytes { haystack in
            haystack.count >= pattern.count && memmem(haystack.baseAddress, haystack.count, pattern.baseAddress, pattern.count) != nil
        }
    }
}
