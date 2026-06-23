# Copy Current Text & Recents Access — Design

Date: 2026-06-23
Status: Approved (pending implementation plan)

Two small, focused additions to the reading UX:

1. A **Copy** control on the reading surface to grab the full read text while parked.
2. A **Recents** affordance on the Paste / New Text screen so the saved-reads
   shelf is always reachable — while preserving a distinct back affordance when
   the user actually arrived from Reads.

Guiding principle (from `rsvp_casual_reader_spec.md`): the reading surface is
sacred. No chrome while streaming. Controls are calm and physical; confirmation
is subtle and local, never a banner.

---

## Feature 1 — Copy button on the Reader surface

### Goal

Allow the user to copy the full current read text while paused / parked.

### Placement

- Add **Copy** as a fourth action in the existing top-left utility rail
  (`utilityRail` in `App/ReadingView.swift`).
- Order, top → bottom:
  1. Settings
  2. Export video
  3. Ideas
  4. Copy
- Use the same circular `utilityButton(...)` style as the existing rail (44pt,
  soft surface, hairline border) so the four read as one set.
- Inherits the rail's visibility gate (`shouldShowPauseChrome` /
  `utilityOpacity`): visible only when the parked/pause chrome is visible.
- Hidden while actively streaming (thumb hold) or cruising.

### Icon

- SF Symbol `doc.on.doc`.
- Muted tint by default (matches Settings / Ideas).
- Accessibility label: **"Copy text"**.

### Action

- Copy the full source text of the current read to `UIPasteboard.general`.
- Use the same canonical prose source the exporter uses: `viewModel.reviewText`.
- Add `ReaderViewModel.copyCurrentText()` so the view stays stateless and simple.

### Confirmation

- Add a typed haptic event `Haptics.Event.copy`, soft, in the same intensity
  family as `.pause` / `.newText` (~0.5).
- Swap the button icon to `checkmark` for ~1 second, then fade back to
  `doc.on.doc`. Local view state on the rail button drives this.
- No global toast / banner for v1.
- Confirmation stays local and calm.

### Acceptance

- Copy button appears only when parked / pause chrome is visible.
- Copy button does not appear during active streaming or Cruise.
- Tapping Copy places the full read text on the pasteboard.
- Button briefly shows a checkmark, then returns to `doc.on.doc`.
- A soft haptic fires.
- No layout shift in the utility rail (four buttons fit the existing column).

---

## Feature 2 — Recents access from Paste / New Text

### Goal

Give the user a clear way back to the saved-reads shelf from the Paste /
New Text screen (`App/PasteView.swift`, the "Read faster without losing the
thread." page) — without stranding them when they launched directly into it.

### Behavior

The top-left affordance on PasteView is context-dependent:

- **Arrived from Reads** (`canReturnToReads == true`): keep the existing
  **`‹ Reads`** back pill. This is true back navigation — return to the exact
  previous Reads shelf.
- **Opened Paste / New Text directly** and the library is non-empty: show
  **`Recents`**, which opens the Reads shelf / library from a standalone state.
- Never strand the user on Paste / New Text with no path back to the shelf when
  saved reads exist.

### Product distinction (important)

- `‹ Reads` means *return* to the Reads shelf you came from (back navigation).
- `Recents` means *open* the Reads shelf / library from a standalone paste state.
- Do **not** make `Recents` perform back-navigation. Keeping these distinct is
  what keeps the app from feeling slippery.

### Implementation notes

- Add a `hasAnyReads` check (any saved reads at all), distinct from the existing
  "has active resumable read" notion. Likely a count/exists query on the store
  surfaced through `ReaderViewModel`.
- `Recents` must open the shelf even if every saved read is finished — do not
  require a pending active / resumable read to show the shelf.
- The shelf leads with the most recent reads, finished or unfinished.
- Existing finished / "read again" behavior still applies (tapping a completed
  read reopens at the top; the completed record is untouched until the user
  starts reading again).
- Routing: the shelf (`ResumeView`) currently renders when
  `pendingResume != nil && state == .idle`. The `Recents` path must be able to
  open it from a most-recent read (active or finished) rather than only an
  active resume candidate. This is a small touch in `ReaderViewModel` (and
  possibly `SkimStore`) — open the shelf from the most-recent read regardless of
  status, without changing launch routing.
- The existing `canReturnToReads` / `returnToReads()` back path is unchanged.

### Launch behavior — unchanged

- The app still opens to the Welcome Back / Reads shelf on launch when there's
  something to resume.
- This feature only *adds* a path back to the shelf from PasteView; it does not
  change what screen launches first.

### Acceptance

- Paste / New Text has access to saved reads whenever the library is non-empty.
- If the user came from Reads, the back pill remains semantically `‹ Reads`.
- If the user launched into Paste / New Text directly, `Recents` opens the
  Reads shelf.
- `Recents` works even when the library contains only finished reads.
- No duplicate read records are created by opening the shelf.
- Launch behavior remains unchanged.

---

## Out of scope (v1)

- Global toast / banner confirmations.
- Any change to launch routing or the Welcome Back shelf itself.
- Reorganizing the utility rail beyond appending the Copy button.
- Core (`Sources/SkimCore`) changes are expected to be minimal; both features
  live mostly in the app layer. If a `hasAnyReads`/most-recent query lands in
  `SkimStore`, add a matching `CoreChecks/main.swift` assertion per the repo
  convention.
