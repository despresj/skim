import Foundation

/// Fixed output format + card durations for a Skim export video. Kept in the pure
/// core (no AVFoundation) so the timeline math is testable by `CoreChecks`; the app
/// layer reads these constants when it configures the actual `AVAssetWriter`.
public enum ExportSpec {
    /// 9:16 vertical, 1080×1920, 30 fps — the v1 output contract.
    public static let width = 1080
    public static let height = 1920
    public static let fps = 30

    /// How long the optional title card and the closing card hold (seconds). Inside
    /// the spec's 1.5–2.0s window.
    public static let titleCardDuration = 1.8
    public static let endCardDuration = 1.8

    /// Reject exports with fewer real words than this — a one- or two-word "video"
    /// isn't worth rendering and reads as a mistake.
    public static let minimumTokens = 5

    /// Soft warning threshold: past this the render takes a noticeable while, so the
    /// UI surfaces "this export may take a while" without blocking it.
    public static let longExportTokens = 1500

    /// `m:ss` for a duration label, e.g. 102s → "1:42". Always at least `0:SS`.
    public static func formatted(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let secs = total % 60
        return "\(minutes):" + (secs < 10 ? "0\(secs)" : "\(secs)")
    }
}

/// What the export should draw at a given instant: the title card, a specific
/// reading token, or the end card. The renderer switches on this per frame.
public enum ExportPhase: Equatable, Sendable {
    case title
    case reading(tokenIndex: Int)
    case end
}

/// The full time layout of an export video, derived purely from the token stream
/// and WPM using Skim's real pacing (`Pacing.secondsPerToken`). It is the single
/// source of truth for both the estimated-duration label shown before export and
/// the per-frame "what word is on screen now" decision during render — so the
/// estimate can never drift from what actually gets written.
///
/// Time runs on one absolute axis: `[0, titleDuration)` is the title card (zero
/// length when there's no title), then the reading section, then the end card.
public struct ExportTimeline: Sendable {
    public let fps: Int
    public let wpm: Int

    /// Title card length in seconds — `0` when no title, so the reading section
    /// starts immediately.
    public let titleDuration: Double
    public let endDuration: Double

    /// Start time (seconds, within the reading section) and on-screen duration of
    /// each reading token, index-aligned. Empty for an empty token stream.
    public let tokenStarts: [Double]
    public let tokenDurations: [Double]

    /// Sum of every token's on-screen time — the reading section's length.
    public let readingDuration: Double

    /// Build a timeline. `titleDuration` should be `0` when there is no title card;
    /// the caller decides (an empty title means no card). Durations come straight
    /// from `Pacing.secondsPerToken(wpm:multiplier:)`, so the export honors the same
    /// clause/sentence/paragraph/long-word rhythm as the live reader.
    public init(
        tokens: [ReadingToken],
        wpm: Int,
        fps: Int = ExportSpec.fps,
        titleDuration: Double,
        endDuration: Double
    ) {
        self.fps = fps
        self.wpm = wpm
        self.titleDuration = max(0, titleDuration)
        self.endDuration = max(0, endDuration)

        var starts: [Double] = []
        var durations: [Double] = []
        starts.reserveCapacity(tokens.count)
        durations.reserveCapacity(tokens.count)

        var cursor = 0.0
        for token in tokens {
            let d = Pacing.secondsPerToken(wpm: Double(wpm), multiplier: token.delayMultiplier)
            starts.append(cursor)
            durations.append(d)
            cursor += d
        }

        self.tokenStarts = starts
        self.tokenDurations = durations
        self.readingDuration = cursor
    }

    /// Total video length: title card + reading + end card.
    public var totalDuration: Double { titleDuration + readingDuration + endDuration }

    /// Number of 1/`fps`-second frames to write. Rounded so the last frame lands on
    /// or just past `totalDuration`.
    public var totalFrames: Int { Int((totalDuration * Double(fps)).rounded()) }

    /// Absolute start time (seconds) of the reading section.
    public var readingStart: Double { titleDuration }

    /// What to draw at absolute time `t`. Clamped: negative times read as the first
    /// phase, times past the end read as the end card.
    public func phase(atTime t: Double) -> ExportPhase {
        if titleDuration > 0, t < titleDuration { return .title }

        let rt = t - titleDuration
        if rt < readingDuration, !tokenStarts.isEmpty {
            return .reading(tokenIndex: tokenIndex(atReadingTime: rt))
        }
        return .end
    }

    /// What to draw at frame `f` (presentation time `f / fps`).
    public func phase(atFrame f: Int) -> ExportPhase {
        phase(atTime: Double(f) / Double(fps))
    }

    /// Index of the token on screen at `rt` seconds into the reading section.
    /// Binary search over `tokenStarts`; clamps into range.
    private func tokenIndex(atReadingTime rt: Double) -> Int {
        guard !tokenStarts.isEmpty else { return 0 }
        if rt <= 0 { return 0 }

        // Largest index whose start is <= rt.
        var lo = 0
        var hi = tokenStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if tokenStarts[mid] <= rt { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
