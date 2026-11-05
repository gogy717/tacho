/// The tokens of one request (or a sum of requests), split into disjoint categories:
/// `total = input + output + cacheRead + cacheWrite5m + cacheWrite1h`.
///
/// `output` already includes `reasoning`; `reasoning` is kept for display only and is never added to a total.
public struct TokenCounts: Equatable, Hashable, Codable, Sendable {
    /// Uncached input.
    public var input: Int
    /// Output, including thinking / reasoning tokens.
    public var output: Int
    /// The thinking part of `output`.
    public var reasoning: Int
    public var cacheRead: Int
    /// Cache writes. Sources that do not distinguish a cache lifetime record every write here.
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int

    public init(input: Int = 0, output: Int = 0, reasoning: Int = 0, cacheRead: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0) {
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    /// `cacheWrite5m + cacheWrite1h`
    public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    /// Everything sent to the model: `input + cacheRead + cacheWrite`.
    public var prompt: Int { input + cacheRead + cacheWrite }
    /// `prompt + output`
    public var total: Int { prompt + output }
    /// `cacheRead ÷ prompt`, 0 to 1. nil with no prompt.
    public var cacheHitRate: Double? {
        prompt > 0 ? Double(cacheRead) / Double(prompt) : nil
    }

    public static let zero = TokenCounts()

    public static func + (l: TokenCounts, r: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: l.input + r.input,
            output: l.output + r.output,
            reasoning: l.reasoning + r.reasoning,
            cacheRead: l.cacheRead + r.cacheRead,
            cacheWrite5m: l.cacheWrite5m + r.cacheWrite5m,
            cacheWrite1h: l.cacheWrite1h + r.cacheWrite1h
        )
    }

    public static func += (l: inout TokenCounts, r: TokenCounts) {
        l = l + r
    }
}
