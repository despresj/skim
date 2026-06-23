import SwiftUI
import UIKit

/// The sacred reading surface. Almost nothing on screen: the current word riding
/// high on its pivot, a tiny progress line, and a thumb rail you hold to read and
/// steer like a joystick — slide up/down for speed, flick ←/→ to replay/skip.
struct ReadingView: View {
    let viewModel: ReaderViewModel
    let ideas: IdeasViewModel

    /// Whether the Ideas scratchpad sheet is up.
    @State private var showingIdeas = false

    /// Whether the Settings sheet is up.
    @State private var showingSettings = false

    /// The Export Questions sheet for the current read, built lazily so it captures
    /// the read's text, title, and current WPM at the moment it opens.
    @State private var exportVM: ExportViewModel?

    /// Defaults key for the one-time gesture coaching flag.
    private static let hintsSeenKey = "skim.hasSeenGestureHints"

    /// First-run gesture coaching. Read once from defaults so it appears on the
    /// very first reader entry, then is dismissed for good. It teaches, it doesn't
    /// gate: a deep-link/file import keeps streaming underneath while it's up.
    @State private var showGestureHints = !UserDefaults.standard.bool(forKey: ReadingView.hintsSeenKey)

    /// Honor Reduce Motion: warmth still *changes* color with speed, but the
    /// crossfade is dropped so nothing animates or pulses. Color never carries the
    /// speed alone — the dial's label and WPM always state it.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width (points) of the **Gauge Control Zone** — the reserved vertical strip on
    /// the reading-hand edge that owns the gauge, its halo, and all speed steering
    /// (slide/flick). One source of truth so the three things that must agree do:
    /// the text never enters it, steering only fires inside it, and threadline
    /// scrolling only fires outside it. Covers the ~80pt dial + halo + touch +
    /// breathing room. Mirrors to the leading edge in left-hand mode.
    private let gaugeZoneWidth: CGFloat = 118

    /// Vertical travel (points) that spans the entire speed range, so the full
    /// slow→fast sweep is reachable in one comfortable thumb slide no matter how
    /// many bands there are (the per-band step is derived from this and the band
    /// count, rather than a fixed step that gets unreachable as bands multiply).
    private let slideSpan: CGFloat = 240

    /// Movement (points) from the gesture origin before any axis commits. Inside
    /// it the thumb is "neutral" — just holding/reading — which keeps a steady
    /// press from drifting the speed or firing a flick.
    private let deadzone: CGFloat = 18

    /// Horizontal travel (points) that turns a sideways move into a flick.
    private let flickThreshold: CGFloat = 44

    /// How long the thumb must rest on the rail before a precision read engages.
    /// This is the whole "tap ≠ hold" boundary: a quick tap (or an accidental
    /// brush) lifts before this elapses and is a true no-op, while a deliberate
    /// hold crosses it and starts reading. Kept small so a real hold still feels
    /// immediate; raise it if taps still leak a read, drop it toward 0 to restore
    /// the old "read on touch-down" feel. The rail's *steering* (slide/flick) is
    /// not gated — only the read-start is.
    private let minHoldToRead: Double = 0.12

    /// Opt-in gesture-zone debug instrumentation. Set the `SKIM_GESTURE_DEBUG`
    /// env var (Xcode scheme) to tint the rail/canvas hit zones and log which zone
    /// received each tap. Never on in a normal run — purely a development aid.
    private static let gestureDebug =
        ProcessInfo.processInfo.environment["SKIM_GESTURE_DEBUG"] != nil

    /// X-position of the locked pivot center, measured from the leading edge. Set
    /// so the focal column sits in the left third — room for the short lead-in to
    /// its left and the long tail to flow right — for either reading hand. Even on
    /// the narrowest iPhone this stays left of center.
    private let pivotAnchorX: CGFloat = 110

    // Live gesture state for the axis-locked joystick.
    @State private var gestureActive = false
    @State private var speedBaseline = 0
    @State private var axis: DragAxis?
    @State private var flickArmed = true
    /// True only while the thumb is actively turning the dial (a committed vertical
    /// rail steer). Drives the dial's live readout/glow so a speed change shows its
    /// numbers as feedback even mid-cruise, then quiets again on release.
    @State private var adjustingSpeed = false
    /// The reader's state when the current surface gesture began. Lets a hold
    /// behave differently mid-cruise (no precision read) than from a resting state
    /// (grab the wheel and read).
    @State private var gestureStartState: ReaderState = .ready

    /// Which zone the current surface gesture *started* in. Hold and tap are global,
    /// but steering (slide/flick) only fires when the press began on the rail — so a
    /// hold-to-read out on the bare canvas can't drift the speed or fire a skip.
    @State private var gestureStartZone: GestureZone = .canvas

    // MARK: Paused-Threadline gesture arbitration (band owns its own touches)
    //
    // The paused Threadline is a front interactive layer whose UITextView owns its
    // pan (native momentum scroll), a long-press (hold-to-read), and a double-tap
    // (Cruise). So when a press *begins inside the band*, the global surface gesture
    // yields entirely — it never double-handles those touches.

    /// A press that began inside the paused Threadline band: the band's own UIKit
    /// recognizers own it, so the surface gesture yields (no hold, no steer).
    @State private var yieldToThreadline = false
    /// A read that was started by a hold *inside* the Threadline band. Keeps the
    /// band layer mounted through the hold so its long-press `.ended` can pause,
    /// even though the reader has left `.paused`.
    @State private var holdStartedInThreadline = false

    /// Fade level for the flick confirmation. Snapped to 1 on each jump, then
    /// eased back to 0 — so the label flashes and dissolves without lingering.
    @State private var navFlashOpacity: Double = 0

    /// The pending "begin precision read" timer for the current rail press. Armed
    /// on touch-down (from a resting state) and fired only once the thumb has
    /// rested past `minHoldToRead`; cancelled the instant the press becomes a
    /// steer (slide/flick commits an axis) or lifts early — so a rail tap never
    /// starts a read. `nil` when no read is pending.
    @State private var holdReadTask: Task<Void, Never>?

    /// Rolling tail of gesture-zone debug lines, shown in the corner overlay when
    /// `gestureDebug` is on. Empty (and unused) in a normal run.
    @State private var debugLog: [String] = []

    private enum DragAxis { case vertical, horizontal }

    private var isHolding: Bool { viewModel.state == .precisionHeld }
    private var leftHanded: Bool { viewModel.isLeftHanded }

    /// The reader's mode as the gauge presents it — the gauge is the single source of
    /// truth for speed *and* reading mode (there's no separate top-center indicator).
    /// `.paused` covers both rest states (ready/paused); idle/completed never show the
    /// gauge so they fold in harmlessly.
    private var gaugeState: GaugeState {
        switch viewModel.state {
        case .precisionHeld: return .manual
        case .cruisePlaying: return .cruise
        default:             return .paused
        }
    }

    /// The dial's lit (amber, engaged) look: on while actually reading — a precision
    /// hold or cruise — and while the thumb is turning the dial; dim and calm at rest.
    private var dialIsActive: Bool { gaugeState != .paused || adjustingSpeed }

    /// Gauge-halo energy (0…1) by mode — brightness only, never footprint (see
    /// `ReadingWarmth`). Cruise burns warmest (committed autopilot), a held thumb
    /// sits between, parked is a faint hint; turning the dial briefly lifts it so
    /// the instrument reads as "adjusting."
    private var auraIntensity: Double {
        if viewModel.isCruising { return 1.0 }
        // A held thumb clearly lights the gauge — this localized halo is now the
        // primary "you are holding to read" signal (the wide edge wash is gone).
        if viewModel.isHoldingToRead || adjustingSpeed { return 0.85 }
        return 0.4
    }

