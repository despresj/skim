import UIKit

/// Invisible UI confirmation. Subtle by design — the goal is confidence, not noise.
@MainActor
final class Haptics {
    enum Event {
        case start       // began reading
        case pause       // released / paused
        case bandChange  // speed band changed
        case cruiseOn    // entered hands-free cruise
        case rewind      // flicked left — jumped back 12 words
        case forward     // flicked right — jumped ahead 12 words
        case finish      // reached the end
    }

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let selection = UISelectionFeedbackGenerator()

    /// Warm the detent generators so the first click fires without the
    /// first-call latency. Called when a hold begins, since that's when the
    /// rapid swipe-up/down band clicks follow.
    func prepare() {
        selection.prepare()
        rigid.prepare()
    }

    func tick(_ event: Event) {
        switch event {
        case .start:      light.impactOccurred(intensity: 0.7)
        case .pause:      soft.impactOccurred(intensity: 0.5)
        case .bandChange:
            // A crisp detent "click" as you cross each speed step — the same
            // feedback iOS pickers use — plus a sharp rigid tap for a mechanical
            // notch feel. Re-prepared so back-to-back clicks stay snappy.
            selection.selectionChanged()
            rigid.impactOccurred(intensity: 0.6)
            selection.prepare()
        case .cruiseOn:
            // Two soft ticks — engaging autopilot feels different from the single
            // tick of grabbing the wheel.
            light.impactOccurred(intensity: 0.6)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                self?.light.impactOccurred(intensity: 0.6)
            }
        case .rewind:     medium.impactOccurred(intensity: 0.7)
        case .forward:    medium.impactOccurred(intensity: 0.5)
        case .finish:     heavy.impactOccurred()
        }
    }
}
