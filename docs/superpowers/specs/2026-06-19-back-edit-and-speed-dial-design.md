# Back-to-edit control + speed dial + refined palette

**Date:** 2026-06-19
**Status:** Approved (design), pending implementation
**Scope:** App layer only (`App/`). No `SkimCore` changes.

## Motivation

Two product gaps and one polish pass:

1. Once text is loaded, `ContentView` only ever shows `ReadingView` — there is no
   path back to change or edit the text you are reading.
2. The vertical speed "rail" reads as a slider; the desired feel is a **dial**.
3. The palette is "a bit off" — darks are dead-neutral/harsh, the amber is dusty,
   and the light bronze accent is borderline for contrast.

Guiding constraint (from `rsvp_casual_reader_spec.md`): the reading surface is
**sacred** — no buttons/toolbars while actively reading. Controls are physical
gestures confirmed by subtle haptics.

## 1. Back / edit control

- A small, calm **`chevron.left` inside a faint circle**, pinned to the **left
  edge, vertically centered** — mirroring the right-edge thumb rail.
- **Visibility:** shown only when **not actively reading** — i.e. in `ready`,
  `paused`, and `completed` states. It **fades out the instant a hold begins**
  (reuses the same `isHolding` fade/animation the rail uses) and is
  **non-interactive while holding** (`allowsHitTesting(false)`), so it never
  competes with the read gesture. The sacred surface stays clean during flow.
- **Action:** tap → returns to the paste screen **prefilled with the current
  text**, so the user can tweak or replace it. Editing + "Start reading"
  re-tokenizes from the top (existing `load(_:)` path).
- **Styling:** `readingMuted` at rest → `readingForeground` on press; quiet,
  no text label (chevron only).

## 2. Speed control → dial (visuals only)

- The vertical track + knob (`SpeedRail`) becomes a **circular dial / gauge**
  (`SpeedDial`):
  - A **partial arc (~270°)** with a faint background track.
  - An **accent arc that sweeps from slow → current** position.
  - A **knob dot riding on the arc** at the current band.
  - **Per-band tick marks** along the arc, kept only while bands are sparse
    (`count <= 9`), matching today's rail behavior.
  - **Band label + wpm in the dial center**, revealed while holding (parity with
    the current rail, which shows label + wpm on active hold).
  - Dim at rest (reads as a control), amber/active while held.
- **Gesture is unchanged.** `ReadingView.holdGesture` still maps hold +
  slide-up = faster / slide-down = slower onto `setBandIndex`. The dial is purely
  a new rendering of `bandIndex / bands.count`. The first-use hint (hand +
  up/down chevrons) stays.

## 3. View-model changes (`ReaderViewModel`)

- Expose the loaded text for prefill:
  ```swift
  /// Raw text currently loaded, exposed so the edit screen can prefill.
  var editableText: String { loadedText ?? "" }
  ```
- Add a navigation method:
  ```swift
  /// Leave the reading surface to edit/replace the text. Routes ContentView
  /// back to PasteView (via .idle), prefilled from `editableText`.
  func beginEditing() {
      cancelPlayback()
      state = .idle
  }
  ```
  No new state-machine case — `state = .idle` already routes `ContentView` to
  `PasteView`. `PasteView` prefills its `draft` from `editableText` on creation:
  ```swift
  init(viewModel: ReaderViewModel) {
      self.viewModel = viewModel
      _draft = State(initialValue: viewModel.editableText)
  }
  ```
- **Known edge case (acceptable for v1):** if the app is backgrounded while
  editing and the clipboard has since changed, the existing foreground reload
  (`loadClipboard`) will replace the draft — identical to today's
  foreground-reload behavior.

## 4. Refined palette (`Theme.swift`)

Synthesized from a three-perspective review (Stripe designer / Airbnb acceptance
tester / Uber developer). Consensus: keep the "reading by lamplight" amber soul,
but warm the darks (no dead-neutral/harsh black), warm the off-white to cut
glare, make the amber more luminous-gold, deepen the light bronze to pass
**WCAG AA** with white text, and put neutrals on a consistent warm ramp.

| Token | Dark (warm lamplight) | Light (warm paper) |
|---|---|---|
| `readingBackground` | `#11100D` warm near-black | `#FBF7F0` warm paper |
| `readingSurface` | `#211F1B` | `#FFFFFF` |
| `readingForeground` | `#F5F2ED` warm off-white | `#211C17` warm ink |
| `readingMuted` | `#9A958C` warm gray | `#6B665E` |
| `readingBorder` | white @ 10% | black @ 8% |
| `readingAccent` | `#FAC26B` luminous gold | `#A86B14` deep bronze (AA w/ white) |
| `readingOnAccent` | `#1A1610` | `#FFFFFF` |
| `readingPivot` | `#FAC26B` gold (= accent) | `#A86B14` bronze (= accent) |
| canvas top-glow | `#29241C` warm lift | `#FFFAF2` |

- The **dial arc** uses `readingAccent`; the **back chevron** uses
  `readingMuted` → `readingForeground`.
- Accent contrast intent: light `#A86B14` with white (`readingOnAccent`) on the
  primary pill targets AA for the pill's label size.

## 5. Files touched

- `App/ReaderViewModel.swift` — add `editableText`, `beginEditing()`.
- `App/PasteView.swift` — prefill `draft` from `editableText`.
- `App/ReadingView.swift` — add left-edge back control; replace `SpeedRail`
  with `SpeedDial`.
- `App/Theme.swift` — refined palette values.

## 6. Core / build / testing

- **No `SkimCore` changes** — all App-layer UI + view-model navigation, so
  no new `CoreChecks` assertions (the convention only requires them for
  tokenizer/pacing behavior).
- Verify `swift build` still compiles the core.
- Visual check in the iOS simulator (Xcode): back control appears/hides with
  hold state, edit prefills text, dial sweeps with slide, palette in both
  light and dark.

## Out of scope (YAGNI)

- Rotary/arc gesture for the dial (kept the existing vertical slide).
- Persisting edits across a clipboard-changed background (v1 edge case above).
- Any new reading/semantic features from the full spec.