    // MARK: Gesture model
    //
    // One large reading surface, no hidden left/right zones. A single full-surface
    // `readingSurfaceGestureLayer` owns the basic actions everywhere; the thumb rail
    // only *adds* steering. Every explicit control is drawn *above* the surface
    // layer, so the front-most-wins hit test lets each consume its own touch first:
    //
    //   1. Reading surface — the whole open canvas (`readingSurfaceGestureLayer`).
    //      Press-and-hold anywhere → read; release → pause; double tap → toggle
    //      Cruise; single tap → brake *only while cruising*. All global and
    //      side-independent — left, center, right, the active word, the context
    //      strip all behave the same.
    //   2. Gauge Control Zone — the reading-hand `gaugeZoneWidth` strip (drawn by
    //      `controlZone`, but non-interactive). It owns the gauge + halo and is the
    //      steering lane: a gesture that *begins* here can slide→speed or flick→±12,
    //      and threadline scrolling never starts here. The text column ends where
    //      this strip begins, so the two never compete. Hold/tap stay global
    //      (read/cruise from anywhere); a Text-Zone gesture never steers, and a
    //      Gauge-Zone gesture never scrolls the context.
    //   3. Utility controls — settings/export/lightbulb, back chevron, scrubber,
    //      new-text chip. Each consumes only its own tap; none leak to the surface
    //      because each sits above the surface layer and intercepts first.
    //
    // Run with SKIM_GESTURE_DEBUG set to see these zones tinted and logged.
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ReadingCanvas()

                ReadingWarmth(warmth: viewModel.speedWarmth, leftHanded: leftHanded,
                              intensity: auraIntensity)

                topContent(height: geo.size.height, width: geo.size.width)

                bottomContent(height: geo.size.height)

                readingSurfaceGestureLayer(size: geo.size)

                pausedThreadlineLayer(size: geo.size)

                navFlashLayer

                controlZone(width: gaugeZoneWidth)

                editControl

                utilityRail

                newTextChip

                // Front-most so its drag strip wins over the thumb rail where they
                // overlap at the foot of the screen.
                scrubberLayer

                // Dev-only zone visualizer. Never hit-testable, so it can sit on
                // top without ever changing which layer owns a touch.
                gestureDebugOverlay(railWidth: gaugeZoneWidth)

