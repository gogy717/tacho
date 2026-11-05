import Foundation

/// What the menu bar icon warns of.
public enum AlertLevel: Equatable, Sendable { case none, amber, red }

/// Where a quota stands and where it is heading.
public struct Projection: Equatable, Sendable {
    public enum Method: Equatable, Sendable {
        /// Local use scaled by how much of the quota it cost so far.
        case calibrated
        /// The percentage used so far, spread over the time the window has been open.
        case windowAverage
    }

    public enum Outcome: Equatable, Sendable {
        case lastsUntilReset
        case runsOut(at: Date, beforeReset: TimeInterval)
        /// Nothing used lately.
        case idle
        case unknown
    }

    public var snapshot: QuotaSnapshot
    public var estimatedPercent: Double
    /// `estimatedPercent` is inferred from local use, not read from the provider.
    public var isEstimate: Bool
    public var method: Method
    public var outcome: Outcome
    /// Observed longer ago than `staleAfter` allows, its window reset since or not (spec 5.6). A row with no recent data says that instead.
    public var isStale: Bool
    /// The next reset, which is later than `snapshot.resetsAt` once that has passed.
    public var resetsAt: Date
    /// False once the snapshot expired a full window ago or more: it then says nothing about the quota, so there is no forecast and no
    /// alert, only the row saying so.
    public var hasRecentData: Bool
    /// Percent of the limit an hour over the recent window, by local use. nil when local use cannot be calibrated.
    public var recentPercentPerHour: Double?
    /// Percent of the limit an hour from the window opening to the snapshot. nil when the snapshot says nothing of this window.
    public var windowPercentPerHour: Double?

    /// The pace the forecast runs on: `recentPercentPerHour` when `calibrated`, else `windowPercentPerHour`.
    public var pacePercentPerHour: Double? {
        method == .calibrated ? recentPercentPerHour : windowPercentPerHour
    }

    /// How far through its window this limit is at `now`, 0 to 1: where use would stand at an even pace. nil with no recent data.
    ///
    /// A method and not a field: it moves with the clock, and as a field every dashboard would differ from the last, which would
    /// redraw the menu bar each second for anyone with a limit.
    public func paceFraction(at now: Date) -> Double? {
        guard hasRecentData else { return nil }
        let length = snapshot.window.length
        return min(1, max(0, now.timeIntervalSince(resetsAt.addingTimeInterval(-length)) / length))
    }

    public init(
        snapshot: QuotaSnapshot,
        estimatedPercent: Double,
        isEstimate: Bool,
        method: Method,
        outcome: Outcome,
        isStale: Bool,
        resetsAt: Date,
        hasRecentData: Bool = true,
        recentPercentPerHour: Double? = nil,
        windowPercentPerHour: Double? = nil
    ) {
        self.snapshot = snapshot
        self.estimatedPercent = estimatedPercent
        self.isEstimate = isEstimate
        self.method = method
        self.outcome = outcome
        self.isStale = isStale
        self.resetsAt = resetsAt
        self.hasRecentData = hasRecentData
        self.recentPercentPerHour = recentPercentPerHour
        self.windowPercentPerHour = windowPercentPerHour
    }
}

/// The forecast of spec §5.5, 预期使用时间.
public enum ProjectionEngine {
    public static let recentWindow: TimeInterval = 1800

    public static func staleAfter(_ window: QuotaWindow) -> TimeInterval {
        switch window {
        case .fiveHour: 900
        case .weekly: 3600
        }
    }

    /// The first reset after `now`: `snapshot.resetsAt`, or later by whole windows once that has passed.
    static func nextReset(of snapshot: QuotaSnapshot, after now: Date) -> Date {
        var reset = snapshot.resetsAt
        while reset <= now { reset += snapshot.window.length }
        return reset
    }

    /// `project` says `.unknown` of such a snapshot, whatever its weights.
    static func isLongOver(_ snapshot: QuotaSnapshot, at now: Date) -> Bool {
        now >= snapshot.resetsAt.addingTimeInterval(snapshot.window.length)
    }

    public static func project(_ snapshot: QuotaSnapshot, weights: WindowWeights, now: Date) -> Projection {
        let reset = nextReset(of: snapshot, after: now)
        // A whole window has gone by since this one closed. By the user's decision, beyond step 8: no forecast from a snapshot this old.
        if isLongOver(snapshot, at: now) {
            return Projection(
                snapshot: snapshot,
                estimatedPercent: 0,
                isEstimate: false,
                method: .windowAverage,
                outcome: .unknown,
                isStale: false,
                resetsAt: reset,
                hasRecentData: false
            )
        }

        let used = snapshot.usedPercent
        let obsolete = now >= snapshot.resetsAt
        let base = obsolete ? 0 : used
        let k = weights.calibration > 0 && used >= 1 ? used / weights.calibration : nil
        let estimate = min(100, base + (k ?? 0) * weights.afterSnapshot)

        // Percent per second. A snapshot from the instant its window opened, or before, says nothing about a pace.
        let elapsed = snapshot.observedAt.timeIntervalSince(snapshot.resetsAt.addingTimeInterval(-snapshot.window.length))
        let windowPace = !obsolete && elapsed > 0 ? used / elapsed : nil
        let recentPace = k.map { $0 * weights.recent / recentWindow }
        let pace = recentPace ?? windowPace

        let outcome: Projection.Outcome
        if let pace {
            if pace == 0 {
                outcome = .idle
            } else {
                let runOut = now.addingTimeInterval((100 - estimate) / pace)
                outcome = runOut >= reset ? .lastsUntilReset : .runsOut(at: runOut, beforeReset: reset.timeIntervalSince(runOut))
            }
        } else {
            outcome = .unknown
        }

        return Projection(
            snapshot: snapshot,
            estimatedPercent: estimate,
            isEstimate: obsolete || (k != nil && weights.afterSnapshot > 0),
            method: k != nil ? .calibrated : .windowAverage,
            outcome: outcome,
            isStale: now.timeIntervalSince(snapshot.observedAt) > staleAfter(snapshot.window),
            resetsAt: reset,
            recentPercentPerHour: recentPace.map { $0 * 3_600 },
            windowPercentPerHour: windowPace.map { $0 * 3_600 }
        )
    }

    /// Red if any quota is estimated at 90% or more; else amber if any will run out before it resets. A row with no recent data says
    /// neither.
    public static func alert(_ projections: [Projection]) -> AlertLevel {
        let current = projections.filter(\.hasRecentData)
        if current.contains(where: { $0.estimatedPercent >= 90 }) { return .red }
        let runsOut = current.contains { projection in
            if case .runsOut = projection.outcome { return true }
            return false
        }
        return runsOut ? .amber : .none
    }
}
