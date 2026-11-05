import Foundation

/// Local use in the three stretches of time a forecast needs, all in one unit: USD, or total tokens.
public struct WindowWeights: Equatable, Sendable {
    /// From the start of the snapshot's window up to and including the snapshot.
    public var calibration: Double
    /// Since the snapshot, or since the last reset if that is later.
    public var afterSnapshot: Double
    /// The last `ProjectionEngine.recentWindow` seconds.
    public var recent: Double

    public init(calibration: Double, afterSnapshot: Double, recent: Double) {
        self.calibration = calibration
        self.afterSnapshot = afterSnapshot
        self.recent = recent
    }
}

public enum QuotaWeights {
    /// calibration: [resetsAt − length, observedAt]; afterSnapshot: what follows observedAt, from the last reset boundary ≤ now at the
    /// earliest, up to now; recent: [now − 1800, now).
    /// Filter: quotaProvider = snapshot.provider, modelContains = snapshot.scope, sources = includedSources.
    /// Unit: USD, unless any group from the calibration start to now is unpriced — then total tokens for all three.
    public static func compute(
        store: EventStore,
        prices: PriceTable,
        snapshot: QuotaSnapshot,
        includedSources: Set<Source>,
        now: Date
    ) throws -> WindowWeights {
        let filter = EventFilter(sources: includedSources, quotaProvider: snapshot.provider, modelContains: snapshot.scope)
        let thresholds = prices.longContextThresholds
        let length = snapshot.window.length
        let windowStart = snapshot.resetsAt.addingTimeInterval(-length)
        let lastReset = ProjectionEngine.nextReset(of: snapshot, after: now).addingTimeInterval(-length)
        // Spec §5.5: C covers [S, t₀], and only what follows t₀ is after the snapshot. It matters because a Codex record gives its
        // event and its snapshot one timestamp. A TimeRange leaves out its end, so the split is the next value the store can hold:
        // `nextUp` of the unix seconds it compares, not of the `Date`, whose finer value can round back onto `observedAt`.
        let pastSnapshot = Date(timeIntervalSince1970: snapshot.observedAt.timeIntervalSince1970.nextUp)

        func groups(from start: Date, to end: Date) throws -> [PricingGroup] {
            try store.pricingGroups(in: TimeRange(start: start, end: end), filter: filter, thresholds: thresholds)
        }

        // Most of a window is before its snapshot, and that part is asked for twice: for what it costs, and for whether all of it has a
        // price. Where the snapshot divides the window, the two parts answer both. A `TimeRange` leaves out its end, so nothing falls
        // between them, and nothing about a price depends on how requests are grouped.
        let isDivided = windowStart <= pastSnapshot && pastSnapshot <= now
        let before = isDivided ? try groups(from: windowStart, to: pastSnapshot) : nil
        let after = isDivided ? try groups(from: pastSnapshot, to: now) : nil
        let sinceWindowStart = if let before, let after { before + after } else { try groups(from: windowStart, to: now) }
        let allPriced = prices.cost(of: sinceWindowStart).unpricedTokens == 0

        func weight(from start: Date, to end: Date, read: [PricingGroup]? = nil) throws -> Double {
            guard allPriced else { return Double(try store.tokens(in: TimeRange(start: start, end: end), filter: filter).total) }
            return prices.cost(of: try read ?? groups(from: start, to: end)).usd
        }

        return WindowWeights(
            calibration: try weight(from: windowStart, to: pastSnapshot, read: before),
            // A reset since the snapshot starts this later than `after` does.
            afterSnapshot: try weight(from: max(pastSnapshot, lastReset), to: now, read: lastReset <= pastSnapshot ? after : nil),
            recent: try weight(from: now.addingTimeInterval(-ProjectionEngine.recentWindow), to: now)
        )
    }
}