                // Topmost of all: one-time gesture coaching, above even the
                // scrubber so its dimmed backdrop covers the whole surface.
                if showGestureHints {
                    GestureHintsOverlay(onDismiss: dismissGestureHints)
                        .transition(.opacity)
                }
            }
            // One source of truth for the warmth crossfade: when the band changes,
            // every speed-driven color (glow, rail, dial, pivot, progress) eases
            // together over a beat. Keyed on `speedWarmth` so a stray word advance
            // never animates color — only an actual speed change does. Dropped
            // under Reduce Motion: the colors snap instead.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25),
                       value: viewModel.speedWarmth)
            // The Ideas scratchpad. Opening pauses cruise; closing resumes it only
            // if it was On — the reading position is never lost either way.
            .sheet(isPresented: $showingIdeas, onDismiss: { viewModel.overlayDismissed() }) {
                IdeasView(ideas: ideas, capture: { viewModel.ideaCapture })
            }
            // Settings pauses cruise on open and resumes it on close if it was On,
            // same as the Ideas panel — the reading position is never lost.
            .sheet(isPresented: $showingSettings, onDismiss: { viewModel.overlayDismissed() }) {
                SettingsView(viewModel: viewModel)
            }
            // Export is an action on the current read. Opening it already paused any
            // cruise; it stays paused on dismiss (no auto-resume), so there's no
            // overlay resume hook here.
            .sheet(item: $exportVM) { vm in
                ExportView(viewModel: vm)
            }
        }
    }

    // MARK: Secondary action rail (export + ideas)

    // MARK: Top-left utility rail (settings · export · ideas)

    /// The utility rail gathers the screen's *tools* in the top-left, so the
    /// bottom-right reading zone (toast, progress, scrubber, thumb rail, context)
    /// stays clean — tools live top-left, reading control lives right/bottom, the
    /// word owns the center. Three soft circular controls on one left x-axis, top →
    /// bottom: Settings, Video export (film, accent — "make a video of this read"),
    /// and Ideas (lightbulb, muted). It tucks just under the status bar, well above
    /// both the active word and the centered rewind chevron. The whole rail fades
    /// together — clear at rest, a quiet whisper while streaming, gone during a thumb
    /// hold — so it never competes with the focal word.
    private var utilityRail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    utilityButton(icon: "gearshape", label: "Settings",
                                  tint: .readingMuted, action: openSettings)
                    utilityButton(icon: "film.fill", label: "Export reading video",
                                  tint: .readingAccent, action: openExport)
                    utilityButton(icon: "lightbulb", label: "Add idea",
                                  tint: .readingMuted, action: openIdeas)
                }
                .padding(.leading, 16)
                Spacer(minLength: 0)
            }
            // Just below the status bar / Dynamic Island.
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .opacity(utilityOpacity)
        .allowsHitTesting(utilityOpacity > 0.2)
        .animation(.easeOut(duration: 0.22), value: utilityOpacity)
    }

    /// One floating circular control in the utility rail — shared size and style so
    /// the three tools read as a set. 44pt meets the touch-target minimum.
    private func utilityButton(icon: String, label: String, tint: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(Color.readingSurface.opacity(0.6), in: Circle())
                .overlay(Circle().stroke(Color.readingBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// How present the utility rail is. Full while parked (ready/paused) — these are
    /// setup/inspection tools and they belong to the parked surface. Gone entirely
    /// while actively reading (a thumb hold *or* cruise) and on idle/completed:
    /// active reading is for reading, not configuration, and visible tools there
    /// would blur whether the reader is parked or driving.
    private var utilityOpacity: Double {
        viewModel.shouldShowPauseChrome ? 1 : 0
    }

    /// Pause a running cruise (the read shouldn't advance behind the sheet), then
    /// open Export for the current read — its prose, saved title, and current speed.
    /// We deliberately don't auto-resume on dismiss: the safe default is to stay put.
    private func openExport() {
        dbg("control tap: export")
        if viewModel.state == .cruisePlaying { viewModel.pauseCruise() }
        exportVM = ExportViewModel(
            text: viewModel.reviewText,
            title: viewModel.currentTitle ?? "",
            wpm: viewModel.wpm)
    }

    private func openIdeas() {
        dbg("control tap: ideas")
        viewModel.overlayPresented()
        showingIdeas = true
    }

    private func openSettings() {
        dbg("control tap: settings")
        viewModel.overlayPresented()
        showingSettings = true
    }

    /// Bank the "seen" flag so the coaching never returns, and fade it out.
    private func dismissGestureHints() {
        UserDefaults.standard.set(true, forKey: Self.hintsSeenKey)
        withAnimation(.easeOut(duration: 0.22)) { showGestureHints = false }
    }

    // MARK: Word (rides high, anchored on the reading-hand side)

    private func topContent(height: CGFloat, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            PivotWord(word: viewModel.currentToken?.text ?? "",
                      anchorX: pivotAnchorX,
                      containerWidth: width,
                      warmth: viewModel.speedWarmth)
                // Hold the baseline steady; no per-word animation/jitter.
                .animation(nil, value: viewModel.currentIndex)
                // Drop into a deliberate upper focal zone — clearly off the
                // status bar / Dynamic Island, so the hero word reads as placed,
                // not stranded in the corner, and holds a repeatable spot.
                .padding(.top, height * 0.25)
            Spacer(minLength: 0)
        }
    }

    // MARK: Context strip + progress (foot of the screen)

    /// The context strip belongs to the *resting* surface — shown at the ready and
    /// when paused (a scrub holds the reader paused, so it stays up and re-anchors
    /// as you drag). It is deliberately gone during an active hold or cruise: while
    /// words actually stream, the focal pivot word is the whole surface, and a
    /// paragraph re-flowing at the foot would only add motion and compete. Hidden on
    /// the completion screen and when nothing's loaded.
    private var showsContext: Bool { viewModel.shouldShowContext }

    /// Any live reading session (not idle/completed). Keeps the progress scrubber
    /// present and seekable even while cruising — where the context strip itself is
    /// hidden, the scrubber shouldn't disappear with it.
    private var inSession: Bool {
        viewModel.hasText &&
        (viewModel.state == .ready || viewModel.state == .precisionHeld ||
         viewModel.state == .paused || viewModel.state == .cruisePlaying)
    }

    private func bottomContent(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer()
            // The context lives *behind* the gesture surface and never takes touches
            // (`.allowsHitTesting(false)` below), so the reader owns every tap/hold —
            // no dead zones. At rest (`.ready`) it's the calm static band; when paused
            // it's the taller auto-centered Threadline. Both sit in a simple reserved
            // column (no text wrapping around controls): a normal margin on the open
            // side, a wider reserve on the side the gauge / back button occupies.
            // The paused Threadline now lives in its own front interactive layer
            // (`pausedThreadlineLayer`) so it can own its native scroll/hold/cruise
            // touches; only the calm `.ready` strip remains here, behind the gesture
            // surface and non-interactive.
            if showsContext && viewModel.state != .paused {
                ContextStrip(viewModel: viewModel)
                    .padding(.horizontal, 28)
                    .transition(.opacity)
            }
            // Lift the context block well clear of the home indicator: a fixed gap
            // below it, with the progress line pinned beneath — so the prose stops
            // fighting the safe area and reads as part of a settled lower cluster.
            Spacer(minLength: 0).frame(height: height * 0.13)
            ProgressLine(progress: viewModel.progress, warmth: viewModel.speedWarmth)
                .padding(.horizontal, 28)
                // Raised off the bottom safe area for clean breathing room above
                // the home indicator.
                .padding(.bottom, 26)
        }
        // Context is decorative orientation only — it must not intercept reader
        // gestures. The interactive controls (back, utility rail, scrubber) are
        // separate front siblings in the root ZStack and keep their own touches.
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.25), value: showsContext)
        .animation(.easeOut(duration: 0.25), value: viewModel.state)
    }

    /// Text reserve on the gauge side == the Gauge Control Zone, so the paused
    /// prose column ends exactly where the reserved gauge strip begins and never
    /// renders under the gauge or its halo.
    private var gaugeReserve: CGFloat { gaugeZoneWidth }
    /// Column reserve clearing the back button on the far edge, so the paused prose
    /// is a clean rectangle that never collides with it — no text wrapping needed.
    private var backReserve: CGFloat { 64 }

    /// Paused context viewport height. Modest now that it scrolls — it shows ~4
    /// lines each side for orientation and you drag for more, so it sits calmly in
    /// the lower band instead of crowding the word and the gauge.
    private func threadlineHeight(_ screenHeight: CGFloat) -> CGFloat {
        min(300, screenHeight * 0.40)
    }

    /// The paused context's vertical span on screen (matching `bottomContent`'s
    /// layout), padded a touch for forgiving touch arbitration. A press starting in
    /// this band is eligible to scroll the context instead of holding to read.
    private func contextBand(_ size: CGSize) -> ClosedRange<CGFloat> {
        let bottom = size.height - size.height * 0.13 - 30
        let top = bottom - threadlineHeight(size.height)
        return (top - 12)...(bottom + 12)
    }

    /// Is the paused context band currently interactive on screen? Visible when
    /// paused, and kept up through a band-initiated hold so its release can pause.
    private var showsPausedThreadline: Bool {
        viewModel.shouldShowContext &&
        (viewModel.state == .paused || holdStartedInThreadline)
    }

    /// The paused Threadline as a front sibling that owns its touches (native
    /// scroll + hold/cruise). Positioned absolutely over the same band/column the
    /// `.ready` strip would occupy, so nothing reflows. Faded while a hold reads.
    @ViewBuilder
    private func pausedThreadlineLayer(size: CGSize) -> some View {
        if showsPausedThreadline {
            let band = contextBand(size)
            let midY = (band.lowerBound + band.upperBound) / 2
            let leading = leftHanded ? gaugeReserve : backReserve
            let colWidth = max(0, size.width - gaugeReserve - backReserve)
            Threadline(
                viewModel: viewModel,
                height: threadlineHeight(size.height),
                leftHanded: leftHanded,
                onHoldRead: {
                    holdStartedInThreadline = true
                    viewModel.startHolding()
                },
                onRelease: {
                    viewModel.stopHolding()
                    holdStartedInThreadline = false
                },
                onCruiseToggle: { viewModel.toggleCruise() },
                onRecenter: { viewModel.recenterContext() }
            )
            .frame(width: colWidth, height: threadlineHeight(size.height))
            .position(x: leading + colWidth / 2, y: midY)
            // Fade the map while a hold streams words, so the pivot word stays hero.
            .opacity(viewModel.state == .paused ? 1 : 0.18)
            .animation(.easeOut(duration: 0.2), value: viewModel.state)
            .transition(.opacity)
        }
    }

    /// On-screen rect of the interactive paused band — used to yield the surface
    /// gesture for presses that start inside it.
    private func threadlineHitRect(_ size: CGSize) -> CGRect {
        let band = contextBand(size)
        let midY = (band.lowerBound + band.upperBound) / 2
        let h = threadlineHeight(size.height)
        let leading = leftHanded ? gaugeReserve : backReserve
        let colWidth = max(0, size.width - gaugeReserve - backReserve)
        return CGRect(x: leading, y: midY - h / 2 - 12, width: colWidth, height: h + 24)
    }

    // MARK: Scrubber (drag the progress line to seek)

    /// The interactive layer riding directly over the visible `ProgressLine`: a
    /// transparent drag strip with a thumb handle and, while scrubbing, a quiet
    /// position readout. The fill itself is still drawn by `ProgressLine` beneath
    /// (it tracks `progress`, which the scrub updates live), so this layer only
    /// adds the grip. Pinned to the foot, inset to match the line, and only live
    /// during an active session.
    private var scrubberLayer: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ProgressScrubber(viewModel: viewModel)
                .padding(.horizontal, 28)
                // Center the 40pt touch strip on the line sitting at bottom 26.
                .padding(.bottom, 7.5)
        }
        .opacity(inSession ? 1 : 0)
        .allowsHitTesting(inSession)
    }

    // MARK: Full-surface gesture layer (hold·tap·double-tap everywhere; rail steers)

    /// The one full-surface layer that makes the reader feel like a single large
    /// reading surface. It owns *every* basic action — press-and-hold to read,
    /// release to pause, double-tap to toggle Cruise, single-tap to brake — anywhere
    /// on the open canvas, with no left/right zone semantics. It sits *behind* every
    /// explicit control (utility rail, back chevron, scrubber, pickup chip), so each
    /// of those intercepts its own touch first and the surface gestures only ever
    /// fire on genuinely open space.
    ///
    /// A single `DragGesture(minimumDistance: 0)` drives the hold (and, for a press
    /// that *began* on the rail, the slide/flick steering); a simultaneous
    /// double/single `TapGesture` pair drives Cruise/brake. Live across the whole
    /// session — ready/paused (to start), `precisionHeld` (the hold continues and
    /// releases here), and cruising (taps brake/exit) — and inert on idle/completed,
    /// so the surface stays sacred outside a read.
    @ViewBuilder
    private func readingSurfaceGestureLayer(size: CGSize) -> some View {
        if inSession {
            Color.clear
                .contentShape(Rectangle())
                .gesture(surfaceDragGesture(size: size))
                .simultaneousGesture(surfaceTapGesture)
        } else {
            Color.clear
                .contentShape(Rectangle())
                .allowsHitTesting(false)
        }
    }

    /// The global tap controls. A double-tap hands off to Cruise from rest (and
    /// toggles it off while cruising); a *single* tap is the brake — while cruising
    /// it pauses immediately, the easy panic/stop gesture. The two compose
    /// *exclusively* so a genuine double-tap is never misread as two singles: the
    /// double wins, and the single only resolves once no second tap follows. From a
    /// resting state the single tap is a guarded no-op, so an accidental brush never
    /// starts or stops anything. Runs *simultaneously* with the hold drag, so a quick
    /// tap (a zero-distance drag whose hold timer never fired) still resolves here.
    private var surfaceTapGesture: some Gesture {
        ExclusiveGesture(
            TapGesture(count: 2).onEnded { dispatchSurfaceTap(.double) },
            TapGesture(count: 1).onEnded { dispatchSurfaceTap(.single) }
        )
    }

    /// Resolve a surface tap through the pure model and apply it. Keeping the
    /// decision in `ReaderGestures.tapIntent` (not inline here) is what lets the core
    /// suite verify the semantics on both hand modes without a device.
    private func dispatchSurfaceTap(_ tap: SurfaceTap) {
        let intent = ReaderGestures.tapIntent(tap, state: viewModel.state)
        dbg(tap == .double ? "reading surface double tap → cruise (\(intent))"
                           : "reading surface single tap → brake (\(intent))")
        apply(intent)
    }

    /// Apply a resolved gesture intent to the view model — the single place a
    /// gesture becomes a reader action, so `ReaderGestures` fully describes the
    /// on-device behavior. `changeSpeed` carries a target index, so the slide
    /// applies it at its call site rather than through here.
    private func apply(_ intent: ReaderIntent) {
        switch intent {
        case .none:               break
        case .toggleCruise:       viewModel.toggleCruise()
        case .pauseCruise:        viewModel.pauseCruise()
        case .beginPrecisionRead: viewModel.startHolding()
        case .rewind:             viewModel.rewind12Words()
        case .forward:            viewModel.forward12Words()
        case .changeSpeed:        break
        }
    }

    // MARK: Flick navigation indicator (transient "jumped N words" flash)

    /// A soft, centered confirmation of the last rail flick — `‹ 12 words` back,
    /// `12 words ›` ahead. It snaps in on each jump and dissolves over ~0.5s, so
    /// you get a glance of how far you moved without a control settling on the
    /// surface. Never hit-testable, and the count is the *actual* distance moved
    /// (honest at the edges); a zero-move flick emits nothing, so it stays blank.
    @ViewBuilder
    private var navFlashLayer: some View {
        if let flash = viewModel.navFlash {
            NavFlashLabel(flash: flash)
                .opacity(navFlashOpacity)
                .allowsHitTesting(false)
                // Key the fade off `seq`, not the value, so two identical jumps in
                // a row still re-flash: snap to full, then ease away. `initial: true`
                // also fires on the layer's first insertion (the session's first
                // jump), which a plain `onChange` would miss.
                .onChange(of: flash.seq, initial: true) {
                    navFlashOpacity = 1
                    withAnimation(.easeOut(duration: 0.5)) { navFlashOpacity = 0 }
                }
        }
    }

    // MARK: Thumb control rail

    @ViewBuilder
    private func controlZone(width: CGFloat) -> some View {
        if viewModel.state != .completed {
            HStack(spacing: 0) {
                if !leftHanded { Spacer(minLength: 0) }
                ZStack {
                    // No side-spanning edge wash: touching to read must light the
                    // *gauge*, not half the screen. The "you are holding" feedback is
                    // the gauge's own localized halo (`ReadingWarmth`, which brightens
                    // on hold) plus the lit dial — both tight on the instrument.

                    HStack {
                        if !leftHanded { Spacer() }
                        SpeedDial(
                            count: viewModel.bands.count,
                            index: viewModel.bandIndex,
                            isActive: dialIsActive,
                            state: gaugeState,
                            label: viewModel.band.label,
                            wpm: viewModel.wpm,
                            // Cruise: briefly surface the WPM while the thumb retunes
                            // the band, then fade back to the quiet engaged gauge.
                            revealReadout: adjustingSpeed,
                            warmth: viewModel.speedWarmth,
                            leftHanded: leftHanded
                        )
                        // Sit the half-dial's flat edge flush against the screen
                        // edge — a built-in instrument tucked into the reading-hand
                        // corner, not a gauge floating in from the side.
                        .padding(leftHanded ? .leading : .trailing, 2)
                        // While parked, the gauge steps back to a quiet readout —
                        // still legible, no longer competing with the context. It
                        // brightens to full only while actively reading (hold/cruise).
                        .opacity(viewModel.isParked ? 0.6 : 1)
                        .animation(.easeOut(duration: 0.25), value: viewModel.isParked)
                        if leftHanded { Spacer() }
                    }
                    .allowsHitTesting(false)
                }
                .frame(width: width)
                if leftHanded { Spacer(minLength: 0) }
            }
            .animation(.easeOut(duration: 0.2), value: isHolding)
            // Purely a visual rail now: the SpeedDial + tint. All touches fall
            // through to `readingSurfaceGestureLayer` beneath, which decides whether
            // a rail-started gesture steers. Never intercepts, so it can't shadow the
            // global hold/tap.
            .allowsHitTesting(false)
        }
    }

    /// The whole-surface press gesture. Press-and-hold *anywhere* reads; release
    /// pauses. If — and only if — the press *began* on the thumb rail, it also
    /// steers like a joystick: up/down throttles speed, a sideways flick rewinds 12
    /// words (←) or fast-forwards 12 (→). A press that begins on the bare canvas
    /// never steers, so its movement is ignored and a hold there just keeps reading.
    ///
    /// The read is *hold-gated*: a touch arms a timer (`minHoldToRead`) instead of
    /// reading on contact, so a quick tap or an accidental brush lifts before it
    /// fires and is a true no-op — no read blip, no haptic (the tap is then resolved
    /// by `surfaceTapGesture`). A deliberate hold crosses the threshold and reads. On
    /// the rail, steering (a slide/flick that commits an axis) cancels the pending
    /// read, so leading with movement just sets speed or jumps without starting a
    /// read. Mid-cruise a hold never grabs the wheel: words already stream, so it only
    /// steers (on the rail) and otherwise does nothing — braking is a tap.
    private func surfaceDragGesture(size: CGSize) -> some Gesture {
        let width = size.width
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !gestureActive {
                    gestureActive = true
                    gestureStartState = viewModel.state
                    gestureStartZone = ReaderGestures.zone(
                        touchX: Double(value.startLocation.x),
                        width: Double(width),
                        controlFraction: Double(gaugeZoneWidth / max(1, width)),
                        leftHanded: leftHanded)
                    speedBaseline = viewModel.bandIndex
                    axis = nil
                    flickArmed = true
                    adjustingSpeed = false
                    // A press that begins inside the paused Threadline band belongs
                    // to the band's own native scroll / hold / cruise recognizers —
                    // the surface gesture yields entirely so it never double-handles.
                    yieldToThreadline = gestureStartState == .paused
                        && threadlineHitRect(size).contains(value.startLocation)
                    dbg("reading surface hold start (\(gestureStartZone), \(gestureStartState))")
                    // Arm the hold-to-read timer from a resting state; in cruise the
                    // thumb only steers, so no read is ever scheduled.
                    if gestureStartState != .cruisePlaying {
                        scheduleHoldRead()
                    }
                }

                // The band owns its own touches; the surface gesture stays out.
                if yieldToThreadline {
                    cancelHoldRead()
                    return
                }

                // Steering is rail-only: a canvas-started press ignores movement
                // entirely, so a hold-to-read out on the open surface can't drift the
                // speed or fire a skip. Only a rail-started press runs the joystick.
                guard gestureStartZone == .rail else { return }

                let dx = value.translation.width
                let dy = value.translation.height
                let magnitude = (dx * dx + dy * dy).squareRoot()

                // Neutral zone: re-arm the next flick and re-baseline the throttle.
                if magnitude < deadzone {
                    axis = nil
                    flickArmed = true
                    adjustingSpeed = false
                    speedBaseline = viewModel.bandIndex
                    return
                }

                if axis == nil {
                    // Commit an axis only once one direction *clearly* dominates,
                    // and re-evaluate every frame until then. A still-diagonal move
                    // stays uncommitted rather than defaulting to vertical — which
                    // matters for the forward (→) flick: on a right-edge rail a
                    // rightward thumb *extends* toward the bezel and naturally arcs
                    // diagonally, so its first travel past the deadzone is rarely
                    // 1.4× horizontal. Defaulting that to vertical froze it into a
                    // speed change forever (the axis never re-evaluated), so skip
                    // could never fire while replay — a clean leftward curl — did.
                    // Now the flick resolves as soon as dx pulls clearly ahead.
                    if abs(dx) > abs(dy) * 1.4 {
                        axis = .horizontal
                    } else if abs(dy) > abs(dx) * 1.4 {
                        axis = .vertical
                    }
                    // The press became a steer, not a still-hold: drop any pending
                    // read so leading with movement never starts one.
                    if axis != nil { cancelHoldRead() }
                }

                switch axis {
                case .vertical:
                    // Map the whole band range across `slideSpan`, so every speed
                    // is reachable in one stroke. Up (negative height) = faster.
                    // The decision "a rail slide steers speed" is owned by the core
                    // model; the index it lands on is computed here.
                    if ReaderGestures.steerIntent(.slide, startZone: gestureStartZone,
                                                  startState: gestureStartState) == .changeSpeed {
                        // Turning the dial: light its live readout for as long as the
                        // vertical steer is held, even mid-cruise.
                        adjustingSpeed = true
                        let perBand = slideSpan / CGFloat(max(1, viewModel.bands.count - 1))
                        let steps = Int((-dy / perBand).rounded())
                        let before = viewModel.bandIndex
                        viewModel.setBandIndex(speedBaseline + steps)
                        if viewModel.bandIndex != before { dbg("rail speed → \(viewModel.wpm) wpm") }
                    }
                case .horizontal:
                    // Left = back 12 words, right = ahead 12 — a timeline
                    // metaphor, identical for either hand and in any mode. One
                    // jump per out-and-back; re-arms on return through the deadzone.
                    if flickArmed, abs(dx) > flickThreshold {
                        let steer: RailSteer = dx < 0 ? .flickBack : .flickForward
                        let intent = ReaderGestures.steerIntent(steer, startZone: gestureStartZone,
                                                                startState: gestureStartState)
                        dbg("rail flick \(dx < 0 ? "←" : "→") → \(intent)")
                        apply(intent)
                        flickArmed = false
                    }
                case .none:
                    break
                }
            }
            .onEnded { _ in
                // A press that lifts before the hold timer fires (and never steered)
                // is a tap → cancel the pending read so it stays a true no-op (the tap
                // is resolved by `surfaceTapGesture`). A hold that did start a read
                // releases into a pause; mid-cruise a hold only steers, so a plain tap
                // leaves autoplay running.
                let wasReading = (viewModel.state == .precisionHeld)
                cancelHoldRead()
                if gestureStartState != .cruisePlaying {
                    // No-op unless a hold actually started a read (guarded in the VM).
                    viewModel.stopHolding()
                    if wasReading { dbg("reading surface release → pause") }
                }
                gestureActive = false
                axis = nil
                flickArmed = true
                adjustingSpeed = false
                yieldToThreadline = false
            }
    }

    /// Arm the hold-to-read timer for the current press. After `minHoldToRead` of
    /// resting contact it engages the precision read; cancelled earlier by a rail
    /// steer or an early lift, so a tap never reaches it. Replaces any prior timer.
    private func scheduleHoldRead() {
        holdReadTask?.cancel()
        holdReadTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(minHoldToRead))
            guard !Task.isCancelled else { return }
            let intent = ReaderGestures.holdIntent(startState: gestureStartState)
            dbg("reading surface hold → read (\(intent))")
            apply(intent)
        }
    }

    /// Drop any pending hold-to-read timer (steer committed, or the press lifted).
    private func cancelHoldRead() {
        holdReadTask?.cancel()
        holdReadTask = nil
    }

    // MARK: Gesture-zone debug instrumentation (SKIM_GESTURE_DEBUG)

    /// Record one gesture-zone event: print it and push it onto the on-screen tail.
    /// A no-op (and zero cost beyond the flag check) in a normal run.
    private func dbg(_ event: String) {
        guard Self.gestureDebug else { return }
        print("🟣 gesture:", event)
        debugLog = (debugLog + [event]).suffix(7)
    }

    /// Dev-only visualizer: tints the *whole* reading-surface hit zone, overlays the
    /// rail's steer-only strip, marks the utility-control corner, and tails the most
    /// recent gesture events. `allowsHitTesting(false)` throughout, so it can never
    /// alter which layer owns a touch — it only reflects the real zones.
    @ViewBuilder
    private func gestureDebugOverlay(railWidth: CGFloat) -> some View {
        if Self.gestureDebug {
            ZStack {
                // 1. Full reading-surface hit zone — hold/tap/double-tap work here,
                //    edge to edge, no left/right split.
                Rectangle()
                    .fill(Color.cyan.opacity(0.08))
                    .overlay(Rectangle().strokeBorder(
                        Color.cyan, style: StrokeStyle(lineWidth: 1.5, dash: [4])))
                    .overlay(alignment: .center) {
                        Text("READING SURFACE\nhold→read · release→pause\ntap=brake (cruising) · 2-tap=cruise")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.cyan)
                            .multilineTextAlignment(.center)
                    }

                // 2. Rail steer strip, on the reading-hand edge — the ONLY zone where
                //    a press additionally steers speed/skip.
                HStack(spacing: 0) {
                    if !leftHanded { Spacer(minLength: 0) }
                    Rectangle()
                        .fill(Color.purple.opacity(0.14))
                        .overlay(Rectangle().strokeBorder(
                            Color.purple, style: StrokeStyle(lineWidth: 1.5, dash: [6])))
                        .overlay(alignment: .top) {
                            Text("RAIL (steer only)\nslide→speed · flick→±12")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.purple)
                                .multilineTextAlignment(.center)
                                .padding(.top, 120)
                        }
                        .frame(width: railWidth)
                    if leftHanded { Spacer(minLength: 0) }
                }

                // 3. Utility-control corner marker (top-left) + event tail (bottom).
                VStack(alignment: .leading, spacing: 2) {
                    Text("⌄ utility controls (own taps only)")
                        .foregroundStyle(.orange)
                        .padding(.leading, 70)
                    Spacer(minLength: 0)
                    ForEach(Array(debugLog.enumerated()), id: \.offset) { _, line in
                        Text(line).foregroundStyle(.white)
                    }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 6)
                .padding(.bottom, 90)
                .padding(.leading, 8)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    // MARK: Back-to-new-text (revealed only when not actively reading)

    /// A quiet back chevron pinned to the edge *opposite* the thumb rail and
    /// vertically centered, mirroring the control. Tapping it drops the loaded
    /// text and returns to the calm empty state, ready to pick up whatever you
    /// copy next — Skim is clipboard-first, so "back" means "read something
    /// else," not "edit this." Hidden the instant a hold begins, so the surface
    /// stays sacred.
    private var editControl: some View {
        HStack {
            if leftHanded { Spacer() }
            Button {
                dbg("control tap: back")
                viewModel.clearText()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.readingMuted)
                    .frame(width: 44, height: 44)
                    .background(Color.readingSurface.opacity(0.7), in: Circle())
                    .overlay(Circle().stroke(Color.readingBorder, lineWidth: 1))
            }
            .padding(leftHanded ? .trailing : .leading, 16)
            if !leftHanded { Spacer() }
        }
        .opacity(editVisible ? 1 : 0)
        .allowsHitTesting(editVisible)
        .animation(.easeOut(duration: 0.22), value: editVisible)
    }

    /// Visible whenever the reader is parked (ready or paused) — the safe state to
    /// leave, restart, or read something else. Gone the instant a hold or cruise
    /// begins, so active reading has one dominant action (pause), never "navigate
    /// away." The paused Threadline routes its text around this button (it is one of
    /// the Threadline's exclusion zones), so the two never collide.
    private var editVisible: Bool {
        viewModel.shouldShowPauseChrome
    }

    // MARK: New-text pickup chip

    /// A gentle, tappable prompt that something fresh was copied while a read was
    /// already loaded — so the clipboard-first flow never silently swaps the text
    /// out from under you. Tap it to load the new text; the small ✕ keeps what
    /// you're reading. It sits low and *centered*, in the quiet gap above the bottom
    /// progress line / home indicator — deliberately off the reading-hand edge so it
    /// never collides with the right-side action rail (export/ideas). Same
    /// surface/hairline family as the other overlays.
    @ViewBuilder
    private var newTextChip: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if viewModel.hasPendingClipboard && pickupVisible {
                NewTextChip(
                    onRead: { viewModel.loadPendingClipboard() },
                    onDismiss: { viewModel.dismissPendingClipboard() }
                )
                .padding(.horizontal, 24)
                // Lifted clear of the progress line + home indicator, landing in
                // the calm band beneath the context strip's lower fade.
                .padding(.bottom, 64)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82),
                   value: viewModel.hasPendingClipboard)
    }

    /// Only ever offer the pickup at rest — never mid-flow — so the sacred
    /// surface stays clear while words are actually streaming. (Foregrounding
    /// already drops a live read to `paused`, so in practice the chip lands here.)
    private var pickupVisible: Bool {
        viewModel.state == .ready || viewModel.state == .paused ||
        viewModel.state == .completed
    }
}

