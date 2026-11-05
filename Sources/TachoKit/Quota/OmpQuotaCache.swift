import Foundation
import GRDB

/// Plan quota from oh-my-pi's usage cache: the `cache` table of `~/.omp/agent/agent.db`, where it keeps the last usage report of
/// every provider account it is signed in to, in rows keyed `usage_cache:report:<provider>:<baseUrl>:<identity>`.
///
/// The database also holds credentials, and keys and reports name the account (e-mail, account and org ids). Only the `cache`
/// table is read and only its `value` column is selected; the key is matched inside SQLite, so all that leaves it is yes or no.
/// Of a report only the provider, fetch time, plan and each limit's id, label, window, amount and status are read.
///
/// `ReadOnlySQLite.open` leaves out a `-wal` it cannot read without changing a file, so a report may only show once oh-my-pi
/// checkpoints it. Such a read takes no lock, and can fail or meet a half-written page if it overlaps a checkpoint: a value that
/// is NULL or does not parse is skipped, and a failed read is for the caller to try again. `NOT NULL` is enforced on writes, not
/// on reads, and GRDB crashes on a NULL read as a plain value, so every column is read as an optional.
public enum OmpQuotaCache {
    /// The limits of every report oh-my-pi would still serve. An Anthropic report counts only when its key names `anthropicAccount`.
    public static func snapshots(agentDB: URL, anthropicAccount: String?) throws -> [QuotaSnapshot] {
        // The identity is joined with "|": "oauth|account:<uuid>|email:<address>". The key gets one more so the last part has one too.
        let identity = anthropicAccount.map { "|account:\($0)|" }
        let now = Int64(Date().timeIntervalSince1970)
        return try ReadOnlySQLite.open(agentDB).read { db in
            var snapshots: [QuotaSnapshot] = []
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT value, instr(key || '|', ?) > 0 AS isTheAccount FROM cache
                    WHERE key GLOB 'usage_cache:report:*' AND expires_at > ?
                    """,
                arguments: [identity, now]
            )
            while let row = try rows.next() {
                guard let value = row["value"] as Data? else { continue }
                snapshots += Self.snapshots(value: value, isTheAccount: row["isTheAccount"] ?? false)
            }
            return snapshots
        }
    }

    /// The limits of one `value`, oh-my-pi's envelope around a report. Its report is null once invalidated.
    private static func snapshots(value: Data, isTheAccount: Bool) -> [QuotaSnapshot] {
        guard
            let report = JSONObject(value)?.object("value"),
            let provider = report.string("provider").flatMap(provider(id:)),
            provider != .anthropic || isTheAccount,
            let observedAt = report.date("fetchedAt")
        else { return [] }
        return (report.array("limits") ?? []).compactMap { entry in
            guard let limit = entry as? [String: Any] else { return nil }
            return snapshot(of: JSONObject(limit), provider: provider, observedAt: observedAt, plan: report.string("metadata", "planType"))
        }
    }

    /// The vendor whose plan an oh-my-pi provider id reports on; nil for one Tacho keeps no quota of.
    private static func provider(id: String) -> QuotaProvider? {
        switch id {
        case "xai-oauth": .xai
        case "openai-codex": .openai
        default: id.hasPrefix("anthropic") ? .anthropic : nil
        }
    }

    private static func snapshot(of limit: JSONObject, provider: QuotaProvider, observedAt: Date, plan: String?) -> QuotaSnapshot? {
        guard
            limit.string("status") != "unknown",
            let (isPlanWide, scope) = reach(of: limit),
            isPlanWide || scope != nil,
            let window = window(of: limit),
            let resetsAt = limit.date("window", "resetsAt"),
            let usedPercent = limit.object("amount").flatMap(usedPercent(of:))
        else { return nil }
        return QuotaSnapshot(
            provider: provider, window: window, scope: scope, usedPercent: usedPercent, resetsAt: resetsAt,
            observedAt: observedAt, origin: .ompCache, plan: plan
        )
    }

    /// The limits that cover a whole account. A report holds others at the same lengths: xAI's per-product allowances (`product:…`),
    /// Codex's per-model meters (`<model>:primary`). `scope.shared` is set on those too, so nothing short of the id tells them apart,
    /// and any of them recorded as the account's would show the wrong figure. An id not listed here is left out.
    private static let planLimits: Set<String> = [
        "anthropic:5h", "anthropic:7d", "openai-codex:primary", "openai-codex:secondary", "xai-oauth:credits:1w",
    ]

    /// Whether `limit` covers the account, or one model of it by the name Claude's own cache gives that model.
    private static func reach(of limit: JSONObject) -> (isPlanWide: Bool, scope: String?)? {
        guard let id = limit.string("id") else { return nil }
        if planLimits.contains(id) { return (true, nil) }
        guard id.hasPrefix("anthropic:7d:") else { return nil }
        return (false, limit.string("label").flatMap(modelName(inLabel:)))
    }

    /// "Claude 7 Day (Fable)" → "Fable", and "Claude 7 Day (Fable (preview))" → "Fable (preview)". The report has the name nowhere
    /// else: `scope.tier` is a slug of it.
    private static func modelName(inLabel label: String) -> String? {
        guard label.hasSuffix(")"), let open = label.firstIndex(of: "(") else { return nil }
        let name = label[label.index(after: open)...].dropLast().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The window of `limit`, by its length, or what its id says when it has none ("5h", "1w"). 5% off counts, as in Codex.
    /// Another length, such as the 30 days of a free ChatGPT plan, is no window of Tacho's.
    private static func window(of limit: JSONObject) -> QuotaWindow? {
        let duration = limit.double("window", "durationMs").flatMap { $0 > 0 ? $0 / 1000 : nil }
        guard let seconds = duration ?? limit.string("window", "id").flatMap(seconds(inWindowId:)) else { return nil }
        return [QuotaWindow.fiveHour, .weekly].first { abs(seconds - $0.length) <= $0.length * 0.05 }
    }

    private static func seconds(inWindowId id: String) -> TimeInterval? {
        if id.lowercased() == "weekly" { return QuotaWindow.weekly.length }
        let units: [Character: TimeInterval] = ["m": 60, "h": 3_600, "d": 86_400, "w": 604_800]
        guard let last = id.last, let unit = units[Character(last.lowercased())], let count = Double(id.dropLast()) else { return nil }
        return count * unit
    }

    /// 0...100 from whichever amount the provider filled in, in oh-my-pi's own order: the used fraction, used / limit, a used
    /// percentage, what remains. nil when none is usable, such as Copilot's 0 of 0.
    private static func usedPercent(of amount: JSONObject) -> Double? {
        let percent: Double
        if let fraction = amount.double("usedFraction") {
            percent = fraction * 100
        } else if let used = amount.double("used"), let limit = amount.double("limit"), limit > 0 {
            percent = used * 100 / limit
        } else if let used = amount.double("used"), amount.string("unit") == "percent" {
            percent = used
        } else if let remaining = amount.double("remainingFraction") {
            percent = (1 - remaining) * 100
        } else {
            return nil
        }
        return min(100, max(0, percent))
    }
}
