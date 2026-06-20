import Foundation

/// Optimal Recognition Point: the single letter the eye should land on so a word
/// is recognized fastest. RSVP feels *still* only when this pivot sits at the
/// same spot on screen every token — so the rule has to be deterministic and the
/// view has to lock the pivot's position, not the word's center.
///
/// Pure and UI-free so `CoreChecks` can pin the rule down; the view (`PivotWord`)
/// owns the actual x-locking. The split is the contract between them: a word is
/// `before` + `pivot` + `after`, and only `pivot` is anchored.
public enum ORP {
    /// Index (into the word's characters) of the pivot letter.
    ///
    /// Deterministic length-bucketed rule, leaning slightly left of center and
    /// settling around the first third as words grow — the classic RSVP feel:
    /// 1 letter → itself; 2–5 → 2nd; 6–9 → 3rd; 10–13 → 4th; 14+ → 5th.
    ///
    /// Leading punctuation (an opening quote/bracket) is skipped before counting,
    /// so `"word` pivots on the same letter `word` does — a stray quote never
    /// shoves the recognition point off the letters. Trailing punctuation rides
    /// along in the length and never reaches the early pivot, so a comma or period
    /// can't shift it either.
    public static func pivotIndex(for word: String) -> Int {
        let chars = Array(word)
        guard chars.count > 1 else { return 0 }

        var start = 0
        while start < chars.count - 1, !isCore(chars[start]) { start += 1 }

        let length = chars.count - start
        let offset: Int
        switch length {
        case ...1:    offset = 0
        case 2...5:   offset = 1
        case 6...9:   offset = 2
        case 10...13: offset = 3
        default:      offset = 4
        }
        return min(chars.count - 1, start + offset)
    }

    /// A word split around its pivot letter, for the view to lay out: `before`
    /// and `after` flow left/right while only `pivot` is locked in space.
    public struct Pivot: Equatable, Sendable {
        public let before: String
        public let pivot: String
        public let after: String

        public init(before: String, pivot: String, after: String) {
            self.before = before
            self.pivot = pivot
            self.after = after
        }
    }

    /// Split `word` into the run before the pivot, the pivot letter, and the run
    /// after. An empty word yields three empties.
    public static func split(_ word: String) -> Pivot {
        let chars = Array(word)
        guard !chars.isEmpty else { return Pivot(before: "", pivot: "", after: "") }
        let p = pivotIndex(for: word)
        let before = String(chars[0..<p])
        let pivot = String(chars[p])
        let after = p + 1 < chars.count ? String(chars[(p + 1)...]) : ""
        return Pivot(before: before, pivot: pivot, after: after)
    }

    private static func isCore(_ c: Character) -> Bool { c.isLetter || c.isNumber }
}
