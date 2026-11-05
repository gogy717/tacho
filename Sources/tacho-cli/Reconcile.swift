import Foundation
import GRDB
import TachoKit

/// Sets Tacho's figures beside what each CLI, or ClaudeBar, keeps on its own. It prints sums and counts only: no path, id or text.
///
/// `run` returns 1 when the figures disagree in a way nothing explains, 0 otherwise. Codex is informational, so its result is never a
/// failure: `tokens_used` is not documented, and holds only the running total of a thread's latest stretch.
struct Reconcile {
    private let context: Context

    init(_ context: Context) {
        self.context = context
    }

    func run(_ target: String) async throws -> Int32 {
        switch target {
        case "claudebar": return try await claudeBar()
        case "omp": return try await omp()
        case "opencode": return try await openCode()
        case "grok": return try await grok()
        case "codex": return try await codex()
        default: throw UsageError("reconcile needs one of claudebar, omp, opencode, grok, codex, not \(target)")
        }
    }

    // MARK: ClaudeBar

    /// Day by day, because a total can hide an event the merge rule moved to another day. It walks the calendar back from yesterday,
    /// not ClaudeBar's keys, so a day only Tacho has figures for is compared too, with ClaudeBar at 0. Days neither side has anything
    /// for are passed over, so that `--days` closed days of real figures are compared.
    private func claudeBar() async throws -> Int32 {
        let wanted = try context.arguments.positiveInt("--days", default: 3)
        let file = context.home.appendingPathComponent(".claudebar/usage-history/claude.json")
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], let days = root["days"] as? [String: Any] else {
            print("claudebar: no `days` in \(file.lastPathComponent)")
            return 1
        }
        let store = try await context.currentStore()
        let calendar = context.calendar
        let filter = EventFilter(sources: [.claudeCode])
        // Newest first, so the last event is the oldest.
        let firstEvent = try allEvents(of: .claudeCode, in: store).last?.time
        let firstKey = days.keys.compactMap { calendar.day($0)?.start }.min()
        guard let earliest = [firstEvent, firstKey].compactMap({ $0 }).min() else {
            print("closed days compared: 0")
            return 1
        }

