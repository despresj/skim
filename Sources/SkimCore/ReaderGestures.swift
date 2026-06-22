import Foundation

/// Pure, UI-free resolution of the reading surface's gesture model — extracted
/// from `ReadingView` so the "what does this touch mean?" decision is one
/// deterministic place that `CoreChecks` can exercise without a device.
///
/// The mental model is one large reading surface, no hidden left/right zones:
///
///   • Hold anywhere — press and hold on the open surface starts a precision
///     read; releasing pauses it. Global: the same from the far left, the
///     center, the right, the active word, or the context strip.
///   • Tap anywhere — a single tap brakes *only while cruising* (else no-op); a
///     double tap toggles Cruise on/off. Also global, no carve-out by side.
///   • Steer on the rail — a vertical slide changes speed, a horizontal flick
///     jumps ±12 words. These are the *only* rail-scoped gestures: they fire
///     just for a touch that began in the thumb rail, so the basic "make words
///     move" actions never depend on finding the rail, but the easy-to-trigger
///     speed/skip steering stays off the bare canvas.
///
/// Explicit controls (settings/export/ideas, back chevron, scrubber, new-text
/// chip) sit *above* this surface layer and consume their own taps, so they
/// never reach here. `ReadingView` routes its handlers through these functions
/// so the behavior on device is exactly what the assertions below check.
public enum GestureZone: Equatable, Sendable {
    case canvas
    case rail
}

/// A discrete tap the surface can resolve to a reader action. Both fire from
/// anywhere on the open surface — there is no per-side semantics.
public enum SurfaceTap: Equatable, Sendable {
    case single
    case double
}

/// The rail's steering gestures — the only gestures scoped to the thumb rail.
public enum RailSteer: Equatable, Sendable {
    case slide
    case flickBack
    case flickForward
}

/// The action a resolved gesture asks the view model to take. Each maps to one
/// `ReaderViewModel` entry point; `none` means the gesture is intentionally inert.
public enum ReaderIntent: Equatable, Sendable {
    case none
    case toggleCruise        // ReaderViewModel.toggleCruise()
    case pauseCruise         // ReaderViewModel.pauseCruise()
    case beginPrecisionRead  // ReaderViewModel.startHolding()
    case changeSpeed         // ReaderViewModel.setBandIndex(_:)
    case rewind              // ReaderViewModel.rewind12Words()
    case forward             // ReaderViewModel.forward12Words()
}

public enum ReaderGestures {

    /// Which zone a touch at horizontal position `touchX` falls in, given the rail
    /// occupies `controlFraction` of `width` on the reading-hand edge. The zone no
    /// longer changes what a hold or tap *means* — those are global — it only gates
    /// the rail-scoped steering (`steerIntent`): right-handers' rail hugs the
    /// trailing edge, left-handers' the leading edge, mirror-symmetric.
    public static func zone(touchX: Double,
                            width: Double,
                            controlFraction: Double,
                            leftHanded: Bool) -> GestureZone {
        guard width > 0 else { return .canvas }
        let railWidth = width * controlFraction
        let inRail = leftHanded ? (touchX <= railWidth)
                                : (touchX >= width - railWidth)
        return inRail ? .rail : .canvas
    }

    /// What a press-and-hold means, by the state the press began in. From a resting
    /// state (ready/paused) a hold grabs the engine and reads; mid-cruise the words
    /// already stream hands-free so a hold takes no precision read, and mid-hold or
    /// on the idle/completed surfaces it's inert. Global — the same anywhere on the
    /// open surface, rail or bare canvas.
    public static func holdIntent(startState: ReaderState) -> ReaderIntent {
        switch startState {
        case .ready, .paused: return .beginPrecisionRead
        case .idle, .precisionHeld, .cruisePlaying, .completed: return .none
        }
    }

    /// What a surface tap means in the current state. A double tap hands off to /
    /// back from cruise; a single tap is the brake and *only* does something while
    /// cruising (so an accidental brush at rest never starts or stops anything).
    /// Global — identical from any patch of the open surface, either hand.
    public static func tapIntent(_ tap: SurfaceTap, state: ReaderState) -> ReaderIntent {
        switch tap {
        case .double:
            switch state {
            case .ready, .paused, .cruisePlaying: return .toggleCruise
            case .idle, .precisionHeld, .completed: return .none
            }
        case .single:
            return state == .cruisePlaying ? .pauseCruise : .none
        }
    }

    /// What a rail steer means. Steering is the rail's exclusive job: it fires only
    /// for a gesture that *began* in the rail zone (`startZone == .rail`) and only in
    /// a live session — a slide changes speed, a flick jumps ±12 words. A canvas-
    /// started gesture never steers, so a hold-to-read out on the bare surface can't
    /// drift the speed or fire a skip, and the idle/completed surfaces are inert.
    public static func steerIntent(_ steer: RailSteer,
                                   startZone: GestureZone,
                                   startState: ReaderState) -> ReaderIntent {
        guard startZone == .rail, startState != .idle, startState != .completed else {
            return .none
        }
        switch steer {
        case .slide:         return .changeSpeed
        case .flickBack:     return .rewind
        case .flickForward:  return .forward
        }
    }
}