/// One-time gesture coaching, shown on the first reader entry: a compact
/// translucent card over a dimmed surface that names the controls once, then gets
/// out of the way for good. Small and warm — the same surface/hairline family as
/// the other overlays, not full-screen onboarding theater. The backdrop swallows
/// touches so the lesson never leaks a stray cruise toggle to the surface beneath;
/// tapping it, or "Got it", dismisses (the parent persists the flag).
private struct GestureHintsOverlay: View {
    let onDismiss: () -> Void

    private let hints: [(icon: String, text: String)] = [
        ("hand.point.up.left.fill", "Hold anywhere to read"),
        ("infinity",                "Double-tap for Cruise"),
        ("pause.fill",              "Tap to pause Cruise"),
        ("arrow.up.arrow.down",     "Slide the edge for speed"),
        ("arrow.left.and.right",    "Flick the edge to jump"),
    ]

    var body: some View {
        ZStack {
            // Dimmed, tap-swallowing backdrop: focuses the card and stops any tap
            // from reaching the reading surface (cruise toggle, rail) underneath.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                Text("Gestures")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(Color.readingMuted)
                    .padding(.bottom, 20)

                VStack(alignment: .leading, spacing: 16) {
                    ForEach(hints, id: \.text) { hint in
                        HStack(spacing: 14) {
                            Image(systemName: hint.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.readingAccent)
                                .frame(width: 26)
                            Text(hint.text)
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.readingForeground)
                        }
                    }
                }

                Button(action: onDismiss) {
                    Text("Got it")
                }
                .buttonStyle(PrimaryPillStyle())
                .padding(.top, 26)
            }
            .padding(28)
            .frame(maxWidth: 320)
            .background(Color.readingSurface,
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.readingBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 26, y: 10)
            .padding(.horizontal, 32)
        }
    }
}

