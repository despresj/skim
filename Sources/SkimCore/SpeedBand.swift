import Foundation

/// A discrete reading speed in words-per-minute. Speeds step in fine 25-WPM
/// increments from a calm 300 up to a 1000 blast, so a vertical thumb slide
/// nudges pace smoothly. The user still feels "slower / faster" plus a soft
/// descriptive label; the exact number is secondary.
public struct SpeedBand: Equatable, Sendable {
    /// Words-per-minute for this speed.
    public let wpm: Int

    public init(wpm: Int) { self.wpm = wpm }

    /// WPM as a Double, for pacing math.
    public var rawValue: Double { Double(wpm) }

    /// Slowest / fastest speeds and the gap between steps.
    public static let minWPM = 300
    public static let maxWPM = 1000
    public static let step = 25

    /// All speeds, slowest → fastest.
    public static let allCases: [SpeedBand] =
        stride(from: minWPM, through: maxWPM, by: step).map(SpeedBand.init(wpm:))

    /// A comfortable starting speed near the calm end. Sits squarely in the
    /// "Cruise" band so a first-run / demo opens calm and inviting — never at a
    /// scary Blast — leaving the upper speeds as something you deliberately ramp into.
    public static let cruise = SpeedBand(wpm: 400)

    /// Next faster speed, clamped at `maxWPM`.
    public func faster() -> SpeedBand { SpeedBand(wpm: min(Self.maxWPM, wpm + Self.step)) }

    /// Next slower speed, clamped at `minWPM`.
    public func slower() -> SpeedBand { SpeedBand(wpm: max(Self.minWPM, wpm - Self.step)) }

    /// Reading "temperature" of this speed, normalized 0…1 across the full band
    /// range: 0 at the slowest band, 1 at the fastest. The view layer maps this
    /// onto a subtle amber warmth (background glow, dial, pivot, progress) so the
    /// surface feels calmer when slow and more energized when fast — an *energy*
    /// state, never an alarm. Pure number here; the palette mapping stays in the
    /// views. Tracks the dial fill exactly, since both span `minWPM…maxWPM`.
    public var warmth: Double {
        let span = Double(Self.maxWPM - Self.minWPM)
        guard span > 0 else { return 0 }
        let clamped = min(max(wpm, Self.minWPM), Self.maxWPM)
        return Double(clamped - Self.minWPM) / span
    }

    /// Soft descriptive band for temporary overlays — kept coarse so reading
    /// stays a feel, not a dial. The precise WPM is shown alongside it.
    public var label: String {
        switch wpm {
        case ..<350: return "Calm"
        case ..<450: return "Cruise"
        case ..<550: return "Fast"
        case ..<650: return "Sprint"
        default:     return "Blast"
        }
    }
}
