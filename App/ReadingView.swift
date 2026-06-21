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

    /// Width fraction of the thumb control rail. Generous for one-thumb reach.
    private let controlFraction: CGFloat = 0.42

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
    /// The reader's state when the current rail gesture began. Lets the rail
    /// behave differently mid-cruise (steer / tap-to-pause) than from a resting
    /// state (grab the wheel and read).
    @State private var gestureStartState: ReaderState = .ready

    /// Fade level for the flick confirmation. Snapped to 1 on each jump, then
    /// eased back to 0 — so the label flashes and dissolves without lingering.
    @State private var navFlashOpacity: Double = 0

    private enum DragAxis { case vertical, horizontal }

    private var isHolding: Bool { viewModel.state == .precisionHeld }
    private var leftHanded: Bool { viewModel.isLeftHanded }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ReadingCanvas()

                ReadingWarmth(warmth: viewModel.speedWarmth, leftHanded: leftHanded)

                topContent(height: geo.size.height, width: geo.size.width)

                bottomContent(height: geo.size.height)

                canvasTapLayer

                cruiseIndicator

                navFlashLayer

                controlZone(width: geo.size.width * controlFraction)

                editControl

                settingsButton

                ideasButton

                newTextChip

                // Front-most so its drag strip wins over the thumb rail where they
                // overlap at the foot of the screen.
                scrubberLayer

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
            // Cruise tap controls span the whole surface — including the thumb
            // rail — and run *simultaneously* with the rail's hold/steer drag, so
            // a double-tap (hand off) or single-tap (stop) works anywhere without
            // disarming the joystick.
            .simultaneousGesture(cruiseTapGesture)
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
        }
    }

    // MARK: Ideas button (persistent, secondary)

    /// A small, quiet lightbulb pinned to the bottom-right corner, lifted clear of
    /// the scrubber and away from the centered back chevron. Reachable but
    /// secondary: a one-tap scratchpad for capturing friction without leaving the
    /// read. Full at rest, faint while cruising, and gone the moment a thumb hold
    /// begins — see `ideasOpacity`.
    private var ideasButton: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button { openIdeas() } label: {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.readingMuted)
                        .frame(width: 40, height: 40)
                        .background(Color.readingSurface.opacity(0.6), in: Circle())
                        .overlay(Circle().stroke(Color.readingBorder, lineWidth: 1))
                }
                .padding(.trailing, 18)
            }
            // Lift clear of the bottom scrubber/progress line + home indicator.
            .padding(.bottom, 64)
        }
        .opacity(ideasOpacity)
        .allowsHitTesting(ideasOpacity > 0)
        .animation(.easeOut(duration: 0.22), value: ideasOpacity)
    }

    /// How present the Ideas lightbulb is. Full at rest (ready/paused) where it's a
    /// one-tap capture; faint while words actually stream under hands-free cruise —
    /// reachable, but stepped back so the focal word stays sacred — and gone during
    /// an active thumb hold or on the completion screen.
    private var ideasOpacity: Double {
        switch viewModel.state {
        case .ready, .paused:   return 1
        case .cruisePlaying:    return 0.12
        default:                return 0
        }
    }

    private func openIdeas() {
        viewModel.overlayPresented()
        showingIdeas = true
    }

    // MARK: Settings button (top-left, secondary)

    /// A quiet gear pinned to the top-left corner — the entry to set-once
    /// preferences (hand, default speed, start-in-cruise). Present at rest and
    /// while paused; like the back chevron it steps off the surface the moment a
    /// thumb hold begins or a hands-free cruise is running, so reading stays sacred.
    private var settingsButton: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SettingsGear { openSettings() }
                    .padding(.leading, 16)
                Spacer(minLength: 0)
            }
            // Below the status area; the back chevron sits lower at vertical center.
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .opacity(editVisible ? 1 : 0)
        .allowsHitTesting(editVisible)
        .animation(.easeOut(duration: 0.22), value: editVisible)
    }

    private func openSettings() {
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
    private var showsContext: Bool {
        viewModel.hasText &&
        (viewModel.state == .ready || viewModel.state == .paused)
    }

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
            if showsContext {
                ContextStrip(viewModel: viewModel)
                    // Centered across the full width so the current word sits in
                    // the middle, with context flowing above and below it.
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
        .animation(.easeOut(duration: 0.25), value: showsContext)
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

    // MARK: Canvas hit-test gate (keeps the bare surface tappable)

    /// A transparent full-surface shape that simply guarantees the bare canvas —
    /// the patches with no word/context drawn on them — reports touches, so the
    /// root tap gestures can fire there too. It carries no gesture of its own: the
    /// cruise taps live on the whole ZStack (`cruiseTapGesture`) so a double-tap
    /// (hand off) or single-tap (stop) works *anywhere*, the thumb rail included,
    /// not just the center-left. Inert while actively holding or finished, so the
    /// surface stays sacred during a read.
    @ViewBuilder
    private var canvasTapLayer: some View {
        let base = Color.clear.contentShape(Rectangle())
        switch viewModel.state {
        case .ready, .paused, .cruisePlaying:
            base
        default:
            base.allowsHitTesting(false)
        }
    }

    /// Hands-free tap controls, recognized across the *entire* surface as a
    /// simultaneous gesture so they never fight the thumb rail's hold/steer drag.
    /// A double-tap hands off to cruise from rest (and still toggles it off while
    /// cruising); a *single* tap is the obvious brake — while cruising it pauses
    /// immediately, the easy panic/stop gesture the surface was missing. The two
    /// compose *exclusively* so a genuine double-tap is never misread as two
    /// singles: the double wins, and the single only resolves once no second tap
    /// follows. From a resting state the single tap is guarded to a no-op, so an
    /// accidental brush never starts a read or kicks off cruise.
    private var cruiseTapGesture: some Gesture {
        ExclusiveGesture(
            TapGesture(count: 2).onEnded { viewModel.toggleCruise() },
            TapGesture(count: 1).onEnded {
                if viewModel.state == .cruisePlaying { viewModel.pauseCruise() }
            }
        )
    }

    // MARK: Cruise indicator (hands-free "still flowing" glyph)

    /// A whisper-quiet autopilot mark that fades in only while cruising, so the
    /// hands-free state reads at a glance without putting a control on the sacred
    /// surface. Pinned top-center, clear of the corner-anchored word, and never
    /// hit-testable — it's a status light, not a button.
    private var cruiseIndicator: some View {
        VStack(spacing: 0) {
            CruiseGlyph()
                .padding(.top, 18)
            Spacer(minLength: 0)
        }
        .opacity(viewModel.state == .cruisePlaying ? 1 : 0)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.3), value: viewModel.state)
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
                    // Faint always-on tint so the edge reads as a control, glowing
                    // brighter while held. Fades toward the active edge.
                    LinearGradient(
                        colors: [.clear,
                                 Color.readingAccent(warmth: viewModel.speedWarmth)
                                    .opacity(isHolding ? 0.12 : 0.05)],
                        startPoint: leftHanded ? .trailing : .leading,
                        endPoint: leftHanded ? .leading : .trailing
                    )
                    .contentShape(Rectangle())
                    .gesture(holdGesture)

                    HStack {
                        if !leftHanded { Spacer() }
                        SpeedDial(
                            count: viewModel.bands.count,
                            index: viewModel.bandIndex,
                            isActive: isHolding,
                            label: viewModel.band.label,
                            wpm: viewModel.wpm,
                            warmth: viewModel.speedWarmth,
                            showHint: viewModel.state == .ready,
                            leftHanded: leftHanded
                        )
                        // Sit the half-dial's flat edge flush against the screen
                        // edge — a built-in instrument tucked into the reading-hand
                        // corner, not a gauge floating in from the side.
                        .padding(leftHanded ? .leading : .trailing, 2)
                        if leftHanded { Spacer() }
                    }
                    .allowsHitTesting(false)
                }
                .frame(width: width)
                if leftHanded { Spacer(minLength: 0) }
            }
            .animation(.easeOut(duration: 0.2), value: isHolding)
        }
    }

    /// Hold to read; the thumb then steers like a joystick. Up/down throttles
    /// speed; a sideways flick rewinds 12 words (←) or fast-forwards 12 (→). The
    /// first move past the deadzone locks an axis so speed and navigation never
    /// cross-fire; returning near the origin re-arms, so you can throttle,
    /// settle, then flick.
    ///
    /// Mid-cruise the rail never grabs the wheel: it only steers (speed/flick).
    /// Pausing is the canvas double-tap, so a plain rail tap is a no-op and the
    /// autoplay keeps flowing. From a resting state, a touch engages precision
    /// reading immediately.
    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !gestureActive {
                    gestureActive = true
                    gestureStartState = viewModel.state
                    speedBaseline = viewModel.bandIndex
                    axis = nil
                    flickArmed = true
                    // In cruise the thumb steers; it doesn't start a held read.
                    if gestureStartState != .cruisePlaying {
                        viewModel.startHolding()
                    }
                }

                let dx = value.translation.width
                let dy = value.translation.height
                let magnitude = (dx * dx + dy * dy).squareRoot()

                // Neutral zone: re-arm the next flick and re-baseline the throttle.
                if magnitude < deadzone {
                    axis = nil
                    flickArmed = true
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
                }

                switch axis {
                case .vertical:
                    // Map the whole band range across `slideSpan`, so every speed
                    // is reachable in one stroke. Up (negative height) = faster.
                    let perBand = slideSpan / CGFloat(max(1, viewModel.bands.count - 1))
                    let steps = Int((-dy / perBand).rounded())
                    viewModel.setBandIndex(speedBaseline + steps)
                case .horizontal:
                    // Left = back 12 words, right = ahead 12 — a timeline
                    // metaphor, identical for either hand and in any mode. One
                    // jump per out-and-back; re-arms on return through the deadzone.
                    if flickArmed, abs(dx) > flickThreshold {
                        if dx < 0 { viewModel.rewind12Words() }
                        else { viewModel.forward12Words() }
                        flickArmed = false
                    }
                case .none:
                    break
                }
            }
            .onEnded { _ in
                // From a resting state the rail drove a held read; releasing
                // pauses it. Mid-cruise the rail only steers — pausing is the
                // canvas double-tap — so a plain tap here leaves autoplay running.
                if gestureStartState != .cruisePlaying {
                    viewModel.stopHolding()
                }
                gestureActive = false
                axis = nil
                flickArmed = true
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

    /// Shown whenever you're not mid-read or finished — i.e. waiting or paused.
    private var editVisible: Bool {
        viewModel.state == .ready || viewModel.state == .paused
    }

    // MARK: New-text pickup chip

    /// A gentle, tappable prompt that something fresh was copied while a read was
    /// already loaded — so the clipboard-first flow never silently swaps the text
    /// out from under you. Tap it to load the new text; the small ✕ keeps what
    /// you're reading. This is an interrupt/queue action, so it floats in the
    /// lower thumb zone on the reading-hand side (mirrored for left-handers) where
    /// the thumb already rests — not as a top banner. Sits in the quiet gap above
    /// the bottom progress line / home indicator, below the vertically-centered
    /// speed dial and the faded context strip, so it never covers the focal word
    /// or the live prose. Same surface/hairline family as the other overlays.
    @ViewBuilder
    private var newTextChip: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if viewModel.hasPendingClipboard && pickupVisible {
                HStack(spacing: 0) {
                    if !leftHanded { Spacer(minLength: 0) }
                    NewTextChip(
                        onRead: { viewModel.loadPendingClipboard() },
                        onDismiss: { viewModel.dismissPendingClipboard() }
                    )
                    .padding(leftHanded ? .leading : .trailing, 16)
                    if leftHanded { Spacer(minLength: 0) }
                }
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
        ("hand.point.up.left.fill", "Hold to read"),
        ("arrow.up.arrow.down",     "Slide to change speed"),
        ("arrow.left.and.right",    "Flick left/right to jump"),
        ("infinity",                "Double-tap for Cruise"),
        ("pause.fill",              "Tap to pause"),
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

/// Speed control as a *mechanical half-dial*: a 180° gauge with its flat edge
/// against the screen edge and a tapered needle that pivots from the hub,
/// sweeping DOWN for slow and UP for fast — a direct mirror of the up/down thumb
/// slide. Etched tick notches light up through the swept arc; the needle snaps
/// band to band with a spring tuned to the haptic click, for a tactile,
/// instrument feel. Dim at rest, amber while held; mirrors to the opposite edge
/// for a left-hand grip.
///
/// The *gesture* is unchanged — the joystick in `ReadingView` still drives
/// `setBandIndex` from a vertical slide; this purely renders `index / count`.
private struct SpeedDial: View {
    let count: Int
    let index: Int
    let isActive: Bool
    let label: String
    let wpm: Int
    /// Speed warmth (0…1): the lit arc, needle, hub, and ticks warm from calm
    /// gold toward hot amber, and the needle's glow swells — calm at Study, alive
    /// at Blast, never an alarm.
    var warmth: Double = 0
    let showHint: Bool
    let leftHanded: Bool

    /// The accent warmed for the current speed — the dial's one hot color.
    private var accent: Color { Color.readingAccent(warmth: warmth) }

    /// Slow sits at straight-down (90°); the needle sweeps through the inward
    /// horizontal to straight-up (fast). Right grip bulges left (+180°), left
    /// grip bulges right (−180°). Degrees are clockwise from 3 o'clock with the
    /// screen's y-down, so +90° points down and 270°/−90° points up.
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
                    .shadow(color: isActive ? accent.opacity(0.4 + warmth * 0.35) : .clear,
                            radius: isActive ? 5 + warmth * 4 : 5)
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

    /// Band label + wpm (held) or the first-use hint (idle), nestled inside the
    /// arc on the screen side of the hub.
    @ViewBuilder
    private func readout(hub: CGPoint, radius: CGFloat) -> some View {
        let cx = hub.x + (leftHanded ? radius * 0.5 : -radius * 0.5)
        Group {
            if isActive {
                VStack(spacing: 0) {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.readingForeground)
                    Text("\(wpm)")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                    Text("wpm")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.readingMuted)
                }
                .transition(.opacity)
                .fixedSize()
            } else if showHint {
                VStack(spacing: 4) {
                    Image(systemName: "chevron.up")
                    Image(systemName: leftHanded ? "hand.point.up.right.fill"
                                                 : "hand.point.up.left.fill")
                        .font(.system(size: 16))
                    Image(systemName: "chevron.down")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.readingMuted)
            }
        }
        .position(x: cx, y: hub.y)
        .animation(.easeOut(duration: 0.18), value: isActive)
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

/// The cruise "status light": an infinity mark — effortless, continuous flow —
/// that breathes slowly in the reading accent so the surface feels alive but
/// never busy. It only ever shows while autoplay is running; the parent fades it
/// in and out with the cruise state.
private struct CruiseGlyph: View {
    @State private var breathing = false

    var body: some View {
        Image(systemName: "infinity")
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(Color.readingAccent.opacity(breathing ? 0.5 : 0.22))
            .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                       value: breathing)
            .onAppear { breathing = true }
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
