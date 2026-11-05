/// Which provider's quota an event counts against.
public enum QuotaAttribution {
    /// How a rule reads an event's raw provider id.
    private enum ProviderMatch: Sendable {
        case any
        case absentOr(String)
        case prefix(String)

        func accepts(_ provider: String?) -> Bool {
            switch self {
            case .any: true
            case .absentOr(let id): provider == nil || provider == id
            case .prefix(let prefix): provider?.hasPrefix(prefix) == true
            }
        }

        /// The same test in SQL. GLOB, not LIKE: LIKE ignores case, and `hasPrefix` does not.
        var sql: String {
            switch self {
            case .any: "1"
            case .absentOr(let id): "(provider IS NULL OR provider = '\(id)')"
            case .prefix(let prefix): "provider GLOB '\(prefix)*'"
            }
        }
    }

    private struct Rule: Sendable {
        var sources: [Source]
        var match: ProviderMatch
        var quota: QuotaProvider

        var sql: String {
            let names = sources.map { "'\($0.rawValue)'" }.joined(separator: ", ")
            return "(source IN (\(names)) AND \(match.sql))"
        }
    }

    /// The mapping, once, for both `provider(source:eventProvider:)` and `sqlPredicate(for:)`. No event matches two rules.
    private static let rules: [Rule] = {
        let multiProvider: [Source] = [.omp, .pi, .opencode]
        return [
            Rule(sources: [.claudeCode], match: .any, quota: .anthropic),
            Rule(sources: [.grok], match: .any, quota: .xai),
            Rule(sources: [.codex], match: .absentOr("openai"), quota: .openai),
            Rule(sources: multiProvider, match: .prefix("anthropic"), quota: .anthropic),
            Rule(sources: multiProvider, match: .prefix("openai"), quota: .openai),
            Rule(sources: multiProvider, match: .prefix("xai"), quota: .xai),
        ]
    }()

    /// claudeCode → anthropic; grok → xai; codex → openai when the provider is nil or "openai";
    /// omp/pi/opencode by provider prefix ("anthropic"→anthropic, "openai"→openai, "xai"→xai); copilot and anything else → nil.
    public static func provider(source: Source, eventProvider: String?) -> QuotaProvider? {
        rules.first { $0.sources.contains(source) && $0.match.accepts(eventProvider) }?.quota
    }

    /// A condition on the `event` table that holds for exactly the events `provider(source:eventProvider:)` gives to `quota`.
    static func sqlPredicate(for quota: QuotaProvider) -> String {
        let matching = rules.filter { $0.quota == quota }.map(\.sql)
        return "(\(matching.joined(separator: " OR ")))"
    }
}
