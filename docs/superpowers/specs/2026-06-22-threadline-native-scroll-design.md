# Premium native scroll for the paused Threadline

**Date:** 2026-06-22
**Status:** Approved design — ready for implementation plan
**Area:** `App/Threadline.swift`, `App/ReadingView.swift`, `App/ReaderViewModel.swift`

## Problem

When the reader pauses, the Threadline shows a window of surrounding prose so the
user can see where they are. Today that window is scrolled by a **custom
drag-offset** mechanism: the `UITextView` is non-interactive
(`isUserInteractionEnabled = false`) and the one global SwiftUI `DragGesture`
imperatively nudges its `contentOffset` through `ThreadlineScroller.scroll(by:)`.
There is no momentum, no deceleration, and no rubber-band bounce — it tracks the
finger 1:1 and stops dead on release. It feels hand-rolled, not native.

**Guiding product principle:** active reading is a *stream*; the paused Threadline
is a *map*. The map must feel like a high-quality native scroll surface — smooth,
momentum-based, easy to inspect, easy to return from. The non-negotiable is native
momentum: *if it doesn't glide like iOS, it feels fake.*

## Core decision

Native momentum/deceleration/bounce comes from `UIScrollView` physics, which only
work when the scroll view **owns its own pan touches**. So we make the paused
Threadline a **front interactive layer** whose `UITextView` is natively scrollable
(`isScrollEnabled = true`, `isUserInteractionEnabled = true`).

This deliberately breaks the codebase's "a single SwiftUI gesture owns every touch"
principle — but **only inside the paused prose column**. Everywhere else, and in
every other reader state, the global `readingSurfaceGestureLayer` is unchanged.

Decisions locked with the user:

- **Arbitration:** UIKit owns it (scroll view pan + long-press-to-read + double-tap-cruise).
- **Recenter spot:** the active token lands **slightly above center** on recenter.
- **Locator affordance:** a small **amber locator icon** (no text), on the open side.

## Architecture

### Layers, before → after

Today (`bottomContent`, all `.allowsHitTesting(false)`):
- `.ready` state → `ContextStrip` (calm static band)
- `.paused` state → `Threadline` (auto-centered, nudged via `ThreadlineScroller`)

After:
- `.ready` `ContextStrip` stays exactly where it is — non-interactive, in `bottomContent`.
- `.paused` `Threadline` **moves out** of `bottomContent` into its own **front
  sibling layer** in the root `ZStack`, inserted just after
  `readingSurfaceGestureLayer` (so it intercepts touches first) and before
  `scrubberLayer` (so the scrubber still wins at the very foot). Shown only when
  `viewModel.state == .paused`. It keeps the existing padded column
  (`gaugeReserve` on the gauge side, `backReserve` on the back-button side), so it
  never renders under the gauge lane, back chevron, scrubber, progress line, or
  new-text chip.

### Gesture arbitration inside the band (all UIKit)

Recognizers attached to the scroll view / its container, coordinated by the
`UIViewRepresentable`'s `Coordinator` (acting as target + `UIScrollViewDelegate`):

1. **Scroll** — the scroll view's built-in `panGestureRecognizer`. Native
   momentum, deceleration, rubber-band bounce, 1:1 finger tracking.
2. **Hold-to-read** — `UILongPressGestureRecognizer`,
   `minimumPressDuration = minHoldToRead` (≈0.12s), `allowableMovement` ≈10pt. On
   `.began`, fire the `onHoldRead` callback. Because `allowableMovement` is small,
   moving the finger past ~10pt before the timer fires **fails** the long-press and
   the scroll pan takes over — *scroll wins*. Staying still past 0.12s fires the
   read. Once reading starts, `state` leaves `.paused`, so SwiftUI removes the band
   entirely — scrolling cannot begin mid-read. (The matching release → pause is the
   long-press `.ended`/`.cancelled` → `onRelease`.)
3. **Cruise** — `UITapGestureRecognizer`, `numberOfTapsRequired = 2` → `onCruiseToggle`.
   A clean double tap only; a drag never triggers it.
