import Foundation

/// How fast a model writes its output, typically.
public struct ModelSpeed: Equatable, Sendable {
    public var model: String
    /// The median of the requests that count.
    public var tokensPerSecond: Double
    public var samples: Int
    /// Some of those requests were timed by an approximate start, so the figure is shown as approximate.
    public var approximate: Bool

    public init(model: String, tokensPerSecond: Double, samples: Int, approximate: Bool) {
        self.model = model
        self.tokensPerSecond = tokensPerSecond
        self.samples = samples
        self.approximate = approximate
    }
}

/// Output speed, for reference only (spec §5.5).
public enum GenerationSpeed {
    public static let minOutputTokens = 50
    public static let minSeconds = 0.5

    /// One request's speed: by its exact generation time when it has one, else by `time − startTime`, which is approximate.
    ///
    /// Nil when the request is too short to mean anything. That includes a negative duration: `startTime` is a guess and
    /// can land after `time`, and `duration − ttft` can come out below zero.
    public static func rate(_ s: SpeedSample) -> (tokensPerSecond: Double, approximate: Bool)? {
        guard s.output >= minOutputTokens else { return nil }
        let seconds: TimeInterval
        let approximate: Bool
        if let generationMs = s.generationMs {
            seconds = generationMs / 1_000
            approximate = false
        } else if let startTime = s.startTime {
            seconds = s.time.timeIntervalSince(startTime)
            approximate = true
        } else {
            return nil
        }
        guard seconds >= minSeconds else { return nil }
        return (Double(s.output) / seconds, approximate)
    }

    /// Every model with a sample that counts, most samples first, then by name.
    public static func medians(_ samples: [SpeedSample]) -> [ModelSpeed] {
        var rates: [String: [(tokensPerSecond: Double, approximate: Bool)]] = [:]
        for sample in samples {
            if let rate = rate(sample) { rates[sample.model, default: []].append(rate) }
        }
        return rates
            .map { model, rates in
                ModelSpeed(
                    model: model,
                    tokensPerSecond: median(rates.map(\.tokensPerSecond)),
                    samples: rates.count,
                    approximate: rates.contains { $0.approximate }
                )
            }
            .sorted { ($1.samples, $0.model) < ($0.samples, $1.model) }
    }

    /// `values` must not be empty.
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
