# Edge Speed Slider + Relocated Return-to-Word Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In paused Threadline mode, replace the 118pt circular speed gauge with a slim, directly-draggable edge speed slider and move the return-to-word button out of the Threadline scroll box into that same edge lane, giving Threadline ~110pt more width.

**Architecture:** A new `EdgeSpeedRail` view (readout + draggable vertical `SpeedTrack` + recenter button) renders as a front sibling in the reading-hand edge lane, shown only while `state == .paused`. The existing `SpeedDial` is hidden in that state; everywhere else (ready/hold/cruise) it is untouched. `gaugeReserve` becomes state-aware so the paused Threadline column reclaims the freed width, and `Threadline` loses its internal locator + right inset, reporting off-center up to `ReadingView`.

**Tech Stack:** Swift 6, SwiftUI (`DragGesture`, `GeometryReader`), `@Observable` view model, UIKit-backed `Threadline` (`UITextView`). iOS 17+, portrait-only.

## Global Constraints

- App-layer UI only. Core (`Sources/SkimCore`) is untouched; no `CoreChecks` assertion is needed. `swift build` only proves the core still compiles; app code compiles only under Xcode.
- Verify each app-layer task with: `xcodebuild -project Skim.xcodeproj -scheme Skim -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`. Final acceptance is on-device via `scripts/deploy-device.sh` (build-gated; only lands on a green build).
- No new files added → `xcodegen generate` is not required. Edit `project.yml`, never the pbxproj (not needed here).
- The swap is gated strictly on `viewModel.state == .paused`. `.ready`, hold-to-read, and Cruise keep the existing `SpeedDial` — do not regress them.
- Exact values: `edgeSliderZoneWidth = 52`; existing `gaugeZoneWidth = 118`, `backReserve = 64`. Slider top = faster (higher band index). Speed only — no skip.
- Speed changes go through `viewModel.setBandIndex(_:)` (already clamps `0…bands.count-1` and fires the `.bandChange` haptic only on an actual step). Recenter goes through `viewModel.recenterContext()`.
- Amber accent (`Color.readingAccent`) used sparingly: the thumb and the WPM number. Dark circular control language for the recenter button (`location.fill`, `Color.readingSurface` bg, `Color.readingBorder` hairline).

---

### Task 1: `EdgeSpeedRail` + `SpeedTrack` views

**Files:**
- Modify: `App/ReadingView.swift` (append two private structs near the other private view structs at end of file, e.g. after `SpeedDial`/`GaugeArc`)

**Interfaces:**
- Consumes: `Color.readingAccent/Border/Surface/Muted` (existing theme), `viewModel.setBandIndex(_:)` / `recenterContext()` (called by the parent, passed in as closures).
- Produces:
  - `EdgeSpeedRail(count: Int, index: Int, wpm: Int, label: String, leftHanded: Bool, offCenter: Bool, onSetIndex: (Int) -> Void, onRecenter: () -> Void)` — the full edge mini-rail.
  - `SpeedTrack(count: Int, index: Int, dragging: Binding<Bool>, onSetIndex: (Int) -> Void)` — the draggable track. Consumed by `EdgeSpeedRail` only; both consumed by Task 2.

- [ ] **Step 1: Add the `SpeedTrack` view**

In `App/ReadingView.swift`, append:

