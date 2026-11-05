import Foundation
import GRDB

/// A span of time: `start` is in it, `end` is not.
public struct TimeRange: Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// Which events a query counts. A field left nil does not narrow them; an empty set matches nothing.
public struct EventFilter: Equatable, Sendable {
    public var sources: Set<Source>?
    public var projects: Set<String>?
    public var models: Set<String>?
    /// A substring of the project or the model. Ignores case for ASCII letters, as SQLite's `lower` does. Empty means no search.
    public var search: String?
    /// The events `QuotaAttribution` gives to this provider.
    public var quotaProvider: QuotaProvider?
    /// A substring of the model, for model-scoped limits. Ignores case like `search`. Empty means no condition.
    public var modelContains: String?
    /// Only what a sub-agent did, or only what it did not.
    public var isSubagent: Bool?
    public var sessionId: String?
    /// Only this machine. The live rate sets it. Totals, cost, heatmaps and groupings leave it nil and count every machine.
    public var machine: String?

    public init(
        sources: Set<Source>? = nil,
        projects: Set<String>? = nil,
        models: Set<String>? = nil,
        search: String? = nil,
        quotaProvider: QuotaProvider? = nil,
        modelContains: String? = nil,
        isSubagent: Bool? = nil,
        sessionId: String? = nil,
        machine: String? = nil
    ) {
        self.sources = sources
        self.projects = projects
        self.models = models
        self.search = search
        self.quotaProvider = quotaProvider
        self.modelContains = modelContains
        self.isSubagent = isSubagent
        self.sessionId = sessionId
        self.machine = machine
    }

    public static let all = EventFilter()
}

/// What a range of rows adds up to. Different means they changed; the same is as good as unchanged, since a row that moved or was
/// rewritten changes a sum, and reading a log again writes what was there. Whole numbers, so that it does not depend on row order.
struct RowsFingerprint: Equatable, Sendable {
    var rows: Int
    /// How far into the range the rows are, added up. From its start and not from 1970, or a few million rows would overflow.
    var milliseconds: Int
    var tokens: TokenCounts
}

/// The tokens of one client of a source.
public struct SourceClientTokens: Equatable, Sendable {
    public var source: Source
    public var client: String?
    public var tokens: TokenCounts
    /// The time of the client's latest event in the range.
    public var lastTime: Date

    public init(source: Source, client: String?, tokens: TokenCounts, lastTime: Date) {
        self.source = source
        self.client = client
        self.tokens = tokens
        self.lastTime = lastTime
    }
}

/// A pricing group within one quarter hour.
public struct QuarterHourGroup: Equatable, Sendable {
    /// Aligned to 900 s in UTC.
    public var start: Date
    public var group: PricingGroup

    public init(start: Date, group: PricingGroup) {
        self.start = start
        self.group = group
    }
}

/// What one request says about generation speed.
public struct SpeedSample: Equatable, Sendable {
    public var model: String
    public var output: Int
    public var generationMs: Double?
    public var startTime: Date?
    public var time: Date

    public init(model: String, output: Int, generationMs: Double?, startTime: Date?, time: Date) {
        self.model = model
        self.output = output
        self.generationMs = generationMs
        self.startTime = startTime
        self.time = time
    }
}

/// What a breakdown groups by.
public enum Dimension: Sendable {
    case source, model, project

    fileprivate var column: String {
        switch self {
        case .source: "source"
        case .model: "model"
        case .project: "project"
        }
    }
}