/// The "new text copied" pickup chip: a clipboard glyph, a short label, and a
/// quiet dismiss. A compact floating pill for the lower thumb zone — the body is
/// one tap-to-load button; the trailing ✕ keeps the current read. Styled to match
/// the flick-flash / back-chevron family.
private struct NewTextChip: View {
    let onRead: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Button(action: onRead) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.readingAccent)
                    Text("New text — read it?")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.readingForeground)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.readingBorder)
                .frame(width: 1, height: 18)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.readingMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(Color.readingSurface.opacity(0.94), in: Capsule())
        .overlay(Capsule().stroke(Color.readingBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
    }
}

/// A calm paragraph of the surrounding prose at the foot of the screen, centered
/// on the current word so you can re-anchor at a glance without leaving the
/// reading surface. Roughly two lines of context read above and below the lit
/// word; both edges dissolve so the block melts into the reading space and never
/// competes with the pivot word riding up top.
private struct ContextStrip: View {
    let viewModel: ReaderViewModel

    /// Words of context each side — sized to fill ~2 lines above and below the
    /// current word without overflowing the five-line block. Symmetric so the
    /// lit word lands near the middle line.
    private let span = 16

    var body: some View {
        let w = ReadingContext.window(
            tokens: viewModel.tokens,
            index: viewModel.currentIndex,
            before: span,
            after: span
        )

        (
            phrase(w.before.isEmpty ? "" : w.before + " ", Color.readingMuted.opacity(0.82))
            + phrase(w.current, Color.readingForeground).bold()
            + phrase(w.after.isEmpty ? "" : " " + w.after, Color.readingMuted.opacity(0.82))
        )
        .font(.system(size: 18, weight: .regular, design: .rounded))
        .lineSpacing(6)
        .multilineTextAlignment(.center)
        .lineLimit(5)
        // A fixed-height band that vertically centers its lines: the block stays
        // put as words re-flow, and the lit current word holds near the middle
        // instead of drifting as line counts change. Clipped so nothing spills
        // past the fade.
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .clipped()
        // No per-word animation — the text re-flows instantly, no shimmer.
        .animation(nil, value: viewModel.currentIndex)
        // Dissolve both edges so the outer lines melt into the reading space and
        // attention settles on the centered current word.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.28),
                    .init(color: .black, location: 0.72),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func phrase(_ s: String, _ color: Color) -> Text {
        Text(s).foregroundColor(color)
    }
}

/// A custom horizontal alignment that marks the pivot letter's optical center, so
/// a parent frame can pin that exact point — not the word's center — to a fixed x.
private extension HorizontalAlignment {
    enum PivotCenterID: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d.width / 2 }
    }
    static let pivotCenter = HorizontalAlignment(PivotCenterID.self)
}

