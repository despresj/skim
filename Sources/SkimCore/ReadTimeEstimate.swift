import Foundation

/// Estimated reading time at a given speed, computed from Skim's *real* pacing —
/// the tokenizer's clause / sentence / paragraph / long-word delay multipliers
/// summed through `Pacing.secondsPerToken` — so a comma-heavy, paragraph-broken
/// read estimates longer than a flat words-per-minute would, matching how the read
/// actually feels. Pure and dependency-free so `CoreChecks` can verify it without
/// an app. The WPM passed in is the user's configured default cruising speed; this
/// type never assumes a hardcoded number.
public enum ReadTimeEstimate {
    /// Total on-screen seconds for a token stream at `wpm`, summing every token's
    /// own paced duration. Zero for an empty stream.
    public static func seconds(tokens: [ReadingToken], wpm: Int) -> Double {
        tokens.reduce(0.0) {
            $0 + Pacing.secondsPerToken(wpm: Double(wpm), multiplier: $1.delayMultiplier)
        }
    }

    /// Convenience: tokenize `text` with Skim's tokenizer, then estimate at `wpm`.
    public static func seconds(text: String, wpm: Int) -> Double {
        seconds(tokens: Tokenizer.tokenize(text), wpm: wpm)
    }

    /// A compact, human time label tuned for a calm reading launcher — time is the
    /// user-facing unit, never raw word count:
    ///   • under 10 minutes → `m:ss`   ("0:42", "1:42", "9:59")
    ///   • 10 minutes and up → whole minutes ("10 min", "24 min")
    /// Always non-negative; a sub-second read reads as "0:00".
    public static func compact(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 600 {
            let minutes = total / 60
            let secs = total % 60
            return "\(minutes):" + (secs < 10 ? "0\(secs)" : "\(secs)")
        }
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes) min"
    }
}
