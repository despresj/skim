import Foundation

/// The auto-start speed ramp: a pure curve from a slow opening speed up to a target
/// cruising speed, sampled by elapsed time. Explicit "read this now" imports open
/// *gently* — starting at `fromWPM` and easing to `toWPM` over `duration` — instead
/// of snapping straight to full speed, which feels like a punch in the eyes. The
/// easing is smoothstep (zero slope at both ends), so the open and the arrival are
/// both calm and physical: no jolt, no overshoot, no robotic linear stepping. Each
/// sample is snapped to a real `SpeedBand`, so the speed gauge's detents and needle
/// stay valid all the way up and the warm color system rides along for free.
///
/// Pure and UI-free so `CoreChecks` can exercise the curve without a simulator.
public struct SpeedRamp: Equatable, Sendable {
    public let fromWPM: Int
    public let toWPM: Int
    public let duration: Double

    public init(fromWPM: Int, toWPM: Int, duration: Double) {
        self.fromWPM = fromWPM
        self.toWPM = toWPM
        self.duration = duration
    }

    /// Smoothstep-eased progress (0…1) at `elapsed` seconds. Clamped at both ends:
    /// `elapsed ≤ 0` → 0, `elapsed ≥ duration` → 1. `s(t) = t²(3 − 2t)` has zero
    /// slope at t=0 and t=1, so speed eases in from rest and settles onto the
    /// target rather than arriving at full tilt.
    public func easedFraction(at elapsed: Double) -> Double {
        guard duration > 0 else { return 1 }
        let t = min(1, max(0, elapsed / duration))
        return t * t * (3 - 2 * t)
    }

    /// Continuous (un-snapped) words-per-minute at `elapsed` seconds along the
    /// eased curve — `fromWPM` at the start, `toWPM` once the ramp completes.
    public func wpm(at elapsed: Double) -> Double {
        Double(fromWPM) + Double(toWPM - fromWPM) * easedFraction(at: elapsed)
    }

    /// The eased WPM at `elapsed`, snapped to the nearest real `SpeedBand` so the
    /// gauge stays on its detents. Never slower than the speed floor, never faster
    /// than the target — so the ramp can't visibly overshoot past where it's headed.
    public func band(at elapsed: Double) -> SpeedBand {
        let capped = min(max(wpm(at: elapsed), Double(SpeedBand.minWPM)), Double(toWPM))
        return SpeedBand.allCases.min(by: {
            abs($0.rawValue - capped) < abs($1.rawValue - capped)
        }) ?? SpeedBand(wpm: toWPM)
    }

    /// Whether the ramp actually has speed to climb. A ramp that opens at or above
    /// its target (or has a non-positive duration) is a no-op — the caller should
    /// just land on the target and skip the animation.
    public var isClimbing: Bool { fromWPM < toWPM && duration > 0 }
}
