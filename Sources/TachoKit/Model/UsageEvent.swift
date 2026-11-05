import Foundation

/// One model request, as recorded by a CLI.
///
/// Only these fields are ever stored; conversation content never is.
public struct UsageEvent: Equatable, Sendable {
    public var source: Source
    /// Client inside the source, raw: "cli", "claude-desktop", "codex-tui", …
    public var client: String?
    /// `"<source.rawValue>:<native key>"`; unique across every file of every source.
    public var dedupKey: String
    public var sessionId: String?
    /// The working directory.
    public var project: String?
    public var isSubagent: Bool
    /// Raw provider id from the record, e.g. "anthropic", "openai", "xai", "copilot".
    public var provider: String?
    public var model: String?
    /// Completion time. Rates, days and heatmaps all bucket by it.
    public var time: Date
    /// Approximate request start (Claude only).
    public var startTime: Date?
    /// Exact generation duration (omp, pi, Copilot).
    public var generationMs: Double?
    /// Claude `usage.speed`.
    public var speed: String?
    /// Claude `usage.inference_geo`.
    public var geo: String?
    public var tokens: TokenCounts

    public init(
        source: Source,
        client: String? = nil,
        dedupKey: String,
        sessionId: String? = nil,
        project: String? = nil,
        isSubagent: Bool = false,
        provider: String? = nil,
        model: String? = nil,
        time: Date,
        startTime: Date? = nil,
        generationMs: Double? = nil,
        speed: String? = nil,
        geo: String? = nil,
        tokens: TokenCounts
    ) {
        self.source = source
        self.client = client
        self.dedupKey = dedupKey
        self.sessionId = sessionId
        self.project = project
        self.isSubagent = isSubagent
        self.provider = provider
        self.model = model
        self.time = time
        self.startTime = startTime
        self.generationMs = generationMs
        self.speed = speed
        self.geo = geo
        self.tokens = tokens
    }
}