/// One RSVP word laid out around its Optimal Recognition Point. The pivot letter
/// (`ORP.split`) is painted in the amber accent and its *center* is locked to a
/// fixed x, so the eye holds one unmoving spot while `before`/`after` flow out to
/// the sides. For ordinary words the lock is geometric and total — a custom
/// alignment guide marks the pivot's center and a fixed-width frame pins it, so
/// word length, glyph width, punctuation, and numbers never shift the anchor.
///
/// Long words ("recommendation", URLs, long numbers) are the exception: at full
/// size they'd spill off the leading edge or past the trailing margin, and a
/// clipped word reads as broken. So before rendering we measure the word's three
/// runs and run a deterministic fit (`PivotFitSolver`): keep the pivot fixed and
/// the size full whenever it fits; otherwise shrink the font (pivot still fixed);
/// and only if it still won't fit at the readable floor, shift the whole word the
/// minimum needed to stay in-bounds. The correction is instant and jitter-free —
/// never animated — and the baseline is held constant across sizes.
///
/// The pivot sits in the left focal column for *both* hands. ORP puts the pivot in
/// a word's first third, so the longer `after` tail always trails to the right —
/// only a left anchor leaves it on-screen room. The word rides high, clear of the
/// mid-height speed dial, so it never fights the thumb whichever hand reads.
private struct PivotWord: View {
    let word: String
    /// Distance of the locked pivot center from the leading screen edge.
    let anchorX: CGFloat
    /// Full container (screen) width, so the fit can respect the trailing margin.
    let containerWidth: CGFloat
    /// Speed warmth (0…1): the focal ORP letter heats from calm gold toward a
    /// golden amber as pace climbs — soft when slow, more energized when fast.
    var warmth: Double = 0

    // Large, rounded, and solidly weighted for a crisp, high-contrast focal word
    // that never thins out or shimmers. `baseSize` is the everyday size; long words
    // shrink toward `minSize` before any shift is considered.
    private let baseSize: CGFloat = 52
    private let minSize: CGFloat = 30
    private let weight: UIFont.Weight = .semibold
    private let tracking: CGFloat = 0.5
    /// Horizontal breathing room kept between the active word and each screen edge.
    private let sideMargin: CGFloat = 16

    var body: some View {
        let parts = ORP.split(word)
        let fit = resolveFit(parts)
        let size = CGFloat(fit.fontSize)

        HStack(spacing: 0) {
            Text(parts.before).foregroundStyle(Color.readingForeground)
            Text(parts.pivot)
                .foregroundStyle(Color.readingPivot(warmth: warmth))
                // The pivot's own center is the alignment point everything pins to.
                .alignmentGuide(.pivotCenter) { $0[HorizontalAlignment.center] }
            Text(parts.after).foregroundStyle(Color.readingForeground)
        }
        .font(.system(size: size, weight: .semibold, design: .rounded))
        .tracking(tracking)
        .lineLimit(1)
        // Measured, not wrapped: the fit already guarantees it stays in bounds.
        .fixedSize()
        // A column exactly `2·anchorX` wide centers the pivot at `anchorX`; the word
        // overflows symmetrically without nudging that locked point.
        .frame(width: anchorX * 2,
               alignment: Alignment(horizontal: .pivotCenter, vertical: .center))
        .frame(maxWidth: .infinity, alignment: .leading)
        // Last-resort horizontal nudge for words too long to fit even when shrunk.
        // Zero for everything else, so the pivot stays put for normal words.
        .offset(x: CGFloat(fit.shift))
        // Hold the baseline steady across sizes: push a shrunk word down by the
        // ascent it lost, inside a fixed-height box, so smaller words don't ride up.
        .padding(.top, baselineDrop(for: size))
        .frame(height: lineHeight(baseSize), alignment: .top)
    }

    /// Measure the three runs at base size and solve for the size + shift that keeps
    /// the word inside the horizontal safe margins with the pivot anchored.
    private func resolveFit(_ parts: ORP.Pivot) -> PivotFit {
        PivotFitSolver.solve(
            beforeWidth: Double(width(parts.before, baseSize)),
            pivotWidth: Double(width(parts.pivot, baseSize)),
            afterWidth: Double(width(parts.after, baseSize)),
            anchorX: Double(anchorX),
            totalWidth: Double(containerWidth),
            leftMargin: Double(sideMargin),
            rightMargin: Double(sideMargin),
            baseFontSize: Double(baseSize),
            minFontSize: Double(minSize)
        )
    }

    /// Width of a run rendered in the active word's actual font + tracking. Empty
    /// runs measure to zero. Tracking adds one inter-glyph gap per character.
    private func width(_ s: String, _ size: CGFloat) -> CGFloat {
        guard !s.isEmpty else { return 0 }
        let attrs: [NSAttributedString.Key: Any] = [.font: uiFont(size), .kern: tracking]
        return ceil((s as NSString).size(withAttributes: attrs).width)
    }

