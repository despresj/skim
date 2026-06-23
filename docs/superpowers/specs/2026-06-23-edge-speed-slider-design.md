# Edge Speed Slider for Paused Threadline + Relocated Return-to-Word — Design

Date: 2026-06-23
Status: Approved (pending implementation plan)

In paused Threadline mode the circular speed gauge (`SpeedDial`, 118pt reserved
lane) steals too much lateral space and visually competes with the context, and
the return-to-word locator floats inside the Threadline scroll box. Replace the
gauge with a slim, directly-draggable **edge speed slider** in a narrow lane, and
move the return-to-word button out of the scroll box into that same edge lane,
below the slider. Threadline reclaims the freed width.

Guiding principle (`rsvp_casual_reader_spec.md`): a calm flow-reading instrument.
Paused is for inspection — speed stays visible and adjustable but secondary to the
context. Controls are physical and confirmed by subtle haptics.

---

## Scope: paused state only

Only the **paused-with-Threadline** state (`viewModel.state == .paused`) changes.
These keep the existing `SpeedDial` half-dial exactly as-is — no regression:

- `.ready` — the calm `ContextStrip` shows (not the Threadline); dim dial.
- Hold-to-read (`.readingHeld` / precision hold) — lit dial, pivot word hero.
- Cruise (`.cruisePlaying`) — quiet engaged dial.

The swap is gated on `state == .paused`, the only state where the expanded,
scrollable Threadline is shown.

---

## Component 1 — `EdgeSpeedSlider` (new, interactive)

A slim vertical speed instrument in a narrow lane on the reading-hand edge.

- **Lane width:** `edgeSliderZoneWidth = 52` (down from the dial's `gaugeZoneWidth
  = 118`). The visible track is slim (~4pt) centered in the lane; an **amber
  thumb** (~28pt) rides it. The full 52pt lane is the touch target, so the control
  stays comfortably grabbable though the visuals are thin (acceptance: "minimum
  touch target remains usable, even if the visual rail is narrow").
- **Track height:** spans the Threadline band height, so slider and context read as
  paired instruments.
- **Input (directly draggable):** a vertical drag maps thumb position → band index
  and calls `viewModel.setBandIndex(_:)`. **Top = faster** (higher index), matching
  the existing rail-steer direction. `setBandIndex` already clamps to
  `0…bands.count-1` and fires the `.bandChange` haptic only on an actual step, so
  detents feel identical to the dial today. The slider drives speed only — no skip.
- **Readout:** a compact stack near the thumb — WPM number in the warm accent, a
  tiny "wpm", and the band label in small muted text. The band label is the
  optional element and truncates/drops on very narrow screens. Quiet by default;
  brightens while dragging.
- **Layering:** drawn as a **front sibling above** `readingSurfaceGestureLayer`, so
  it consumes its own drag (front-most-wins hit test) — consistent with how every
  other explicit control intercepts first. The surface/rail gesture model is
  unchanged; the `SpeedDial` path still relies on it for active/cruise steering.
- Shown only while `state == .paused`. When not paused, the `SpeedDial` renders as
  today and the slider is absent.

## Component 2 — Relocated return-to-word button

- **Remove from `Threadline.swift`:** the trailing `location.fill` locator overlay
  *and* the 44pt `threadlineLocatorRail` right inset (`textContainerInset.right`).
  Prose then uses the full Threadline width.
- **Lift `offCenter` state up:** `Threadline`'s `onOffCenterChange` callback bubbles
  to a new `@State offCenter` in `ReadingView`. `Threadline` no longer owns the
  button; it only reports off-center.
- **Dock in the edge lane:** the button sits in the same lane as the slider,
  **below** it with generous spacing, in the existing dark circular language
  (`location.fill`, `Color.readingAccent` glyph, `Color.readingSurface` background,
  hairline `Color.readingBorder`). Shown only when `offCenter` is true (active word
  scrolled out of the comfort band). Tap → `viewModel.recenterContext()` (already a
  smooth animated recenter). It clears the progress line and new-text chip.
- Slider + button form a clean vertical mini-rail in the edge lane.

## Layout math (the width win)

- Today (right-hand mode): the right edge consumes `118 (dial) + 44 (locator
  inset) = 162pt` before prose begins.
- After: `edgeSliderZoneWidth = 52`, no locator inset → Threadline reclaims
  **~110pt** of width.
- The paused column becomes `width − edgeSliderZoneWidth − backReserve(64)`. This
  flows through a **state-aware `gaugeReserve`**: it returns `edgeSliderZoneWidth`
  when `state == .paused`, else `gaugeZoneWidth`. `gaugeReserve` is consumed only by
  the paused Threadline layout (`pausedThreadlineLayer`) and `threadlineHitRect`,
  so the change is localized to paused mode.
- `threadlineHitRect` automatically widens with the smaller reserve, keeping
  press-to-scroll vs press-to-read arbitration correct over the new column.

## Mirroring & safety

- The lane sits on the reading-hand side, reusing the existing pattern:
  `leading = leftHanded ? edgeSliderZoneWidth : backReserve`. Right-hand → lane on
  the right; left-hand → mirrored to the left. The slider docks to that screen
  edge with its readout facing inward; the recenter button shares the lane.
- Slider and recenter button never overlap the Threadline, progress bar, or
  new-text chip — they live in the reserved lane, vertically within the band
  (slider) and just below it (button), above the progress cluster.
- Amber accent used sparingly: the thumb and the WPM number; the recenter glyph
  reuses the existing accent treatment.

## Deliberate trade-off

In paused mode the rightmost lane was also where a horizontal flick = skip ±12
could begin (the `.rail` zone == the gauge zone). The interactive slider now owns
that lane, so **edge-flick-skip is superseded while paused**. Skip still works
while reading/holding via the rail, and scrubbing the progress line still seeks.
This is intended: the ticket scopes the lane to speed.

---

## Files touched

- `App/ReadingView.swift` — add `EdgeSpeedSlider` (new private view), a paused-only
  `edgeSpeedSliderLayer` + recenter-button layer (front siblings), make
  `gaugeReserve` state-aware, hide `SpeedDial`/`controlZone` dial while paused, add
  `@State offCenter`, wire `Threadline.onOffCenterChange` to it.
- `App/Threadline.swift` — remove the locator overlay, the `threadlineLocatorRail`
  inset, and the internal `offCenter` ownership; expose `onOffCenterChange` to the
  parent; drop the now-unused `onRecenter` parameter.

## Out of scope

- Any change to `.ready`, hold-to-read, or Cruise gauge treatment.
- Core (`Sources/SkimCore`) changes — this is app-layer UI only; no `CoreChecks`
  assertion is needed.
- Preserving paused edge-flick-skip (deliberately dropped, see above).
- The progress scrubber, new-text chip, utility rail, and back chevron.

## Acceptance criteria (from the ticket)

- In paused Threadline mode, the circular gauge is replaced by a narrow edge speed
  slider.
- Threadline text area is wider than before.
- Text never renders under the speed slider.
- Return-to-word button is no longer inside the scroll text box.
- Return-to-word button appears below the edge speed slider.
- Return-to-word button recenters smoothly.
- Edge speed slider remains usable and readable; the WPM/band readout is legible.
- Layout works on small and large phones (uses proportional band height + reserves).
- Layout mirrors correctly for left-hand and right-hand modes.
- Active/hold/Cruise gauge behavior is not regressed.
