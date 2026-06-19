import Foundation

/// Discrete reading speeds. The user feels "slower / faster", never an exact
/// WPM number. Raw value is words-per-minute.
public enum SpeedBand: Double, CaseIterable, Sendable {
    case slow = 225
    case cruise = 300
    case fast = 400
    case sprint = 525
    case blast = 650

    /// Bands ordered slow → blast, used to step up and down.
    private static let ordered = SpeedBand.allCases.sorted { $0.rawValue < $1.rawValue }

    /// Next faster band, clamped at `.blast`.
    public func faster() -> SpeedBand {
        let ordered = SpeedBand.ordered
        guard let i = ordered.firstIndex(of: self), i + 1 < ordered.count else { return self }
        return ordered[i + 1]
    }

    /// Next slower band, clamped at `.slow`.
    public func slower() -> SpeedBand {
        let ordered = SpeedBand.ordered
        guard let i = ordered.firstIndex(of: self), i > 0 else { return self }
        return ordered[i - 1]
    }

    /// Short label for temporary overlays, e.g. "Cruise".
    public var label: String {
        switch self {
        case .slow: return "Slow"
        case .cruise: return "Cruise"
        case .fast: return "Fast"
        case .sprint: return "Sprint"
        case .blast: return "Blast"
        }
    }
}