    /// The rounded system font matching the SwiftUI `.rounded` design, for measuring.
    private func uiFont(_ size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: d, size: size)
    }

    private func lineHeight(_ size: CGFloat) -> CGFloat { uiFont(size).lineHeight }

    /// How far to drop a shrunk word so its baseline matches the full-size baseline.
    /// Ascent scales with point size, so the lost ascent is the drop. Zero at base.
    private func baselineDrop(for size: CGFloat) -> CGFloat {
        max(0, uiFont(baseSize).ascender - uiFont(size).ascender)
    }
}

/// How the gauge presents the reader's mode. The gauge is the single source of
/// truth for both speed and reading mode — there is no separate top-center symbol.
enum GaugeState {
    /// At rest (ready/paused): inspecting. Full, readable band + WPM; dim dial.
    case paused
    /// Actively reading by holding: the *same* readable band + WPM grid as paused —
    /// identical fonts, slots, and baselines — over a warmed (lit) dial. Hold is the
    /// clutch, not a named mode, so it is never labelled.
    case manual
    /// Hands-free cruise: a quiet, engaged gauge — needle + lit arc + a thin amber
    /// ring carry "locked, hands-free"; the text readout steps away (no "Cruise"
    /// word) and only re-reveals the WPM briefly while the speed is being adjusted.
    case cruise
}

/// Speed control *and* mode indicator as a *mechanical half-dial*: a 180° gauge
/// with its flat edge against the screen edge and a tapered needle that pivots from
/// the hub, rising from the low end as speed climbs — Calm sits at the bottom of the
/// arc, Blast at the top, like a speedometer sweeping up. Etched tick notches light
/// up through the swept arc; the needle snaps band to band with a spring tuned to
/// the haptic click. It reads three states (`GaugeState`): *paused* — dim dial with
/// the full band + WPM spelled out; *manual* (hold-to-read) — the same band + WPM
/// grid in the same slots, warmed by a lit dial (no reflow, no "Hold" word); and
/// *cruise* — a quiet engaged gauge (lit needle/arc + a thin amber ring) with the
/// text readout hidden, surfacing the WPM only while the speed is being adjusted.
/// Mirrors to the opposite edge for a left-hand grip.
///
/// The *gesture* is unchanged — the joystick in `ReadingView` still drives
/// `setBandIndex` from a vertical slide; this purely renders `index / count`.
private struct SpeedDial: View {
    let count: Int
    let index: Int
    let isActive: Bool
    /// Which of the three reader modes the gauge should present (see `GaugeState`).
    let state: GaugeState
    let label: String
    let wpm: Int
    /// Cruise only: while the thumb is actively retuning the band, briefly surface the
    /// WPM in the locked readout grid, then let it fade back to the quiet engaged
    /// gauge. Ignored in paused/manual, which always show the readout.
    var revealReadout: Bool = false
    /// Speed warmth (0…1): the lit arc, needle, hub, and ticks warm from calm
    /// gold toward hot amber, and the needle's glow swells — calm at Study, alive
    /// at Blast, never an alarm.
    var warmth: Double = 0
    let leftHanded: Bool

    /// The accent warmed for the current speed — the dial's one hot color.
    private var accent: Color { Color.readingAccent(warmth: warmth) }

    /// How energized the active glow is: none while parked, medium under a held
    /// thumb, full in cruise. A hold should read as temporary pressure, not as the
    /// committed autopilot of cruise, so its dial is lit but deliberately calmer.
    private var glowScale: Double {
        switch state {
        case .paused: return 0.0
        case .manual: return 0.8   // touch lights the dial clearly (no edge wash now)
        case .cruise: return 1.0
        }
    }

    /// The low end sits at straight-down (the 6-o'clock end); the needle sweeps up
    /// through the inward horizontal to straight-up as speed climbs, so slow reads at
    /// the bottom of the arc and fast at the top — a rising speedometer, not an
    /// inverted one. Right grip bulges left, left grip bulges right. Degrees are
    /// clockwise from 3 o'clock with the screen's y-down, so +90° points down (slow)
    /// and 270°/−90° points up (fast).
    private let startDeg: Double = 90
    private var sweepDeg: Double { leftHanded ? -180 : 180 }

    private var frac: Double { count > 1 ? Double(index) / Double(count - 1) : 0 }

    private let snap = Animation.spring(response: 0.24, dampingFraction: 0.62)

    var body: some View {
        GeometryReader { geo in
            let lw: CGFloat = isActive ? 4 : 3
            let pad: CGFloat = lw + 8
            let radius = min(geo.size.height / 2, geo.size.width) - pad
            // The hub rides the rail edge; the arc bulges into the screen.
            let hub = CGPoint(x: leftHanded ? pad : geo.size.width - pad,
                              y: geo.size.height / 2)

            ZStack {
                // Cruise "engaged" ring: a thin amber arc hugging the *outside* of
                // the gauge, shown only in cruise, with a soft glow — a quiet "locked,
                // hands-free" mark that belongs to the instrument, never an alarm.
                if state == .cruise {
                    GaugeArc(center: hub, radius: radius + 6,
                             startDeg: startDeg, endDeg: startDeg + sweepDeg)
                        .stroke(accent.opacity(0.85),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .shadow(color: accent.opacity(0.5), radius: 3)
                        .transition(.opacity)
                }

                // Dim background track across the full half-sweep.
                GaugeArc(center: hub, radius: radius,
                         startDeg: startDeg, endDeg: startDeg + sweepDeg)
                    .stroke(isActive ? accent.opacity(0.16)
                                     : Color.readingForeground.opacity(0.10),
                            style: StrokeStyle(lineWidth: lw, lineCap: .round))

                // Lit arc slow → current — fills as you throttle up.
                GaugeArc(center: hub, radius: radius,
                         startDeg: startDeg, endDeg: startDeg + frac * sweepDeg)
                    .stroke(isActive ? accent
                                     : Color.readingForeground.opacity(0.32),
                            style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .animation(snap, value: index)

                // Etched tick notches, one per band, lit through the swept arc.
                ForEach(0..<count, id: \.self) { i in
                    let f = count > 1 ? Double(i) / Double(count - 1) : 0
                    let major = (i == 0 || i == count - 1)
                    TickMark(hub: hub, radius: radius,
                             length: major ? 8 : 5, deg: startDeg + f * sweepDeg)
                        .stroke(tickColor(lit: f <= frac + 0.0001),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .animation(.easeOut(duration: 0.15), value: index)
                }

                // The needle, springing between detents. Its glow swells with
                // warmth so the dial looks more alive at speed without ever flaring.
                Needle(hub: hub, length: radius - 3,
                       startDeg: startDeg, sweepDeg: sweepDeg, frac: frac)
                    .fill(isActive ? accent
                                   : Color.readingForeground.opacity(0.5))
                    // Glow energy scales with the mode: muted parked, medium hold,
                    // full cruise (see `glowScale`).
                    .shadow(color: accent.opacity((0.4 + warmth * 0.35) * glowScale),
                            radius: 5 + warmth * 4 * glowScale)
                    .animation(snap, value: index)

                // Hub cap — the mechanical pivot.
                Circle()
                    .fill(isActive ? accent : Color.readingForeground.opacity(0.5))
                    .frame(width: isActive ? 11 : 8, height: isActive ? 11 : 8)
                    .overlay(Circle().fill(Color.readingBackground).frame(width: 3, height: 3))
                    .position(hub)
                    .animation(.easeOut(duration: 0.18), value: isActive)

                readout(hub: hub, radius: radius)
            }
        }
        // A compact instrument — roughly 40% smaller than before — so it reads as
        // a supporting speed gauge near the thumb, not the app's headline feature.
        .frame(width: 74, height: 138)
    }

    private func tickColor(lit: Bool) -> Color {
        guard lit else { return Color.readingForeground.opacity(0.16) }
        return isActive ? accent : Color.readingForeground.opacity(0.4)
    }

    /// The speed readout nestled inside the arc on the screen side of the hub.
    /// *Paused* and *manual* (hold-to-read) render the **identical** grid — same band
    /// + WPM + "wpm", same fonts, same slots, same baselines — so warming from rest to
    /// an active hold never shifts a digit or reflows a line; only the *dial* warms
    /// (lit arc, brighter needle, hotter amber via `isActive`/`glowScale`). Hold is a
    /// clutch, never a named mode, so it carries no state word. *Cruise* hides the
    /// readout entirely — the needle, lit arc, and engaged ring say "locked,
    /// hands-free" — and only re-reveals the WPM, in that same locked grid, while the
    /// speed is being retuned. The WPM always rides the warm accent — the number is
    /// what the eye lands on.
    @ViewBuilder
    private func readout(hub: CGPoint, radius: CGFloat) -> some View {
        let cx = hub.x + (leftHanded ? radius * 0.5 : -radius * 0.5)
        Group {
            switch state {
            case .paused, .manual:
                labelledReadout(top: label)
            case .cruise:
                if revealReadout { labelledReadout(top: label) }
            }
        }
        .position(x: cx, y: hub.y)
        .animation(.easeOut(duration: 0.2), value: state)
        .animation(.easeOut(duration: 0.25), value: revealReadout)
    }

    /// The three-line readout — the band name, the live WPM in the warm accent, and a
    /// small "wpm" suffix. The WPM uses tabular (monospaced) digits so 300, 450, 725…
    /// all occupy the same width — the number never jitters as the band changes. This
    /// one grid is shared by paused, manual, and the brief cruise reveal, which is what
    /// keeps their geometry locked together.
    private func labelledReadout(top: String) -> some View {
        VStack(spacing: 0) {
            Text(top)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.readingForeground)
            Text("\(wpm)")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent)
            Text("wpm")
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(Color.readingMuted)
        }
        .transition(.opacity)
        .fixedSize()
    }
}

/// A tapered gauge needle with a short counterweight tail, pivoting at `hub`.
/// `frac` is animatable, so the needle springs smoothly between detents.
private struct Needle: Shape {
    let hub: CGPoint
    let length: CGFloat
    let startDeg: Double
    let sweepDeg: Double
    var frac: Double

