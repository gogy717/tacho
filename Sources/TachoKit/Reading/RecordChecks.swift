import Foundation

extension JSONObject {
    /// Whether these token figures can be taken as they stand: each of `required` is a count, and each of `optional` is a count or is
    /// not there. Anything else would pass as 0, or take from a total, with nothing to say so; a figure a reader no longer finds is how
    /// a changed format shows. A null is a figure not there.
    func holdsCounts(required: [String], optional: [String] = []) -> Bool {
        required.allSatisfy(isCount) && optional.allSatisfy { isCount($0) || isMissing($0) }
    }

    /// Whether the figure is a count a call could have. Above the limit it is a damaged log: adding such a figure up would trap, at
    /// every launch, since the row stays. No call comes near it, and neither does a thread's running total.
    func isCount(_ name: String) -> Bool {
        (0...Self.largestCount).contains(int(name) ?? -1)
    }

    private static let largestCount = 1 << 40

    /// `int` alone cannot say: it is nil for a figure of the wrong type as well.
    private func isMissing(_ name: String) -> Bool {
        string(name) == nil && double(name) == nil && bool(name) == nil && object(name) == nil && array(name) == nil
    }
}

/// `text`, unless it is blank. A blank id says no more than a missing one, and as a key it would merge every call that has it.
func present(_ text: String?) -> String? {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return text
}

/// A model's answers that gave no usage, one after another: how a changed format shows when every line still parses.
///
/// Most of a log carries no usage and is never counted. An answer always has some, on its own line or on one after it, so a run
/// longer than a healthy log ever has means the reader no longer finds it. Every answer of such a run then counts as skipped, which
/// is what tells Settings that a source's format moved on (spec 3, 5.4, 7).
struct AnswersWithoutUsage: Codable, Equatable {
    /// Past the longest run of a healthy log, with room to spare.
    static let threshold = 20

    private(set) var run = 0

    /// One more answer: what it adds to the skipped count. The answer that makes the run long enough brings in the whole run, and
    /// each one after it itself.
    mutating func add() -> Int {
        run += 1
        return run < Self.threshold ? 0 : run == Self.threshold ? run : 1
    }
}
