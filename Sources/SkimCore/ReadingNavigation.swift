import Foundation

/// Pure index math for the rail's rewind/fast-forward flicks. Kept in the core so
/// the "never negative, never past the end" guarantee is verified by `CoreChecks`
/// rather than trusted to inline arithmetic at the gesture call site.
public enum ReadingNavigation {
    /// The landing index for a flick that moves `distance` words from `index`
    /// (negative = rewind, positive = fast-forward), clamped to a valid token at
    /// `[0, count - 1]`. With no tokens the cursor stays pinned at 0, so a flick on
    /// an empty read is a safe no-op rather than a negative or out-of-range index.
    public static func jumpTarget(from index: Int, by distance: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(count - 1, index + distance))
    }
}
