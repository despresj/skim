import UIKit

/// Invisible UI confirmation. Subtle by design — the goal is confidence, not noise.
@MainActor
final class Haptics {
    enum Event {
        case start       // began reading
        case pause       // released / paused
        case bandChange  // speed band changed
        case finish      // reached the end
    }

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)

    func tick(_ event: Event) {
        switch event {
        case .start:      light.impactOccurred(intensity: 0.7)
        case .pause:      soft.impactOccurred(intensity: 0.5)
        case .bandChange: light.impactOccurred(intensity: 0.4)
        case .finish:     heavy.impactOccurred()
        }
    }
}