```swift
/// The slim, directly-draggable vertical speed track for the paused edge rail. A
/// drag maps the thumb's vertical position to a band index (top = fastest), driving
/// `onSetIndex`; clamping + the detent haptic live in the view model. The 44pt-wide
/// hit lane keeps the touch target comfortable though the visible track is ~4pt.
private struct SpeedTrack: View {
    let count: Int
    let index: Int
    @Binding var dragging: Bool
    let onSetIndex: (Int) -> Void

    /// Thumb travel: 0 at the slowest (bottom), 1 at the fastest (top).
    private var fraction: CGFloat {
        guard count > 1 else { return 0 }
        return CGFloat(index) / CGFloat(count - 1)
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let accent = Color.readingAccent
            ZStack {
                Capsule().fill(Color.readingBorder).frame(width: 4)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Capsule().fill(accent.opacity(0.5))
                        .frame(width: 4, height: max(0, h * fraction))
                }
                Circle()
                    .fill(accent)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(Color.readingSurface, lineWidth: 1.5))
                    .shadow(color: accent.opacity(dragging ? 0.55 : 0), radius: 7)
                    .position(x: geo.size.width / 2, y: (1 - fraction) * h)
                    .animation(.easeOut(duration: 0.14), value: fraction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        let y = min(max(0, v.location.y), h)
                        let f = 1 - (y / max(1, h))   // top = fastest
                        onSetIndex(Int((f * CGFloat(count - 1)).rounded()))
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(width: 44)
    }
}
```

- [ ] **Step 2: Add the `EdgeSpeedRail` view**

Append below `SpeedTrack`:

```swift
/// The paused-mode edge instrument: a compact speed readout on top, the draggable
/// `SpeedTrack` filling the middle, and the return-to-word button docked at the
/// bottom (shown only when the active word has scrolled away). Replaces the half-
/// dial while paused so the Threadline gets the width. Lives in a 52pt lane on the
/// reading-hand edge; mirrored L/R by the caller's positioning.
private struct EdgeSpeedRail: View {
    let count: Int
    let index: Int
    let wpm: Int
    let label: String
    let leftHanded: Bool
    let offCenter: Bool
    let onSetIndex: (Int) -> Void
    let onRecenter: () -> Void

    @State private var dragging = false

    var body: some View {
        VStack(spacing: 0) {
            readout
                .padding(.bottom, 10)
            SpeedTrack(count: count, index: index, dragging: $dragging, onSetIndex: onSetIndex)
                .frame(maxHeight: .infinity)
            // Reserve the button slot so the track height never jumps as it toggles.
            ZStack {
                if offCenter {
                    Button(action: onRecenter) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.readingAccent)
                            .frame(width: 34, height: 34)
                            .background(Color.readingSurface.opacity(0.85), in: Circle())
                            .overlay(Circle().stroke(Color.readingBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to current word")
                    .transition(.opacity)
                }
            }
            .frame(height: 40)
            .padding(.top, 12)
        }
        .frame(width: 52)
        .animation(.easeOut(duration: 0.2), value: offCenter)
    }

    /// WPM number (amber) + tiny "wpm" + band label (muted, the optional element —
    /// scales down on narrow screens). Quiet at rest, full while dragging.
    private var readout: some View {
        VStack(spacing: 1) {
            Text("\(wpm)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.readingAccent)
            Text("WPM")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.readingMuted)
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.readingMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .opacity(dragging ? 1 : 0.7)
        .animation(.easeOut(duration: 0.15), value: dragging)
    }
}
```

- [ ] **Step 3: Build to verify the new views compile**

Run: `xcodebuild -project Skim.xcodeproj -scheme Skim -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **` (the structs are unused for now; that is fine).

- [ ] **Step 4: Commit**

```bash
git add App/ReadingView.swift
git commit -m "feat: EdgeSpeedRail + SpeedTrack views for paused edge speed slider"
```

---

### Task 2: Wire the rail in, gate the dial, widen Threadline, relocate the locator

**Files:**
- Modify: `App/Threadline.swift` (remove the locator overlay, the `threadlineLocatorRail` inset, and internal `offCenter` ownership; expose `onOffCenterChange`; drop `onRecenter`)
- Modify: `App/ReadingView.swift` (add `edgeSliderZoneWidth`, state-aware `gaugeReserve`, `@State offCenter`, the `edgeSpeedRailLayer`, gate the dial out while paused, update the `Threadline(...)` call)