4. **No scroll haptics.** Scrolling fires neither reading nor cruise haptics.

Thresholds (`minHoldToRead` 0.12s, movement ~8–12pt) are tunable on device.

### SwiftUI ↔ UIKit coexistence — the #1 risk

The global `readingSurfaceGestureLayer` (a `DragGesture(minimumDistance: 0)`) still
sits in the `ZStack`, below the interactive Threadline. We must guarantee it does
not double-handle touches that begin in the band. Plan:

- In `surfaceDragGesture`'s `onChanged`, when the press **begins inside the paused
  Threadline frame**, set a `yieldToThreadline` flag, cancel any pending hold timer,
  and `return` on every subsequent event — the SwiftUI gesture becomes a no-op there
  and the UIKit recognizers own the interaction. (This replaces — and is simpler
  than — today's `gestureStartInContext` / `contextScrolling` custom-scroll block.)
- **Validate on device first** that (a) native scroll actually begins from a touch
  in the band and (b) a stationary hold still starts reading, i.e. the SwiftUI
  `DragGesture` is not claiming the touch and starving the scroll pan.
- **Fallback if it interferes:** scope the SwiftUI surface gesture's hit region to
  exclude the paused Threadline band (e.g. a `contentShape` that omits the band, or
  gating `allowsHitTesting` on that rect), so the band's touches reach UIKit cleanly.

This is the one genuinely fiddly integration point; everything else is mechanical.

## Recenter logic ("here you are" without fighting the user)

Separate **highlight** from **scroll position**:

- **Highlight** (current sentence to full ink + active token to amber, via the
  existing `ReadingContext.proseMap` index→character-range map — already correct for
  repeated words, never string search) updates whenever `activeIndex` changes. This
  is a cheap in-place attribute edit and performs **no scrolling**, so the highlight
  stays accurate even while the user scrolls.
- **Recenter scroll** fires **only** when `contextRecenterTick` changes — never
  merely because `activeIndex` changed. Targets **slightly above center**
  (active-token rect mid-point placed a fixed fraction above the viewport middle,
  ~40% down rather than 50%), clamped to scroll bounds, **animated**
  (`setContentOffset(_:animated:)`).

Discrete recenter triggers (each bumps `contextRecenterTick`):

| Trigger | Status |
| --- | --- |
| Enter pause (`stopHolding`, `pauseCruise`) | already bumps |
| Begin scrub / scrub step | already bumps |
| Rewind / forward flick **while paused** | **add** `bumpRecenter()` to `rewind12Words` / `forward12Words` (paused only — harmless when context hidden) |
| Tap the "Back to word" locator | **add** — new VM call, e.g. `recenterContext()` that bumps |

Free manual scrolling never bumps the tick, so it never snaps back.

## "Back to word" locator affordance

- **Look:** a small amber locator glyph (SF Symbol `scope` or `location.fill`) in a
  soft circular background (`readingSurface` + `readingBorder`, accent-tinted).
  No text. Placed unobtrusively on the **open** (non-gauge) side of the band, inset
  from the edge, vertically toward the band's lower-middle.
- **Visibility:** shown when the active token's glyph rect leaves a comfortable
  central band of the viewport (i.e. the user has scrolled it away); hidden when the
  token is visible and roughly centered. Computed in `scrollViewDidScroll` by
  comparing the active range's rect to the viewport's central band; the SwiftUI
  `@State` Bool is flipped **only when crossing the threshold**, never per frame, so
  scrolling stays smooth. Fades in/out (`.opacity`, ~0.2s).
- **Action:** tap → `viewModel.recenterContext()` (bumps the tick → animated
  recenter) + a single light `UIImpactFeedbackGenerator` tick. This is a recenter
  control tap, not a scroll, so the "no scroll haptics" rule is preserved.

## Visual & layout (mostly already present)

- **Legibility tiers** (keep): surrounding text `readingForeground` @0.55 (muted but
  legible), current sentence full ink, active token amber + semibold.
- **Edge fades** (keep): the existing top/bottom `LinearGradient` mask — a viewport
  into the text, no hard box. The centered/slightly-above-center token sits in the
  fully-opaque middle, never under a fade.
- **Scroll indicator:** enable a subtle native vertical indicator
  (`showsVerticalScrollIndicator = true`, low-contrast style) — it auto-shows during
  interaction and auto-hides, reinforcing "native." (Acceptable to keep hidden if it
  reads as utilitarian on device.)
- **Column / zones:** unchanged padded column keeps the Threadline inside the Text
  Scroll Zone, clear of the gauge lane, back button, scrubber, progress line, and
  chip. Padding swaps with `leftHanded`, so it works in both hands; heights are
  proportional (`threadlineHeight = min(300, screenHeight * 0.40)`), so it works on
  small and large devices.

## Performance

- Attributed string built **once per token-set change** (existing `signature`
  cache); never rebuilt per frame.
- Highlight = in-place `addAttribute` edits on the existing storage.
- Native scroll = zero per-frame SwiftUI work.
- Locator Bool flips only on threshold cross.
- Recenter uses a single animated `setContentOffset`.
- Long single paragraphs (500+ words) handled by TextKit 1, as today.

## Components

| Component | Change |
| --- | --- |
| `ThreadlineTextView` (`UIViewRepresentable`) | Make scroll view interactive + natively scrollable; add long-press / double-tap recognizers in the `Coordinator`; add `UIScrollViewDelegate` for locator threshold; expose `onHoldRead` / `onRelease` / `onCruiseToggle` callbacks and an `isOffCenter` callback/binding; keep proseMap highlight; recenter only on `recenterKey` change, slightly above center. |
| `Threadline` (SwiftUI) | Host the text view + edge-fade mask + the amber locator overlay; own the `showLocator` `@State`; wire callbacks to reader intents. |
| `ThreadlineScroller` | Repurpose: drop `scroll(by:)`; keep a weak text-view handle for programmatic `recenter(animated:)` and a "is active token centered enough" query if needed. |
| `ReadingView` | Move paused `Threadline` to a front interactive sibling layer; make `surfaceDragGesture` yield for band-origin presses; delete `gestureStartInContext`, `contextScrolling`, `lastScrollTranslation`, `contextBand` and the onChanged context block. |
| `ReaderViewModel` | Add `bumpRecenter()` to `rewind12Words`/`forward12Words` (paused); add `recenterContext()`. |

## Out of scope (YAGNI)

- Single-tap-to-brake inside the Threadline (Cruise hides the band, so there is no
  paused single-tap action to honor here).
- Persisting/restoring scroll position across resume — resume returns to the active
  stream; the next pause recenters fresh.
- No XCTest target (CLT-only core harness doesn't cover UIKit views); validation is
  on-device per the QA checklist below.

## Acceptance criteria

- Paused Threadline scrolls with native momentum, bounce, and smooth tracking; no
  stutter, no mechanical snap.
- Dragging the band scrolls; it does not start reading. A stationary press-and-hold
  starts reading. A small drift under threshold still reads; vertical travel past
  threshold scrolls instead.
- Scrolling away does not snap back; the amber locator appears and recenters
  smoothly on tap; it hides when the token is centered.
- Highlight maps to the correct token occurrence, including repeated words, and
  stays accurate while scrolling.
- Threadline stays clear of the gauge/control zones; top/bottom fades look polished;
  no jank on long text; works in both hands and on small/large devices.

## QA checklist (on device)

1. Pause → active token is slightly above center.
2. Flick vertically → momentum scroll.
3. Slow drag → smooth 1:1 tracking.
4. Press-and-hold still → reading starts.
5. Slight drift under threshold during hold → still reads.
6. Vertical move past threshold → scroll wins, no read.
7. Scroll far → no snap-back, locator appears.
8. Tap locator → smooth animated recenter.
9. Repeated words ("the the the") → correct occurrence highlighted.
10. Long paragraph and short text both usable.
11. Left- and right-hand modes.
12. Small and large phone layouts.