        print("\(left("day", 12))\(left("category", 12))\(right("claudebar", 16))\(right("tacho", 16))\(right("diff %", 10))")
        var compared = 0
        var withoutEntry = 0
        var failures: [String] = []
        var next = calendar.startOfDay(for: Date())
        while compared < wanted, let start = calendar.date(byAdding: .day, value: -1, to: next), start >= calendar.startOfDay(for: earliest) {
            let day = TimeRange(start: start, end: next)
            next = start
            let parts = calendar.dateComponents([.year, .month, .day], from: start)
            let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            let entry = days[key] as? [String: Any] ?? [:]
            let tacho = try store.tokens(in: day, filter: filter)
            let figures: [(String, Int, Int)] = [
                ("input", Self.int(entry["inputTokens"]), tacho.input),
                ("output", Self.int(entry["outputTokens"]), tacho.output),
                ("cacheWrite", Self.int(entry["cacheCreationTokens"]), tacho.cacheWrite5m + tacho.cacheWrite1h),
                ("cacheRead", Self.int(entry["cacheReadTokens"]), tacho.cacheRead),
            ]
            guard figures.contains(where: { $0.1 != 0 || $0.2 != 0 }) else { continue }
            compared += 1
            if entry.isEmpty { withoutEntry += 1 }
            for (category, theirs, ours) in figures {
                let difference = Self.percentDifference(ours, from: theirs)
                print("\(left(key, 12))\(left(category, 12))\(right("\(theirs)", 16))\(right("\(ours)", 16))\(right(String(format: "%.3f", difference), 10))")
                if difference > 1 {
                    failures.append("\(key) \(category)")
                }
            }
        }
        print("closed days compared: \(compared), \(withoutEntry) of them with no ClaudeBar entry")
        // Nothing compared is no agreement.
        guard compared > 0 else { return 1 }
        if failures.isEmpty {
            print("within 1%")
            return 0
        }
        print("more than 1% apart: \(failures.joined(separator: ", "))")
        return 1
    }

    // MARK: omp

    /// One record of a session that has a usage.
    private struct OmpRecord {
        var key: String
        var isSideCall: Bool
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int

        var isZero: Bool { input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 }
    }

    /// Row by row against `stats.db`, because its totals mix what Tacho counts apart. Its `messages` table holds side calls too, and
    /// it holds nothing newer than omp's last sync, so a comparison of sums would differ for reasons that say nothing about Tacho.
    private func omp() async throws -> Int32 {
        let store = try await context.currentStore()
        let events = try allEvents(of: .omp, in: store)
        let byKey = Dictionary(events.map { ($0.dedupKey, $0) }, uniquingKeysWith: { first, _ in first })

        // What the sessions say, and the two fields glassbox reads differently from Tacho.
        var records: [String: OmpRecord] = [:]
        var usages = 0
        var orchestration = 0
        var reasoningTokens = 0
        var reasoning = 0
        for file in try PiFamilyReader(source: .omp).discover(root: context.home.appendingPathComponent(".omp")) {
            _ = try LineReader.read(file, from: nil) { line in
                guard line.range(of: Data(#""usage""#.utf8)) != nil,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = object["id"] as? String
                else { return }
                let message = object["message"] as? [String: Any]
                let isSideCall = object["type"] as? String == "model_usage"
                guard isSideCall || (object["type"] as? String == "message" && message?["role"] as? String == "assistant") else { return }
                guard let usage = (isSideCall ? object["usage"] : message?["usage"]) as? [String: Any] else { return }
                usages += 1
                if usage["orchestration"] != nil { orchestration += 1 }
                if usage["reasoningTokens"] != nil { reasoningTokens += 1 }
                if usage["reasoning"] != nil { reasoning += 1 }
                let native = isSideCall ? "mu:\(id)" : Self.present(message?["responseId"]) ?? Self.present(message?["respId"]) ?? id
                records["\(file.path)\n\(id)"] = OmpRecord(
                    key: "\(Source.omp.rawValue):\(native)",
                    isSideCall: isSideCall,
                    input: Self.int(usage["input"]),
                    output: Self.int(usage["output"]),
                    cacheRead: Self.int(usage["cacheRead"]),
                    cacheWrite: Self.int(usage["cacheWrite"])
                )
            }
        }

        let rows = try statsRows(context.home.appendingPathComponent(".omp/stats.db"))

        var messageRows = 0
        var sideCallRows = 0
        var zeroRows = 0
        var notInSessions = 0
        var notInStore = 0
        var differing = 0
        var nullRows = 0
        var matchedMessageTokens = 0
        var matchedSideCallTokens = 0
        var statsTokens = 0
        var newest: Int64 = 0
        var matchedKeys: Set<String> = []
        for row in rows {
            guard !row.hasNull else {
                nullRows += 1
                continue
            }
            let total = row.figures.reduce(0, +)
            statsTokens += total
            newest = max(newest, row.timestamp)
            guard let record = records["\(row.file)\n\(row.entry)"] else {
                notInSessions += 1
                continue
            }
            if record.isZero, total == 0 {
                zeroRows += 1
                continue
            }
            guard let event = byKey[record.key] else {
                notInStore += 1
                continue
            }
            matchedKeys.insert(record.key)
            let tokens = event.tokens
            if row.figures != [tokens.input, tokens.output, tokens.cacheRead, tokens.cacheWrite] {
                differing += 1
                continue
            }
            if record.isSideCall {
                sideCallRows += 1
                matchedSideCallTokens += total
            } else {
                messageRows += 1
                matchedMessageTokens += total
            }
        }

        // Every session record against the store, in both directions. `stats.db` stops at its last sync, so this is the only check
        // on what came after it.
        let nonZero = records.values.filter { !$0.isZero }
        let recordKeys = Set(nonZero.map(\.key))
        var recordsEqual = 0
        var recordsDiffering = 0
        var recordsNotInStore = 0
        for record in nonZero {
            guard let tokens = byKey[record.key]?.tokens else {
                recordsNotInStore += 1
                continue
            }
            if [record.input, record.output, record.cacheRead, record.cacheWrite] == [tokens.input, tokens.output, tokens.cacheRead, tokens.cacheWrite] {
                recordsEqual += 1
            } else {
                recordsDiffering += 1
            }
        }
        let eventsWithoutRecord = events.filter { !recordKeys.contains($0.dedupKey) }.count

        let isSideCall: (UsageEvent) -> Bool = { $0.dedupKey.hasPrefix("\(Source.omp.rawValue):mu:") }
        let messages = events.filter { !isSideCall($0) }
        let sideCalls = events.filter(isSideCall)
        let cutoff = Date(timeIntervalSince1970: Double(newest) / 1000)
        let unmatched = messages.filter { !matchedKeys.contains($0.dedupKey) }
        let unmatchedOlder = unmatched.filter { $0.time <= cutoff }
        let total: ([UsageEvent]) -> Int = { $0.reduce(0) { $0 + $1.tokens.total } }

        print("sessions against the store: \(recordsEqual) records equal, \(recordsDiffering) differing, \(recordsNotInStore) not in the store, \(eventsWithoutRecord) events with no record")
        print("stats.db messages: \(rows.count) rows, \(statsTokens) tokens, newest row \(cutoff.ISO8601Format())")
        print("  assistant messages, tokens equal to Tacho's: \(messageRows) rows, \(matchedMessageTokens) tokens")
        print("  model_usage side calls, tokens equal to Tacho's: \(sideCallRows) rows, \(matchedSideCallTokens) tokens")
        print("  zero-usage rows, which Tacho does not store: \(zeroRows)")
        print("  rows whose tokens differ from Tacho's: \(differing)")
        print("  rows with no record in any session: \(notInSessions); rows whose record is not in the store: \(notInStore)")
        print("  rows with a NULL column: \(nullRows)")
        print("Tacho omp messages, excluding omp:mu: \(messages.count) events, \(total(messages)) tokens")
        print("  in stats.db: \(messages.count - unmatched.count); newer than its last row: \(unmatched.count - unmatchedOlder.count) events, \(total(unmatched) - total(unmatchedOlder)) tokens; older and absent: \(unmatchedOlder.count)")
        print("model_usage extra: \(sideCalls.count) events, \(total(sideCalls)) tokens (\(sideCallRows) of them also in stats.db)")
        print("usage objects in the sessions: \(usages); with `orchestration`: \(orchestration); with `reasoningTokens`: \(reasoningTokens); with `reasoning`: \(reasoning)")
        // A zero-usage row is accounted for without being compared, so rows alone are not enough.
        guard messageRows + sideCallRows > 0, !nonZero.isEmpty else {
            print("nothing to compare")
            return 1
        }
        let sessionsAgree = recordsDiffering == 0 && recordsNotInStore == 0 && eventsWithoutRecord == 0
        let statsAgree = differing == 0 && notInSessions == 0 && notInStore == 0 && nullRows == 0 && unmatchedOlder.isEmpty
        print(sessionsAgree && statsAgree ? "every session record and every stats.db row is accounted for" : "the sessions, stats.db and Tacho disagree")
        return sessionsAgree && statsAgree ? 0 : 1
    }

    /// One row of `stats.db`'s `messages`. `figures` are input, output, cache read and cache write.
    private struct StatsRow {
        var file: String
        var entry: String
        var figures: [Int]
        var timestamp: Int64
        /// Whether a column is NULL. Such a row cannot be compared: read as a 0 it could even look equal.
        var hasNull: Bool
    }

    private func statsRows(_ database: URL) throws -> [StatsRow] {
        try ReadOnlySQLite.open(database).read { db in
            // A NULL read as a plain value is a fatal error in GRDB, so every column is read as an optional and a NULL is noted.
            try Row.fetchAll(db, sql: "SELECT session_file, entry_id, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, timestamp FROM messages").map { row in
                StatsRow(
                    file: row["session_file"] as String? ?? "",
                    entry: row["entry_id"] as String? ?? "",
                    figures: ["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"].map { row[$0] as Int? ?? 0 },
                    timestamp: row["timestamp"] as Int64? ?? 0,
                    hasNull: row.databaseValues.contains(where: \.isNull)
                )
            }
        }
    }

    // MARK: OpenCode

    /// The sums of OpenCode's `session` table.
    private struct SessionTotals {
        var sessions: Int
        var input: Int
        var output: Int
        var reasoning: Int
        var cacheRead: Int
        var cacheWrite: Int
        /// How many of the token cells are NULL. `sum` passes over them, so they would not show in the totals.
        var nulls: Int
    }

    private func sessionTotals(_ database: URL) throws -> SessionTotals {
        try ReadOnlySQLite.open(database).read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT count(*) AS sessions, sum(tokens_input) AS input, sum(tokens_output) AS output, sum(tokens_reasoning) AS reasoning,
                       sum(tokens_cache_read) AS cacheRead, sum(tokens_cache_write) AS cacheWrite,
                       sum((tokens_input IS NULL) + (tokens_output IS NULL) + (tokens_reasoning IS NULL)
                           + (tokens_cache_read IS NULL) + (tokens_cache_write IS NULL)) AS nulls
                FROM session
                """)
            // `sum` of no rows, or of only NULLs, is NULL.
            func total(_ column: String) -> Int { row.flatMap { $0[column] as Int? } ?? 0 }
            return SessionTotals(
                sessions: total("sessions"), input: total("input"), output: total("output"), reasoning: total("reasoning"),
                cacheRead: total("cacheRead"), cacheWrite: total("cacheWrite"), nulls: total("nulls")
            )
        }
    }

    private func openCode() async throws -> Int32 {
        let store = try await context.currentStore()
        let database = URL(fileURLWithPath: try only(context.roots.roots[.opencode]))
        let session = try sessionTotals(database)
        let tacho = sum(try allEvents(of: .opencode, in: store))
        // The session table keeps reasoning apart from output; Tacho's output includes it.
        let figures: [(String, Int, Int)] = [
            ("input", session.input, tacho.input),
            ("output + reasoning", session.output + session.reasoning, tacho.output),
            ("reasoning", session.reasoning, tacho.reasoning),
            ("cacheRead", session.cacheRead, tacho.cacheRead),
            ("cacheWrite", session.cacheWrite, tacho.cacheWrite5m),
        ]
        print("session rows: \(session.sessions), NULL cells: \(session.nulls)")
        let totalsAgree = printTotals(figures, theirs: "session")
        let rowsAgree = try printRewriteCheck(of: .opencode, reader: OpenCodeReader(), files: [database], in: store)
        guard session.sessions > 0 else {
            print("nothing to compare")
            return 1
        }
        return totalsAgree && rowsAgree && session.nulls == 0 ? 0 : 1
    }

    // MARK: Grok

    private func grok() async throws -> Int32 {
        let store = try await context.currentStore()
        let reader = GrokReader()
        let files = try reader.discover(root: context.home.appendingPathComponent(".grok"))
        let events = try allEvents(of: .grok, in: store)
        let bySession = Dictionary(grouping: events) { $0.sessionId ?? "" }

        var theirs = TokenCounts.zero
        var totalTokens = 0
        var sessions = 0
        var matching = 0
        for file in files where file.lastPathComponent == "usage.json" {
            guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  let session = root["session"] as? [String: Any]
            else { continue }
            sessions += 1
            let cached = Self.int(session["cachedReadTokens"])
            let created = Self.int(session["cacheCreationTokens"])
            let expected = TokenCounts(
                input: Self.int(session["inputTokens"]) - cached - created, output: Self.int(session["outputTokens"]),
                reasoning: Self.int(session["reasoningTokens"]), cacheRead: cached, cacheWrite5m: created
            )
            theirs = theirs + expected
            totalTokens += Self.int(session["totalTokens"])
            let ours = sum(bySession[file.deletingLastPathComponent().lastPathComponent] ?? [])
            if ours == expected, ours.total == Self.int(session["totalTokens"]) {
                matching += 1
            }
        }
        let tacho = sum(events)
        print("usage.json sessions: \(sessions); matching their own totals: \(matching)")
        let totalsAgree = printTotals([
            ("input", theirs.input, tacho.input),
            ("output", theirs.output, tacho.output),
            ("reasoning", theirs.reasoning, tacho.reasoning),
            ("cacheRead", theirs.cacheRead, tacho.cacheRead),
            ("cacheWrite", theirs.cacheWrite5m, tacho.cacheWrite5m),
            ("total", totalTokens, tacho.total),
        ], theirs: "usage.json")
        let rowsAgree = try printRewriteCheck(of: .grok, reader: reader, files: files, in: store)
        guard sessions > 0 else {
            print("nothing to compare")
            return 1
        }
        return totalsAgree && rowsAgree && matching == sessions ? 0 : 1
    }

    // MARK: Codex

    /// `threads.tokens_used` by thread id. No other column is read: the table also holds the first message of each thread.
    private func tokensUsed(_ database: URL) throws -> (used: [String: Int], nullRows: Int) {
        try ReadOnlySQLite.open(database).read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, tokens_used FROM threads")
            let used = Dictionary(rows.map { ($0["id"] as String? ?? "", $0["tokens_used"] as Int? ?? 0) }, uniquingKeysWith: { first, _ in first })
            return (used, rows.filter { $0.databaseValues.contains(where: \.isNull) }.count)
        }
    }

    /// Thread by thread against `threads.tokens_used`. Informational: on this Mac that column is the last running total of a rollout.
    /// A running total starts over at a resume or a continuation, so a thread that has one shows Tacho higher, and a thread that starts
    /// from a parent's total shows Tacho lower. A sub-agent that made no call of its own has a total and no events.
    private func codex() async throws -> Int32 {
        let store = try await context.currentStore()
        let events = try allEvents(of: .codex, in: store)
        let (rows, nullRows) = try tokensUsed(context.home.appendingPathComponent(".codex/state_5.sqlite"))
        var tachoByThread: [String: Int] = [:]
        for event in events {
            tachoByThread[event.sessionId ?? "", default: 0] += event.tokens.total
        }

        var equal = 0
        var theirZero = 0
        var noEvents = 0
        var noEventsTokens = 0
        var tachoHigher = 0
        var tachoLower = 0
        var theirTotal = 0
        var differenceInBoth = 0
        for (id, used) in rows {
            theirTotal += used
            guard let ours = tachoByThread[id] else {
                noEvents += 1
                noEventsTokens += used
                continue
            }
            if used == 0 {
                theirZero += 1
            } else if ours == used {
                equal += 1
            } else if ours > used {
                tachoHigher += 1
            } else {
                tachoLower += 1
            }
            if used != 0 {
                differenceInBoth += ours - used
            }
        }
        let onlyTacho = tachoByThread.filter { rows[$0.key] == nil }
        let tachoTotal = tachoByThread.values.reduce(0, +)
        print("threads rows: \(rows.count), tokens_used sum: \(theirTotal), rows with a NULL column: \(nullRows)")
        print("Tacho: \(tachoByThread.count) threads, \(events.count) events, \(tachoTotal) tokens")
        print("  equal: \(equal); Tacho higher: \(tachoHigher); Tacho lower: \(tachoLower); tokens_used 0 with Tacho events: \(theirZero)")
        print("  threads with no Tacho events: \(noEvents) (\(noEventsTokens) tokens_used)")
        print("  Tacho threads with no row: \(onlyTacho.count) (\(onlyTacho.values.reduce(0, +)) tokens)")
        print("  net difference on threads with both: \(differenceInBoth)")
        print("informational: tokens_used is the last running total of a thread, not a sum of its calls")
        return 0
    }

    // MARK: Shared

    /// Prints each figure beside Tacho's, and says whether they are all equal.
    private func printTotals(_ figures: [(String, Int, Int)], theirs: String) -> Bool {
        print("\(left("category", 20))\(right(theirs, 16))\(right("tacho", 16))\(right("diff", 12))")
        for (category, their, ours) in figures {
            print("\(left(category, 20))\(right("\(their)", 16))\(right("\(ours)", 16))\(right("\(ours - their)", 12))")
        }
        return figures.allSatisfy { $0.1 == $0.2 }
    }

    /// Whether the merge rule hides a rewritten row: every stored row beside what the source says now. The rule keeps a stored row
    /// when a rewrite has smaller output, so a row the source revised that way would show up here as differing.
    ///
    /// This can only find a rewrite that happened after the store read the row. On a store as young as the file's last change it cannot
    /// fail, so it says something only on a store kept across the source's use. No rows at all is no agreement.
    private func printRewriteCheck(of source: Source, reader: any SourceReader, files: [URL], in store: EventStore) throws -> Bool {
        var fresh: [String: UsageEvent] = [:]
        for file in files {
            for event in try reader.read(file, from: nil).events {
                fresh[event.dedupKey] = event
            }
        }
        var same = 0
        var differing = 0
        var onlyInStore = 0
        var largestTimeGap = 0.0
        let stored = try allEvents(of: source, in: store)
        for event in stored {
            guard let current = fresh[event.dedupKey] else {
                onlyInStore += 1
                continue
            }
            // The store keeps a time as seconds since 1970 and a `Date` counts from 2001, so a time with microseconds comes back a few
            // hundred nanoseconds off. A rewrite that moved a turn would be far more than a millisecond.
            let timeGap = abs(current.time.timeIntervalSince(event.time))
            largestTimeGap = max(largestTimeGap, timeGap)
            if current.tokens == event.tokens, timeGap < 0.001 {
                same += 1
            } else {
                differing += 1
            }
        }
        let onlyInSource = Set(fresh.keys).subtracting(stored.map(\.dedupKey)).count
        print("rows against a fresh read: \(same) same, \(differing) differing, \(onlyInStore) only in the store, \(onlyInSource) only in the source")
        print(String(format: "largest time gap: %.9f s", largestTimeGap))
        print("this sees only a rewrite made after the store read the row: on a store younger than the source's last change it cannot fail")
        return same > 0 && differing == 0 && onlyInStore == 0 && onlyInSource == 0
    }

    private func allEvents(of source: Source, in store: EventStore) throws -> [UsageEvent] {
        try store.logPage(filter: EventFilter(sources: [source]), before: nil, limit: Int(Int32.max))
    }

    private func sum(_ events: [UsageEvent]) -> TokenCounts {
        events.reduce(.zero) { $0 + $1.tokens }
    }

    private func only(_ roots: [String]?) throws -> String {
        guard let root = roots?.first else { throw UsageError("no root configured") }
        return root
    }

    /// `value` as text, unless it is blank, which the omp reader takes for a missing id.
    private static func present(_ value: Any?) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    /// How far `ours` is from `theirs`, as a percentage of `theirs`. Any difference from nothing is a whole 100%.
    private static func percentDifference(_ ours: Int, from theirs: Int) -> Double {
        if ours == theirs { return 0 }
        if theirs == 0 { return 100 }
        return Double(abs(ours - theirs)) / Double(theirs) * 100
    }
}