**Interfaces:**
- Consumes: `EdgeSpeedRail(...)`, `SpeedTrack(...)` (Task 1); `viewModel.state`, `viewModel.bands`, `viewModel.bandIndex`, `viewModel.wpm`, `viewModel.band.label`, `viewModel.setBandIndex(_:)`, `viewModel.recenterContext()`, `viewModel.shouldShowContext`, `contextBand(_:)`, `threadlineHeight(_:)`, `leftHanded` (all existing).
- Produces: `Threadline` with new signature `Threadline(viewModel:height:onHoldRead:onRelease:onCruiseToggle:onOffCenterChange:)` (no `onRecenter`).

- [ ] **Step 1: Drop the locator rail constant and right inset in Threadline**

In `App/Threadline.swift`, delete the constant (lines ~4-7):

```swift
/// Width of the reserved right-edge rail that carries the recenter locator. The
/// prose is inset by this much on the right so the floating button always sits in
/// clear space beside the text column — never over readable words.
private let threadlineLocatorRail: CGFloat = 44
```

Then change the text container inset (in `makeUIView`) from:

```swift
        // Reserve a clear strip on the right for the recenter locator so the prose
        // column ends before the rail and the button never overlaps readable text.
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: threadlineLocatorRail)
```

to (the locator no longer lives here; keep a slim gutter for the scroll indicator):

```swift
        // Prose uses the full Threadline width now; keep a slim right gutter so the
        // scroll indicator never sits on the last glyphs.
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 6)
```

- [ ] **Step 2: Change Threadline's signature — drop `onRecenter`, expose `onOffCenterChange`, remove the overlay**

In `App/Threadline.swift`, replace the whole `struct Threadline: View { ... }` (lines ~25-99) with:

```swift
struct Threadline: View {
    let viewModel: ReaderViewModel
    /// Fixed viewport height — sized by the caller so the block never collides with
    /// the pivot word up top or the progress cluster below.
    let height: CGFloat
    /// A still press-and-hold crossed the read gate: start reading.
    let onHoldRead: () -> Void
    /// The read-initiating hold lifted: pause.
    let onRelease: () -> Void
    /// A clean double tap: toggle Cruise.
    let onCruiseToggle: () -> Void
    /// Reports whether the active word has scrolled out of the comfort band, so the
    /// parent can show/hide the return-to-word control in the edge lane. The button
    /// itself now lives outside this view, beside the prose — never over the text.
    let onOffCenterChange: (Bool) -> Void

    var body: some View {
        ThreadlineTextView(
            tokens: viewModel.tokens,
            activeIndex: viewModel.currentIndex,
            recenterKey: viewModel.contextRecenterTick,
            onHoldRead: onHoldRead,
            onRelease: onRelease,
            onCruiseToggle: onCruiseToggle,
            onOffCenterChange: onOffCenterChange
        )
        .frame(maxWidth: .infinity)
        .frame(height: height)
        // Soft top/bottom dissolve so the outer lines melt into the reading space
        // and the eye settles on the centered active word.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.14),
                    .init(color: .black, location: 0.86),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}
```

- [ ] **Step 3: Build Threadline in isolation expecting a call-site error**

Run: `xcodebuild -project Skim.xcodeproj -scheme Skim -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `ReadingView.swift` still calls `Threadline(... onRecenter:)`, which no longer exists. This confirms the only remaining consumer is the call site fixed next. (If it unexpectedly succeeds, search for other `onRecenter:` / `threadlineLocatorRail` references and remove them.)

- [ ] **Step 4: Add `edgeSliderZoneWidth` and make `gaugeReserve` state-aware**

In `App/ReadingView.swift`, just below the `gaugeZoneWidth` declaration (~line 43), add:

```swift
    /// Width (points) of the slim **edge speed slider** lane that replaces the dial
    /// while paused — the Threadline reclaims the difference (118 → 52).
    private let edgeSliderZoneWidth: CGFloat = 52
```

Then replace `gaugeReserve` (~line 436):

```swift
    private var gaugeReserve: CGFloat { gaugeZoneWidth }
```

with:

```swift
    /// Text reserve on the reading-hand side. While paused the slim edge slider lane
    /// stands in for the dial, so the paused Threadline column reclaims the width;
    /// every other state keeps the full gauge zone. Consumed only by the paused
    /// Threadline layout + hit-rect, so this is localized to paused mode.
    private var gaugeReserve: CGFloat {
        viewModel.state == .paused ? edgeSliderZoneWidth : gaugeZoneWidth
    }
