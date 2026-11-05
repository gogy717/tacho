/// A coding CLI whose local logs Tacho reads.
///
/// The raw value is persisted and prefixes every `UsageEvent.dedupKey`.
public enum Source: String, CaseIterable, Codable, Sendable {
    case claudeCode, codex, omp, pi, copilot, opencode, grok

    /// The product name shown in the interface.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .omp: "oh-my-pi"
        case .pi: "pi"
        case .copilot: "Copilot CLI"
        case .opencode: "OpenCode"
        case .grok: "Grok Build"
        }
    }
}
