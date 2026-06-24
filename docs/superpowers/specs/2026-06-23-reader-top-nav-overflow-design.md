# Reader Top Nav Bar + Overflow Menu — Design

Date: 2026-06-23
Status: Approved (pending implementation plan)

Replace the Reader's left vertical utility rail with a simple top
navigation/menu pattern: `‹ Reads` at the top-left (app navigation), a `…`
overflow menu at the top-right (tools). The reading surface keeps only what is
actually part of reading — active word, Threadline, edge speed control, progress.

Guiding principle (`rsvp_casual_reader_spec.md`): the reading surface is sacred —
no toolbars competing with the word. Navigation belongs at the top; tools tuck
into an overflow; reading controls stay on the surface only when they are part of
reading.

---

## New chrome model

A parked-only **top bar** across the top of the reading surface:

- **Top-left — `‹ Reads`:** a pill (chevron + the word "Reads"), same calm
  capsule family as `PasteView`'s back pill. Action = the existing
  `viewModel.clearText()`.
- **Top-right — `…`:** an `ellipsis` glyph in the soft circle the utility
  buttons used, opening a native SwiftUI `Menu`.

Both are **fixed** top-left / top-right regardless of reading hand — this is app
navigation, not a reading control, and it sits above the Threadline band, so
handedness is irrelevant. Both fade together on the existing
`viewModel.shouldShowPauseChrome` gate: clearly visible while parked
(ready/paused), gone during hold-to-read and Cruise. Top chrome never competes
with the active word.

### `‹ Reads` semantics (no new navigation logic)

`viewModel.clearText()` already does the right thing: it cancels playback, saves
progress (the read stays resumable on disk), drops the loaded text, sets
`state = .idle`, and calls `refreshPendingResume()` — so `ContentView` routes to
the Reads/Recents shelf (`ResumeView`) when there's something to resume, else the
paste screen. So `‹ Reads` is the current back action, only relabeled and moved.
This is navigation, not a reading control.

## Overflow menu

A native SwiftUI `Menu` whose items use `Label(_, systemImage:)`:

1. **Settings** (`gearshape`) → `openSettings()`
2. **Export video** (`film.fill`) → `openExport()`
3. **Add idea** (`lightbulb`) → `openIdeas()`
4. **Copy text** (`doc.on.doc`) → `viewModel.copyCurrentText()` (copies the full
   read, fires the soft `.copy` haptic) + a brief centered **"Copied" pill**
5. **Gesture tips** (`questionmark.circle`) → re-shows the existing
   `GestureHintsOverlay` (sets `showGestureHints = true`)

Settings / Export / Add idea reuse the existing helpers unchanged, so cruise
pause-on-open / resume-on-close and the sheet presentations behave exactly as
before. Export still opens the reader-based export sheet; Ideas still opens the
idea capture panel; Settings still opens Settings.

### Copy confirmation

The menu closes on tap, so the old in-place checkmark is gone. Confirmation is
now: the soft `.copy` haptic (already inside `copyCurrentText()`), plus a brief
**"Copied" pill** — a `checkmark` + "Copied" in the same translucent
surface/hairline capsule family as the flick flash / scrub readout. It is
**centered** (consistent with `NavFlashLabel` placement, clear of the high active
word), fades in on copy and out after ~1s, and is never hit-testable.

## Removals (no duplicate controls on the surface)

Delete from `App/ReadingView.swift`:

- `utilityRail`, `utilityButton(icon:label:tint:action:)`, `utilityOpacity`
- the centered back chevron `editControl` and its `editVisible` flag
- the now-unused `didCopy` state (the rail checkmark it drove is gone)

The four tools (settings/export/ideas/copy) live only in the overflow menu; the
copy action exists in exactly one place.

## Bonus breathing room — `backReserve` 64 → 28

The old back chevron sat vertically centered on the edge opposite the rail, and
the paused Threadline reserved `backReserve = 64`pt to clear it. With the button
gone from that edge, reduce `backReserve` to **28** (matching the calm
`ContextStrip` horizontal margin) so the Threadline reclaims that strip too. This
is the only consumer of `backReserve` (the paused Threadline layout +
`threadlineHitRect`), so the change is localized.

## State changes in `ReadingView`

- Remove `@State didCopy`.
- Add `@State showCopied` (drives the "Copied" pill).
- `copyText()` now drives `showCopied` instead of `didCopy`.
- Add `showGestureTips()` → `showGestureHints = true`.
- Body: replace `utilityRail` and `editControl` with a single `topBar`; add the
  `copiedPill` layer. `newTextChip`, `scrubberLayer`, the gesture layers, and the
  edge speed rail are untouched.

## Scope

One file: `App/ReadingView.swift`. `copyCurrentText()` already exists in the view
model; no view-model or core change. App-layer UI only — no `CoreChecks`
assertion needed.

## Out of scope

- The edge speed slider, Threadline internals, progress scrubber, new-text chip,
  and the surface gesture model.
- Any change to what the menu's sheets do internally.

## Acceptance criteria (from the ticket)

- Reader has `‹ Reads` in the top-left.
- Reader has `…` in the top-right.
- The left vertical utility rail is gone.
- Settings / Export / Add idea / Copy text remain accessible through the overflow
  menu (plus Gesture tips).
- Copy text still copies the full current read, with haptic + a "Copied" pill.
- Threadline has more visual breathing room (back chevron gone from its edge;
  `backReserve` reduced).
- Active word remains the visual hero.
- No tool buttons overlap Threadline text (top chrome sits above the band).
- `‹ Reads` and `…` are shown while parked; hidden/faded during hold-to-read and
  Cruise.
- Works on small and large devices (top bar uses standard top insets; menu is
  native).