```

- [ ] **Step 5: Add the `offCenter` state**

In `App/ReadingView.swift`, beside the other `@State` (after `didCopy`, ~line 19):

```swift
    /// True once the active word has scrolled out of the Threadline comfort band —
    /// fed up from `Threadline`, drives the edge-lane return-to-word button.
    @State private var offCenter = false
```

- [ ] **Step 6: Update the `Threadline(...)` call to feed `offCenter`**

In `pausedThreadlineLayer` (~lines 474-487), replace the `Threadline(...)` initializer call:

```swift
            Threadline(
                viewModel: viewModel,
                height: threadlineHeight(size.height),
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
```

with (swap the last argument):

```swift
            Threadline(
                viewModel: viewModel,
                height: threadlineHeight(size.height),
                onHoldRead: {
                    holdStartedInThreadline = true
                    viewModel.startHolding()
                },
                onRelease: {
                    viewModel.stopHolding()
                    holdStartedInThreadline = false
                },
                onCruiseToggle: { viewModel.toggleCruise() },
                onOffCenterChange: { offCenter = $0 }
            )
```

- [ ] **Step 7: Gate the dial out while paused**

In `controlZone(width:)` (~line 627), replace:

```swift
        if viewModel.state != .completed {
```

with (the slim slider stands in for the dial while paused):

```swift
        if viewModel.state != .completed && viewModel.state != .paused {
```

- [ ] **Step 8: Add the `edgeSpeedRailLayer` and place it in the body**

In `App/ReadingView.swift`, add this function next to `pausedThreadlineLayer`:

```swift
    /// The paused edge instrument: the slim speed slider + the return-to-word button,
    /// docked in the slim lane on the reading-hand edge, vertically aligned to the
    /// Threadline band. A front sibling so its drag wins its own touches; absent in
    /// every non-paused state (the dial returns there). Mirrors L/R like the column.
    @ViewBuilder
    private func edgeSpeedRailLayer(size: CGSize) -> some View {
        if viewModel.state == .paused && viewModel.shouldShowContext {
            let band = contextBand(size)
            let midY = (band.lowerBound + band.upperBound) / 2
            let x = leftHanded ? edgeSliderZoneWidth / 2 : size.width - edgeSliderZoneWidth / 2
            EdgeSpeedRail(
                count: viewModel.bands.count,
                index: viewModel.bandIndex,
                wpm: viewModel.wpm,
                label: viewModel.band.label,
                leftHanded: leftHanded,
                offCenter: offCenter,
                onSetIndex: { viewModel.setBandIndex($0) },
                onRecenter: { viewModel.recenterContext() }
            )
            .frame(width: edgeSliderZoneWidth, height: threadlineHeight(size.height))
            .position(x: x, y: midY)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.2), value: viewModel.state)
        }
    }
```

Then in `body`, add it to the root `ZStack` immediately after `controlZone(width: gaugeZoneWidth)` (~line 204):

```swift
                controlZone(width: gaugeZoneWidth)

                edgeSpeedRailLayer(size: geo.size)
```

- [ ] **Step 9: Build the app target**

Run: `xcodebuild -project Skim.xcodeproj -scheme Skim -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 10: Commit**

```bash
git add App/ReadingView.swift App/Threadline.swift
git commit -m "feat: edge speed slider replaces dial when paused; relocate return-to-word to edge lane"
```

---

### Task 3: On-device verification, acceptance, and geometry tuning

**Files:** none (verification + small tuning only)

- [ ] **Step 1: Deploy on a green build**

Run: `scripts/deploy-device.sh`
Expected: clean build, then install + launch on the iPhone.

- [ ] **Step 2: Walk the acceptance criteria**

- Pause mid-read: the circular gauge is gone and a slim edge speed slider stands in its place; the Threadline text column is visibly wider than before.
- Prose never renders under the slider lane (right gutter is clean; no glyphs beneath the thumb).
- Drag the thumb up → speed increases; down → decreases; detents click (the `.bandChange` haptic). The WPM/band readout is legible and updates live.
- Scroll the Threadline away from the active word: the return-to-word button appears **below** the slider in the edge lane (not inside the text box). Tapping it smoothly recenters and the button hides.
- Start a hold-to-read from the Threadline and from the open surface: words stream, the dial returns while reading, the slider is absent. Release → paused → slider returns. (Confirms the slider's drag didn't shadow hold-to-read, and active/cruise gauge is not regressed.)
- Double-tap → Cruise still works; cruise shows the existing engaged dial.
- Toggle reading hand in Settings: the whole rail (slider + readout + button) mirrors to the opposite edge and Threadline mirrors with it.
- Repeat on a small phone (e.g. iPhone SE) and a large one (e.g. Pro Max): the readout, track, and button all fit within the band with no overlap of the progress line or new-text chip.

- [ ] **Step 3: Tune vertical/lane offsets only if needed**

If on-device the recenter button crowds the progress line on small phones, or the readout rides into the pivot word, adjust only these knobs in `App/ReadingView.swift` / the `EdgeSpeedRail` layout: `edgeSliderZoneWidth` (lane width), the `EdgeSpeedRail` button slot `.frame(height:)`/`.padding(.top:)`, or the `readout` `.padding(.bottom:)`. Re-run the simulator build after any change. Keep changes minimal and re-verify Step 2.

- [ ] **Step 4: Commit any tuning**

```bash
git add App/ReadingView.swift
git commit -m "fix: tune edge speed rail geometry from on-device pass"
```

---

## Self-Review

**Spec coverage:**
- "Replace circular gauge with narrow edge speed slider in paused mode" → Task 2 Steps 7-8 (gate dial, add rail). ✓
- "Directly-draggable thumb, top=faster, setBandIndex + detent haptic" → Task 1 `SpeedTrack`. ✓
- "Compact readout: WPM + optional band name + small wpm" → Task 1 `EdgeSpeedRail.readout`. ✓
- "Threadline wider; text never under slider; native momentum; highlight; auto-center on pause; drag scrolls / press holds" → Task 2 Steps 1,4 (inset + state-aware reserve); momentum/highlight/center/gestures live in the untouched `ThreadlineTextView`. ✓
- "Move return-to-word out of scroll box, below the slider, dark circular, only when off-center, smooth recenter, hide when centered" → Task 2 Steps 2,5,6 + Task 1 `EdgeSpeedRail` button. ✓
- "Mini-rail, generous spacing, no overlap of Threadline/progress/chip" → Task 1 layout (readout/track/button slot) + Task 2 Step 8 positioning. ✓
- "Mirror L/R" → Task 2 Step 8 `x = leftHanded ? … : …`; reserve via `gaugeReserve`. ✓
- "Works small + large phones" → proportional `threadlineHeight`/`contextBand` + Task 3 Steps 2-3. ✓
- "Active/hold/Cruise not regressed" → gate is `state == .paused` only; `controlZone` otherwise unchanged; verified Task 3 Step 2. ✓
- Deliberate trade-off (no paused edge-flick-skip) → consequence of the slider owning the lane; documented in spec. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows complete code. ✓

**Type consistency:** `EdgeSpeedRail`/`SpeedTrack` parameter lists, `onSetIndex`/`onRecenter`/`onOffCenterChange`, `edgeSliderZoneWidth`, `offCenter`, and the new `Threadline` signature are referenced identically across Tasks 1-2. `setBandIndex(_:)`, `recenterContext()`, `bands`, `bandIndex`, `wpm`, `band.label`, `shouldShowContext`, `contextBand`, `threadlineHeight` match existing signatures. ✓

**Note on testing:** Build gates + on-device acceptance, not CLI unit tests — the changed code is app-layer (Xcode-only); the `CoreChecks` harness covers pure `SkimCore`, which is untouched.
