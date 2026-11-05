import Foundation

/// Reads Anthropic's usage figures: the body of its usage endpoint, fetched or as Claude Code caches it.
public enum ClaudeUsageParser {
    /// One snapshot per limit: from `limits`, and from `five_hour` and `seven_day` for a window `limits` does not name.
    ///
    /// A limit Tacho has no place for is left out rather than shown as something it is not: another kind, a model limit with no
    /// model name, or one with no reset time, which a snapshot cannot do without.
    public static func snapshots(utilization: [String: Any], observedAt: Date, origin: QuotaOrigin, plan: String?) -> [QuotaSnapshot] {
        snapshots(JSONObject(utilization), observedAt: observedAt, origin: origin, plan: plan)
    }

    static func snapshots(_ body: JSONObject, observedAt: Date, origin: QuotaOrigin, plan: String?) -> [QuotaSnapshot] {
        var snapshots: [QuotaSnapshot] = []

        func add(_ window: QuotaWindow, scope: String?, percent: Double?, resetsAt: Date?) {
            guard let percent, let resetsAt, !snapshots.contains(where: { $0.window == window && $0.scope == scope }) else { return }
            snapshots.append(QuotaSnapshot(
                provider: .anthropic, window: window, scope: scope, usedPercent: min(100, max(0, percent)),
                resetsAt: resetsAt, observedAt: observedAt, origin: origin, plan: plan
            ))
        }

        for case let entry as [String: Any] in body.array("limits") ?? [] {
            let limit = JSONObject(entry)
            guard let (window, scope) = place(of: limit) else { continue }
            add(window, scope: scope, percent: limit.double("percent"), resetsAt: limit.date("resets_at"))
        }
        add(.fiveHour, scope: nil, percent: body.double("five_hour", "utilization"), resetsAt: body.date("five_hour", "resets_at"))
        add(.weekly, scope: nil, percent: body.double("seven_day", "utilization"), resetsAt: body.date("seven_day", "resets_at"))
        return snapshots
    }

    /// The window and scope of an entry of `limits`.
    private static func place(of limit: JSONObject) -> (QuotaWindow, scope: String?)? {
        switch limit.string("kind") {
        case "session":
            return (.fiveHour, nil)
        case "weekly_all":
            return (.weekly, nil)
        case "weekly_scoped":
            // A blank scope reads back from the store as none, so the model's figure would pass as the whole account's.
            guard let model = limit.string("scope", "model", "display_name")?.trimmingCharacters(in: .whitespaces), !model.isEmpty else {
                return nil
            }
            return (.weekly, model)
        default:
            return nil
        }
    }
}

/// The quota Claude Code keeps in `~/.claude.json`, written when someone runs `/usage`.
///
/// That file also holds the user's e-mail and project history. Only `cachedUsageUtilization` and `oauthAccount.accountUuid` are
/// read out of it.
public enum ClaudeCacheQuota {
    public static func accountUuid(claudeJSON: Data) -> String? {
        JSONObject(claudeJSON).flatMap(accountUuid(in:))
    }

    /// The cached limits; none unless they are the signed-in account's.
    public static func snapshots(claudeJSON: Data) -> [QuotaSnapshot] {
        JSONObject(claudeJSON).map(snapshots(in:)) ?? []
    }

    static func accountUuid(in config: JSONObject) -> String? {
        config.string("oauthAccount", "accountUuid")
    }

    static func snapshots(in config: JSONObject) -> [QuotaSnapshot] {
        guard
            let cache = config.object("cachedUsageUtilization"),
            let account = accountUuid(in: config),
            cache.string("accountUuid") == account,
            let observedAt = cache.date("fetchedAtMs"),
            let utilization = cache.object("utilization")
        else { return [] }
        return ClaudeUsageParser.snapshots(utilization, observedAt: observedAt, origin: .claudeCache, plan: nil)
    }
}
