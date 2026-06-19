import SwiftUI

/// The sacred reading surface. Almost nothing on screen: the current word riding
/// high on its pivot, a tiny progress line, and a thumb rail you hold to read and
/// steer like a joystick — slide up/down for speed, flick ←/→ to replay/skip.
struct ReadingView: View {
    let viewModel: ReaderViewModel

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

    /// Leading inset of the pivot from the screen edge. Small, so the focal point
    /// sits in the top corner with room for the single-letter lead-in beside it.
    private let pivotAnchorX: CGFloat = 40

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

                topContent(height: geo.size.height)

                bottomContent

                canvasTapLayer

                cruiseIndicator

                navFlashLayer

                controlZone(width: geo.size.width * controlFraction)

                editControl
            }
            // One source of truth for the warmth crossfade: when the band changes,
            // every speed-driven color (glow, rail, dial, pivot, progress) eases
            // together over a beat. Keyed on `speedWarmth` so a stray word advance
            // never animates color — only an actual speed change does. Dropped
            // under Reduce Motion: the colors snap instead.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25),
                       value: viewModel.speedWarmth)
        }
    }

    // MARK: Word (rides high, anchored on the reading-hand side)

    @ViewBuilder
    private func topContent(height: CGFloat) -> some View {
        if viewModel.state == .completed {
            // The end-of-text state stays centered; only the streaming word
            // rides high on the screen.
            CompletionView(viewModel: viewModel)
        } else {
            VStack(spacing: 0) {
                PivotWord(word: viewModel.currentToken?.text ?? "",
                          anchorX: pivotAnchorX,
                          leftHanded: leftHanded,
                          warmth: viewModel.speedWarmth)
                    // Hold the baseline steady; no per-word animation/jitter.
                    .animation(nil, value: viewModel.currentIndex)
                    .padding(leftHanded ? .trailing : .leading, 20)
                    .padding(.top, height * 0.07)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Context strip + progress (foot of the screen)

    /// The line-by-line context belongs to an active session — hide it on the
    /// completion screen and when there's nothing loaded.
    private var showsContext: Bool {
        viewModel.hasText &&
        (viewModel.state == .ready || viewModel.state == .precisionHeld ||
         viewModel.state == .paused || viewModel.state == .cruisePlaying)
    }

    private var bottomContent: some View {
        VStack(spacing: 0) {
            Spacer()
            if showsContext {
                ContextStrip(viewModel: viewModel)
                    // Centered across the full width so the current word sits in
                    // the middle, with context flowing above and below it.
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
            ProgressLine(progress: viewModel.progress, warmth: viewModel.speedWarmth)
                .padding(.horizontal, 28)
                .padding(.bottom, 14)
        }
        .animation(.easeOut(duration: 0.25), value: showsContext)
    }

    // MARK: Canvas mode switch (full-surface taps, clear of the thumb rail)

    /// A transparent full-surface tap catcher, sitting above the passive word/
    /// context layers but below the rail and back chevron (which win their own
    /// regions). Double-tap is the single hands-free toggle: when resting it hands
    /// off to cruise; while cruising it takes the wheel back. The same gesture both
    /// ways keeps the mental model trivial — and a *double* tap (never a stray
    /// single) means an accidental brush never stops the flow. Inert while actively
    /// holding or finished, so the surface stays sacred during a read.
    @ViewBuilder
    private var canvasTapLayer: some View {
        let base = Color.clear.contentShape(Rectangle())
        switch viewModel.state {
        case .ready, .paused:
            base.onTapGesture(count: 2) { viewModel.enterCruise() }
        case .cruisePlaying:
            base.onTapGesture(count: 2) { viewModel.pauseCruise() }
        default:
            base.allowsHitTesting(false)
        }
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
                        .padding(leftHanded ? .leading : .trailing, 12)
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
                    // Bias toward the vertical (speed) axis: only a clearly
                    // sideways move commits to a flick, so a near-vertical or
                    // diagonal lift-off never misfires replay/skip.
                    axis = abs(dx) > abs(dy) * 1.4 ? .horizontal : .vertical
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
            phrase(w.before.isEmpty ? "" : w.before + " ", Color.readingMuted.opacity(0.6))
            + phrase(w.current, Color.readingForeground).bold()
            + phrase(w.after.isEmpty ? "" : " " + w.after, Color.readingMuted.opacity(0.6))
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

/// One RSVP word, anchored on its pivot. The pivot — the second letter — is
/// painted blue and pinned to a fixed x, so your eye holds one spot while the
/// rest of the word flows around it. This is the "optimal recognition point"
/// that makes rapid serial reading feel still. Mirrors to the opposite corner
/// for a left-handed grip while letters still read left to right.
private struct PivotWord: View {
    let word: String
    let anchorX: CGFloat
    let leftHanded: Bool
    /// Speed warmth (0…1): the focal ORP letter heats from calm gold toward a
    /// golden amber as pace climbs — soft when slow, more energized when fast.
    var warmth: Double = 0

    private let font = Font.system(size: 50, weight: .semibold, design: .rounded)

    var body: some View {
        let chars = Array(word)
        // Pivot on the second letter (index 1); single-character words pivot on
        // their only letter.
        let pivotIdx = chars.count > 1 ? 1 : 0
        let before = chars.isEmpty ? "" : String(chars[0..<pivotIdx])
        let pivot  = chars.isEmpty ? "" : String(chars[pivotIdx])
        let after  = chars.count > pivotIdx + 1 ? String(chars[(pivotIdx + 1)...]) : ""

        HStack(spacing: 0) {
            if leftHanded {
                Spacer(minLength: 0)
                Text(before).foregroundStyle(Color.readingForeground)
                Text(pivot).foregroundStyle(Color.readingPivot(warmth: warmth))
                // Trailing box pins the pivot's right edge to a fixed x from the
                // right; the rest of the word reads on to the left of it.
                Text(after)
                    .foregroundStyle(Color.readingForeground)
                    .frame(width: anchorX, alignment: .leading)
            } else {
                // The lead-in fills a fixed box ending at the anchor, so the
                // pivot's left edge always lands on the same x no matter the word.
                Text(before)
                    .foregroundStyle(Color.readingForeground)
                    .frame(width: anchorX, alignment: .trailing)
                Text(pivot).foregroundStyle(Color.readingPivot(warmth: warmth))
                Text(after).foregroundStyle(Color.readingForeground)
                Spacer(minLength: 0)
            }
        }
        .font(font)
        .tracking(0.5)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
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
            let lw: CGFloat = isActive ? 6 : 4
            let pad: CGFloat = lw + 9
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
                             length: major ? 11 : 7, deg: startDeg + f * sweepDeg)
                        .stroke(tickColor(lit: f <= frac + 0.0001),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .animation(.easeOut(duration: 0.15), value: index)
                }

                // The needle, springing between detents. Its glow swells with
                // warmth so the dial looks more alive at speed without ever flaring.
                Needle(hub: hub, length: radius - 4,
                       startDeg: startDeg, sweepDeg: sweepDeg, frac: frac)
                    .fill(isActive ? accent
                                   : Color.readingForeground.opacity(0.5))
                    .shadow(color: isActive ? accent.opacity(0.4 + warmth * 0.35) : .clear,
                            radius: isActive ? 8 + warmth * 6 : 8)
                    .animation(snap, value: index)

                // Hub cap — the mechanical pivot.
                Circle()
                    .fill(isActive ? accent : Color.readingForeground.opacity(0.5))
                    .frame(width: isActive ? 15 : 11, height: isActive ? 15 : 11)
                    .overlay(Circle().fill(Color.readingBackground).frame(width: 4, height: 4))
                    .position(hub)
                    .animation(.easeOut(duration: 0.18), value: isActive)

                readout(hub: hub, radius: radius)
            }
        }
        .frame(width: 116, height: 216)
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
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.readingForeground)
                    Text("\(wpm)")
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                    Text("wpm")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.readingMuted)
                }
                .transition(.opacity)
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
                Capsule().fill(Color.readingForeground.opacity(0.08))
                Capsule()
                    .fill(Color.readingAccent(warmth: warmth).opacity(0.5 + warmth * 0.3))
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: 2)
    }
}

/// Shown at the end of the text.
private struct CompletionView: View {
    let viewModel: ReaderViewModel

    var body: some View {
        VStack(spacing: 26) {
            Text("Done")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.readingForeground)
            VStack(spacing: 12) {
                Button {
                    viewModel.restart()
                } label: {
                    Label("Read again", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(SecondaryPillStyle())

                Button {
                    viewModel.clearText()
                } label: {
                    Label("New text", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(SecondaryPillStyle())
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}