extension EventStore {
    /// The tokens of the events in `range` that pass `filter`.
    public func tokens(in range: TimeRange, filter: EventFilter = .all) throws -> TokenCounts {
        let selection = Selection(range: range, filter: filter)
        return try reader.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT \(tokenSums) FROM event \(selection.clause)", arguments: selection.arguments)
            return row.map { TokenCounts($0) } ?? .zero
        }
    }

    /// The tokens in `range` of every client of every source.
    public func tokensBySourceAndClient(in range: TimeRange, filter: EventFilter = .all) throws -> [SourceClientTokens] {
        let selection = Selection(range: range, filter: filter)
        let rows = try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source, client, MAX(time) AS lastTime, \(tokenSums)
                FROM event \(selection.clause)
                GROUP BY source, client
                """, arguments: selection.arguments)
        }
        return rows.compactMap { row in
            Source(rawValue: row["source"]).map { source in
                SourceClientTokens(
                    source: source,
                    client: row["client"],
                    tokens: TokenCounts(row),
                    lastTime: Date(timeIntervalSince1970: row["lastTime"])
                )
            }
        }
    }

    /// The events of each of the last `minutes` wall-clock minutes, oldest first, summed by everything that changes their price: a
    /// minute's tokens and its dollars from one query. The last entry is the minute `now` is in, up to `now`.
    ///
    /// Minutes are counted in UTC: every UTC offset in use is a whole number of minutes, so they are the local ones too.
    public func minuteGroups(endingAt now: Date, minutes: Int = 60, filter: EventFilter = .all, thresholds: [Int]) throws -> [[PricingGroup]] {
        guard minutes > 0 else { return [] }
        let end = now.timeIntervalSince1970
        let start = ((end / 60).rounded(.down) - Double(minutes - 1)) * 60
        var selection = Selection(filter: filter)
        selection.add("time >= ? AND time <= ?", [start, end])
        let rows = try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT CAST((time - ?) / 60 AS INTEGER) AS minute, model, speed, geo, \(promptBand(thresholds)) AS band, \(tokenSums)
                FROM event \(selection.clause)
                GROUP BY minute, model, speed, geo, band
                """, arguments: [start] + selection.arguments)
        }
        var groups = [[PricingGroup]](repeating: [], count: minutes)
        for row in rows {
            groups[row["minute"]].append(PricingGroup(row))
        }
        return groups
    }

    /// The events in `range` that pass `filter`, summed by everything that changes their price.
    ///
    /// `thresholds` are the effective price table's `longContextThresholds`, ascending.
    public func pricingGroups(in range: TimeRange, filter: EventFilter = .all, thresholds: [Int]) throws -> [PricingGroup] {
        let selection = Selection(range: range, filter: filter)
        let rows = try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT model, speed, geo, \(promptBand(thresholds)) AS band, \(tokenSums)
                FROM event \(selection.clause)
                GROUP BY model, speed, geo, band
                """, arguments: selection.arguments)
        }
        return rows.map { PricingGroup($0) }
    }

    /// `pricingGroups` for each UTC quarter hour, for `LocalBuckets` to sort into the user's calendar.
    public func quarterHourGroups(in range: TimeRange, filter: EventFilter = .all, thresholds: [Int]) throws -> [QuarterHourGroup] {
        let selection = Selection(range: range, filter: filter)
        return try reader.read { db in
            // A cursor, here and in `speedSamples`: these answers run to tens of thousands of rows, and `fetchAll` holds them all twice.
            try Array(Row.fetchCursor(db, sql: """
                SELECT CAST(time / 900 AS INTEGER) * 900 AS quarterHour, model, speed, geo, \(promptBand(thresholds)) AS band, \(tokenSums)
                FROM event \(selection.clause)
                GROUP BY quarterHour, model, speed, geo, band
                """, arguments: selection.arguments).map {
                    QuarterHourGroup(start: Date(timeIntervalSince1970: $0["quarterHour"]), group: PricingGroup($0))
                })
        }
    }

    /// `quarterHourGroups` with the source of each, by raw value: what a page's columns stack by. The same requests in more groups, adding up
    /// to the same.
    func quarterHourGroupsBySource(in range: TimeRange, filter: EventFilter = .all, thresholds: [Int]) throws -> [(source: String, group: QuarterHourGroup)] {
        let selection = Selection(range: range, filter: filter)
        let rows = try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT CAST(time / 900 AS INTEGER) * 900 AS quarterHour, source, model, speed, geo, \(promptBand(thresholds)) AS band, \(tokenSums)
                FROM event \(selection.clause)
                GROUP BY quarterHour, source, model, speed, geo, band
                """, arguments: selection.arguments)
        }
        return rows.map { ($0["source"], QuarterHourGroup(start: Date(timeIntervalSince1970: $0["quarterHour"]), group: PricingGroup($0))) }
    }

    /// `pricingGroups` of each source (by raw value), model or project. Events without a model or project go under the key "",
    /// so the entries add up to the whole range.
    public func breakdown(in range: TimeRange, by dimension: Dimension, thresholds: [Int], filter: EventFilter = .all) throws -> [String: [PricingGroup]] {
        let selection = Selection(range: range, filter: filter)
        let rows = try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT COALESCE(\(dimension.column), '') AS dimension, model, speed, geo, \(promptBand(thresholds)) AS band, \(tokenSums)
                FROM event \(selection.clause)
                GROUP BY dimension, model, speed, geo, band
                """, arguments: selection.arguments)
        }
        return Dictionary(grouping: rows) { $0["dimension"] as String }.mapValues { $0.map { PricingGroup($0) } }
    }

    /// One pass over `range`, to say whether its rows have changed without working out anything from them. Throws if the token sums
    /// of the whole range do not fit, which sums by the quarter hour may well do: a read should not depend on this.
    func fingerprint(of range: TimeRange) throws -> RowsFingerprint {
        let selection = Selection(range: range)
        return try reader.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS rows, COALESCE(SUM(CAST((time - ?) * 1000 AS INTEGER)), 0) AS milliseconds, \(tokenSums)
                FROM event \(selection.clause)
                """, arguments: [range.start.timeIntervalSince1970] + selection.arguments)
            return row.map { RowsFingerprint(rows: $0["rows"], milliseconds: $0["milliseconds"], tokens: TokenCounts($0)) }
                ?? RowsFingerprint(rows: 0, milliseconds: 0, tokens: .zero)
        }
    }

    /// How many events of `range` pass `filter`, and how many of those a sub-agent made.
    func requestCounts(in range: TimeRange, filter: EventFilter = .all) throws -> (all: Int, subagent: Int) {
        let selection = Selection(range: range, filter: filter)
        let row = try reader.read { db in
            try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS requests, SUM(isSubagent) AS subagent FROM event \(selection.clause)
                """, arguments: selection.arguments)
        }
        return (row?["requests"] ?? 0, row?["subagent"] ?? 0)
    }

    /// What one limit has read up to `end`, newest first, back to the start of its newest `windows` windows. The table keeps every row, and a page
    /// refreshes each minute, so this stops at the first reading of a window too many. Not by date: after a gap the windows it wants reach further back.
    func limitReadings(of snapshot: QuotaSnapshot, upTo end: Date, windows: Int) throws -> [(time: Date, percent: Double, resetsAt: Date)] {
        try reader.read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT observedAt, usedPercent, resetsAt FROM quotaSnapshot
                WHERE provider = ? AND "window" = ? AND scope = ? AND observedAt <= ?
                ORDER BY observedAt DESC
                """, arguments: [snapshot.provider.rawValue, snapshot.window.rawValue, snapshot.scope ?? "", end.timeIntervalSince1970])
            var readings: [(time: Date, percent: Double, resetsAt: Date)] = []
            var resets: [Date] = []
            while let row = try rows.next() {
                let resetsAt = Date(timeIntervalSince1970: row["resetsAt"])
                if !resets.contains(where: { abs($0.timeIntervalSince(resetsAt)) <= LimitHistory.sameWindow }) {
                    if resets.count == windows { break }
                    resets.append(resetsAt)
                }
                readings.append((Date(timeIntervalSince1970: row["observedAt"]), row["usedPercent"], resetsAt))
            }
            return readings
        }
    }

    /// The time of the first event at or after `date`.
    func firstEventTime(from date: Date) throws -> Date? {
        let seconds = try reader.read { db in
            try Double.fetchOne(db, sql: "SELECT MIN(time) FROM event WHERE time >= ?", arguments: [date.timeIntervalSince1970])
        }
        return seconds.map { Date(timeIntervalSince1970: $0) }
    }

    /// `pricingGroups` of each named client of each source (by raw value). Events that name no client are left out.
    func clientBreakdown(in range: TimeRange, thresholds: [Int]) throws -> [String: [String: [PricingGroup]]] {
        var selection = Selection(range: range)
        selection.add("client IS NOT NULL")
        let rows = try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source, client, model, speed, geo, \(promptBand(thresholds)) AS band, \(tokenSums)
                FROM event \(selection.clause)
                GROUP BY source, client, model, speed, geo, band
                """, arguments: selection.arguments)
        }
        return Dictionary(grouping: rows) { $0["source"] as String }.mapValues { rows in
            Dictionary(grouping: rows) { $0["client"] as String }.mapValues { $0.map { PricingGroup($0) } }
        }
    }

    /// The events that pass `filter`, newest first: up to `limit` of them older than `before`, or the newest when it is nil.
    ///
    /// `before` holds only a time, so the next page can only start below the time this one ends on. Events can share a time
    /// (a Grok turn gives one to each of its models), so a page runs past `limit` to finish that time rather than lose them.
    public func logPage(filter: EventFilter, before: Date?, limit: Int) throws -> [UsageEvent] {
        guard limit > 0 else { return [] }
        var page = Selection(filter: filter)
        if let before { page.add("time < ?", [before.timeIntervalSince1970]) }
        let rows = try reader.read { db in
            var rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM event \(page.clause) ORDER BY time DESC, id DESC LIMIT ?",
                arguments: page.arguments + [limit]
            )
            if rows.count == limit, let last = rows.last {
                var rest = Selection(filter: filter)
                rest.add("time = ? AND id < ?", [last["time"], last["id"]])
                rows += try Row.fetchAll(db, sql: "SELECT * FROM event \(rest.clause) ORDER BY id DESC", arguments: rest.arguments)
            }
            return rows
        }
        return rows.compactMap { UsageEvent($0) }
    }

    /// What the events in `range` say about generation speed: those with a timing, and a model to report it under.
    public func speedSamples(in range: TimeRange, filter: EventFilter = .all) throws -> [SpeedSample] {
        var selection = Selection(range: range, filter: filter)
        selection.add("model IS NOT NULL AND (generationMs IS NOT NULL OR startTime IS NOT NULL)")
        return try reader.read { db in
            try Array(Row.fetchCursor(
                db,
                sql: "SELECT model, output, generationMs, startTime, time FROM event \(selection.clause)",
                arguments: selection.arguments
            ).map { row in
                SpeedSample(
                    model: row["model"],
                    output: row["output"],
                    generationMs: row["generationMs"],
                    startTime: date(row, "startTime"),
                    time: Date(timeIntervalSince1970: row["time"])
                )
            })
        }
    }
}

/// The columns `TokenCounts.init(_:)` reads, summed.
private let tokenSums = """
    COALESCE(SUM(input), 0) AS input, COALESCE(SUM(output), 0) AS output, COALESCE(SUM(reasoning), 0) AS reasoning, \
    COALESCE(SUM(cacheRead), 0) AS cacheRead, COALESCE(SUM(cacheWrite5m), 0) AS cacheWrite5m, COALESCE(SUM(cacheWrite1h), 0) AS cacheWrite1h
    """

/// `PricingGroup.promptBand` of a row: the highest `b` whose `thresholds[b - 1]` its prompt is over, else 0.
private func promptBand(_ thresholds: [Int]) -> String {
    guard !thresholds.isEmpty else { return "0" }
    let prompt = "input + cacheRead + cacheWrite5m + cacheWrite1h"
    let cases = thresholds.enumerated().reversed().map { "WHEN \(prompt) > \($0.element) THEN \($0.offset + 1)" }
    return "CASE \(cases.joined(separator: " ")) ELSE 0 END"
}

private func date(_ row: Row, _ column: String) -> Date? {
    (row[column] as Double?).map { Date(timeIntervalSince1970: $0) }
}

/// The WHERE clause of a query, with its arguments.
private struct Selection {
    private var conditions: [String] = []
    private(set) var arguments = StatementArguments()

    init(range: TimeRange? = nil, filter: EventFilter = .all) {
        if let range {
            add("time >= ? AND time < ?", [range.start.timeIntervalSince1970, range.end.timeIntervalSince1970])
        }
        if let sources = filter.sources { add("source", in: sources.map(\.rawValue)) }
        if let projects = filter.projects { add("project", in: Array(projects)) }
        if let models = filter.models { add("model", in: Array(models)) }
        if let search = filter.search, !search.isEmpty {
            add("(\(contains("project")) OR \(contains("model")))", [search, search])
        }
        if let quota = filter.quotaProvider { add(QuotaAttribution.sqlPredicate(for: quota)) }
        if let part = filter.modelContains, !part.isEmpty { add(contains("model"), [part]) }
        if let isSubagent = filter.isSubagent { add("isSubagent = ?", [isSubagent]) }
        if let sessionId = filter.sessionId { add("sessionId = ?", [sessionId]) }
        if let machine = filter.machine { add("machine = ?", [machine]) }
    }

    mutating func add(_ condition: String, _ values: StatementArguments = []) {
        conditions.append(condition)
        arguments += values
    }

    private mutating func add(_ column: String, in values: [String]) {
        add("\(column) IN (\(databaseQuestionMarks(count: values.count)))", StatementArguments(values))
    }

    /// `instr`, not LIKE, so that a `%` or `_` the user typed is only that character.
    private func contains(_ column: String) -> String {
        "instr(lower(\(column)), lower(?)) > 0"
    }

    var clause: String {
        conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
    }
}

extension TokenCounts {
    /// From a row of the `event` table, or of `tokenSums`.
    fileprivate init(_ row: Row) {
        self.init(
            input: row["input"],
            output: row["output"],
            reasoning: row["reasoning"],
            cacheRead: row["cacheRead"],
            cacheWrite5m: row["cacheWrite5m"],
            cacheWrite1h: row["cacheWrite1h"]
        )
    }
}

extension PricingGroup {
    fileprivate init(_ row: Row) {
        self.init(model: row["model"], speed: row["speed"], geo: row["geo"], promptBand: row["band"], tokens: TokenCounts(row))
    }
}

extension UsageEvent {
    /// Nil for a row of a source this build cannot name, such as one left by a newer version.
    fileprivate init?(_ row: Row) {
        guard let source = Source(rawValue: row["source"]) else { return nil }
        self.init(
            source: source,
            client: row["client"],
            dedupKey: row["dedupKey"],
            sessionId: row["sessionId"],
            project: row["project"],
            isSubagent: row["isSubagent"],
            provider: row["provider"],
            model: row["model"],
            time: Date(timeIntervalSince1970: row["time"]),
            startTime: date(row, "startTime"),
            generationMs: row["generationMs"],
            speed: row["speed"],
            geo: row["geo"],
            tokens: TokenCounts(row)
        )
    }
}