    var animatableData: Double {
        get { frac }
        set { frac = newValue }
    }

    func path(in _: CGRect) -> Path {
        let a = (startDeg + frac * sweepDeg) * .pi / 180
        let perp = a + .pi / 2
        let baseW: CGFloat = 4
        let tip = CGPoint(x: hub.x + length * cos(a), y: hub.y + length * sin(a))
        let tail = CGPoint(x: hub.x - 16 * cos(a), y: hub.y - 16 * sin(a))
        let b1 = CGPoint(x: hub.x + baseW * cos(perp), y: hub.y + baseW * sin(perp))
        let b2 = CGPoint(x: hub.x - baseW * cos(perp), y: hub.y - baseW * sin(perp))

        var p = Path()
        // Pointer: wide at the hub, tapering to the tip.
        p.move(to: b1); p.addLine(to: tip); p.addLine(to: b2); p.closeSubpath()
        // Counterweight stub behind the hub.
        p.move(to: b1); p.addLine(to: tail); p.addLine(to: b2); p.closeSubpath()
        return p
    }
}

/// A single radial tick notch running from `radius − length` out to `radius`.
private struct TickMark: Shape {
    let hub: CGPoint
    let radius: CGFloat
    let length: CGFloat
    let deg: Double

    func path(in _: CGRect) -> Path {
        let a = deg * .pi / 180
        let outer = CGPoint(x: hub.x + radius * cos(a), y: hub.y + radius * sin(a))
        let inner = CGPoint(x: hub.x + (radius - length) * cos(a),
                            y: hub.y + (radius - length) * sin(a))
        var p = Path()
        p.move(to: inner)
        p.addLine(to: outer)
        return p
    }
}

/// A circular arc sampled as a polyline, so the stroked arc, the ticks, and the
/// knob all share one angle convention (degrees clockwise from 3 o'clock) and
/// stay perfectly aligned. `endDeg` is animatable for a smooth sweep.
private struct GaugeArc: Shape {
    let center: CGPoint
    let radius: CGFloat
    let startDeg: Double
    var endDeg: Double

    var animatableData: Double {
        get { endDeg }
        set { endDeg = newValue }
    }

    func path(in _: CGRect) -> Path {
        var path = Path()
        let steps = 90
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let rad = (startDeg + (endDeg - startDeg) * t) * .pi / 180
            let pt = CGPoint(x: center.x + radius * cos(rad),
                             y: center.y + radius * sin(rad))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }
}

/// The transient flick-jump label: a chevron pointing the way you travelled and
/// the actual word count, in a calm translucent pill. The arrow leads on a
/// rewind and trails on a fast-forward, so the glance reads as motion. Styling
/// mirrors the back-chevron control (surface fill, hairline border, muted ink)
/// so it belongs to the same quiet family.
private struct NavFlashLabel: View {
    let flash: ReaderViewModel.NavFlash

    private var isBack: Bool { flash.direction == .back }
    private var countText: String { "\(flash.words) word\(flash.words == 1 ? "" : "s")" }

    var body: some View {
        HStack(spacing: 7) {
            if isBack { chevron }
            Text(countText)
            if !isBack { chevron }
        }
        .font(.system(size: 17, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.readingMuted)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Color.readingSurface.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(Color.readingBorder, lineWidth: 1))
    }

    private var chevron: some View {
        Image(systemName: isBack ? "chevron.left" : "chevron.right")
            .font(.system(size: 15, weight: .bold))
    }
}

/// Subtle bottom progress line.
private struct ProgressLine: View {
    let progress: Double
    /// Speed warmth (0…1): the fill warms toward hot amber and lifts slightly in
    /// presence as pace climbs, keeping the foot of the screen in step with the
    /// rest of the accent family.
    var warmth: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.readingForeground.opacity(0.09))
                // Brighter, slightly more present amber fill so progress reads
                // clearly without ever shouting — still tertiary to the word.
                Capsule()
                    .fill(Color.readingAccent(warmth: warmth).opacity(0.72 + warmth * 0.22))
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: 3)
    }
}

/// The drag grip layered over `ProgressLine`. A transparent full-width strip maps
/// horizontal touches to a token (`scrub(toProgress:)`), with a thumb handle that
/// brightens and grows while dragging and a centered "412 / 1,920 · 21%" readout
/// floating above the line. Reading pauses on touch-down and resumes on release
/// only if it was already On — all handled in the view model; this view is just
/// the gesture and its feedback. A tap is a zero-length drag, so it seeks too.
private struct ProgressScrubber: View {
    let viewModel: ReaderViewModel
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = max(0, min(1, viewModel.progress))
            let cx = CGFloat(p) * w

            ZStack {
                // Full strip is the hit area, even where the line is transparent.
                Color.clear.contentShape(Rectangle())

                Circle()
                    .fill(Color.readingAccent(warmth: viewModel.speedWarmth))
                    .frame(width: dragging ? 17 : 11, height: dragging ? 17 : 11)
                    .overlay(Circle().stroke(Color.readingBackground.opacity(0.55), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.3), radius: dragging ? 6 : 3, y: 1)
                    .opacity(dragging ? 1 : 0.5)
                    .position(x: cx, y: geo.size.height / 2)
                    .animation(.easeOut(duration: 0.16), value: dragging)

                if dragging {
                    ScrubReadout(index: viewModel.currentIndex,
                                 total: viewModel.wordCount,
                                 progress: p)
                        // Floats above the line; not clipped by the strip bounds.
                        .position(x: w / 2, y: -14)
                        .transition(.opacity)
                }
            }
            .frame(width: w, height: geo.size.height)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            viewModel.beginScrub()
                            dragging = true
                        }
                        viewModel.scrub(toProgress: Double(value.location.x / w))
                    }
                    .onEnded { _ in
                        viewModel.endScrub()
                        dragging = false
                    }
            )
        }
        .frame(height: 40)
    }
}

/// The transient scrub position readout — token position and percent — in the
/// same calm translucent pill as the flick flash, so it reads as the same quiet
/// family. Subtle and non-modal; only ever up while a finger is on the scrubber.
private struct ScrubReadout: View {
    let index: Int
    let total: Int
    let progress: Double

    var body: some View {
        Text("\(index + 1) / \(total.formatted())  ·  \(Int((progress * 100).rounded()))%")
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.readingForeground)
            .monospacedDigit()
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.readingSurface.opacity(0.92), in: Capsule())
            .overlay(Capsule().stroke(Color.readingBorder, lineWidth: 1))
            .fixedSize()
    }
}
