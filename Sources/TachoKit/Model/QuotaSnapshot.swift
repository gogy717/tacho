import Foundation

/// The account behind a quota; decides which events count against it.
public enum QuotaProvider: String, CaseIterable, Codable, Sendable { case anthropic, openai, xai }

/// A rolling usage-limit window.
public enum QuotaWindow: String, Codable, Sendable {
    case fiveHour, weekly

    /// The window's length in seconds.
    public var length: TimeInterval {
        switch self {
        case .fiveHour: 18_000
        case .weekly: 604_800
        }
    }
}

/// Where a snapshot was read from.
public enum QuotaOrigin: String, Codable, Sendable { case claudeCache, ompCache, anthropicAPI, codexLog, grokLog }

/// One observation of a provider's usage limit.
public struct QuotaSnapshot: Equatable, Sendable {
    public var provider: QuotaProvider
    public var window: QuotaWindow
    /// Model display name of a model-scoped weekly limit, e.g. "Fable"; nil for the account-wide limit.
    public var scope: String?
    /// 0...100
    public var usedPercent: Double
    public var resetsAt: Date
    public var observedAt: Date
    public var origin: QuotaOrigin
    public var plan: String?

    public init(
        provider: QuotaProvider,
        window: QuotaWindow,
        scope: String? = nil,
        usedPercent: Double,
        resetsAt: Date,
        observedAt: Date,
        origin: QuotaOrigin,
        plan: String? = nil
    ) {
        self.provider = provider
        self.window = window
        self.scope = scope
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.origin = origin
        self.plan = plan
    }
}
