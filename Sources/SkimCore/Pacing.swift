import Foundation

/// Timing math for the playback loop. Pure and side-effect free so it can be
/// unit-tested without an app.
public enum Pacing {
    /// Seconds a token should remain on screen, given the current speed band's
    /// words-per-minute and the token's own delay multiplier.
    public static func secondsPerToken(wpm: Double, multiplier: Double) -> Double {
        guard wpm > 0 else { return 0 }
        return (60.0 / wpm) * multiplier
    }

    public static func secondsPerToken(band: SpeedBand, multiplier: Double) -> Double {
        secondsPerToken(wpm: band.rawValue, multiplier: multiplier)
    }
}
