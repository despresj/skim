# Clause-granularity replay flick

**Date:** 2026-06-19
**Status:** ❌ Superseded — not built. Replaced by fixed 12-word rail flicks
(see `2026-06-19-cruise-and-12-word-navigation-design.md`). Sentence/clause
semantic replay was dropped in favor of a predictable fixed jump; left here for
the design rationale only.
**Scope:** `SkimCore` (new semantic index) + `App/` (gesture + view-model + haptics).

## Motivation

Today the left flick always replays a whole **sentence** (`replayCurrentSentence`).
That is sometimes too coarse: you missed two words, not the whole thought, and a
full-sentence rewind overshoots. The instinct to "go back a few words" is real —
but a **fixed word count** is the exact pattern the product spec rejects
(problem #3: *"Back button moves one word… user has to think about indexes.
Semantic replay is more natural than time-based rewind."*). A fixed count also
lands you mid-phrase, with no clause boundary to re-anchor on.

So the finer step is still **semantic** — a *clause* — and the control stays a
single physical metaphor: **how far you flick decides how far back you go.**

- **Short left flick → replay current clause** (reel back clause by clause).
- **Long left flick → replay current sentence** (today's behavior, now on the
  longer throw).

No tap-counting (rejected: collides with cruise's double-tap, taxes the instant
hold-to-read with tap-disambiguation latency, fails "obvious after one use").

## 1. Core: a `clauseIndex` on every token (`SkimCore`)

Clause boundaries currently survive only as the `1.4×` `delayMultiplier`, which
`max()` can mask (a clause-ending word at a paragraph break becomes `2.8×`). So
derive nothing from the multiplier — emit an explicit index, mirroring
`sentenceIndex`. This is exactly the convention CLAUDE.md calls for: *"emit the
indices now so semantic replay drops in cleanly later."*

- `ReadingToken` gains `clauseIndex: Int` (added to the stored props and `init`,
  alongside `sentenceIndex`).
- `Tokenizer` maintains a running `clauseIndex`, incremented whenever a
  clause-or-larger boundary passes:
  - after a token whose trailing punctuation is a **clause** ender (`, ; :`),
  - after a token that **ends a sentence** (a sentence end is also a clause end),
  - at a **paragraph break** with no terminal punctuation.

  ```swift
  let endsClause = punctuation.map(clauseEnders.contains) ?? false
  // …assign token with current sentenceIndex AND clauseIndex…
  if endsSentence { sentenceIndex += 1; clauseIndex += 1 }
  else if endsClause { clauseIndex += 1 }
  // paragraph-break fallthrough (mirrors the sentence bump):
  if !lastWasSentenceEnd && !words.isEmpty { sentenceIndex += 1; clauseIndex += 1 }
  ```

Worked example — `"Hello, world. Next."`:

| token | sentenceIndex | clauseIndex |
|---|---|---|
| `Hello,` | 0 | 0 |
| `world.` | 0 | 1 |
| `Next.`  | 1 | 2 |

Three clauses; `"Hello,"` and `"world."` are the two clauses of sentence 0.

## 2. Core tests (`CoreChecks/main.swift`)

Per convention, tokenizer behavior gets matching assertions. Add:

- `clauseIndex` sequence for `"Hello, world. Next."` is `[0, 1, 2]`.
- A clause-ender at a paragraph break still advances `clauseIndex` (guards the
  `max()`-masking case the multiplier can't represent).
- `clauseIndex` is monotonic non-decreasing and `>= sentenceIndex` at every token
  (every sentence boundary is also a clause boundary).

## 3. View-model: clause replay (`ReaderViewModel`)

Mirror `replayCurrentSentence` exactly, so the **reel-back-on-repeat** feel is
identical — flick again from a clause start steps to the previous clause:

```swift
/// Flick a short throw toward the past: jump to the first word of the current
/// clause. If already at that word, step back to the previous clause — so
/// repeated short flicks reel back clause by clause.
func replayCurrentClause() {
    guard let token = currentToken else { return }
    let start = firstIndex(ofClause: token.clauseIndex) ?? 0
    if currentIndex == start, token.clauseIndex > 0 {
        jump(to: firstIndex(ofClause: token.clauseIndex - 1) ?? 0, haptic: .replayClause)
    } else {
        jump(to: start, haptic: .replayClause)
    }
}

private func firstIndex(ofClause clause: Int) -> Int? {
    tokens.firstIndex { $0.clauseIndex == clause }
}
```

`replayCurrentSentence` is unchanged (keeps its `.replay` haptic).

## 4. Gesture: graduated left flick (`ReadingView`)

Keep the axis-locked joystick. Only the horizontal branch changes: instead of
firing the instant `dx` crosses one threshold, **track the peak excursion and
commit on the inbound return**, choosing the level by how far the peak reached.
Deciding on the return (not the apex) is what lets one throw pick clause vs.
sentence; it fires a few ms later than today — imperceptible, and it matches the
natural out-and-back flick the rail already documents.

New tunables (alongside `flickThreshold`):

```swift
private let clauseFlick: CGFloat = 44    // short throw → clause (was flickThreshold)
private let sentenceFlick: CGFloat = 110 // long throw  → sentence
```

New gesture state: `@State private var flickPeakDx: CGFloat = 0` (signed).

Horizontal branch:

```swift
case .horizontal:
    if abs(dx) > abs(flickPeakDx) { flickPeakDx = dx }      // remember the apex
    // Commit once, as the thumb eases back inside the clause line.
    if flickArmed, abs(flickPeakDx) >= clauseFlick, abs(dx) < clauseFlick {
        if flickPeakDx < 0 {                                 // left → into the past
            abs(flickPeakDx) >= sentenceFlick
                ? viewModel.replayCurrentSentence()
                : viewModel.replayCurrentClause()
        } else {                                             // right → forward
            viewModel.skipSentence()
        }
        flickArmed = false
        flickPeakDx = 0
    }
```

- **Deadzone re-arm** (`magnitude < deadzone`) also resets `flickPeakDx = 0`
  (alongside the existing `axis = nil` / `flickArmed = true`), so the next flick
  starts clean.
- **Lift without returning:** in `onEnded`, before `stopHolding()`, if
  `flickArmed && abs(flickPeakDx) >= clauseFlick`, fire the same level selection
  (so a flick-and-release still registers). Then reset state as today.

Velocity-independent: a slow, long drag back is still a *sentence* (peak decides,
not speed); a quick short tick is a *clause*.

## 5. Haptics: a lighter tick for the smaller jump (`Haptics`)

The earlier haptics pass argued for restraint, but this is the on-brand
exception — feedback intensity should encode jump *size* so the rail stays
eyes-free. Add one event:

```swift
case replayClause   // short flick: reeled back one clause
```

- `.replayClause` → `medium.impactOccurred(intensity: 0.55)` (lighter).
- `.replay` (sentence) stays `medium 0.8` (heavier).

So the thumb *feels* "small step back" vs. "big step back" without looking.

## 6. Forward (right flick) stays sentence-only — deliberate

No clause-granularity on skip. Skipping forward into a mid-sentence clause drops
you in with no *preceding* context to re-anchor on — worse re-entry than landing
on a sentence start. Per spec principle #3, recovery (back) is where precision
pays; skipping is coarse by nature. Right flick keeps `skipSentence()` unchanged.

## 7. Files touched

- `Sources/SkimCore/ReadingToken.swift` — add `clauseIndex` (prop + init).
- `Sources/SkimCore/Tokenizer.swift` — maintain/emit `clauseIndex`.
- `Sources/CoreChecks/main.swift` — clause-index assertions (§2).
- `App/ReaderViewModel.swift` — `replayCurrentClause()`, `firstIndex(ofClause:)`.
- `App/ReadingView.swift` — graduated flick: `clauseFlick`/`sentenceFlick`,
  `flickPeakDx`, peak-on-return commit, `onEnded` fallback.
- `App/Haptics.swift` — `.replayClause` event.

## 8. Build / testing

- `swift build` then `swift run CoreChecks` — the new clause assertions must pass
  (core change, so CoreChecks is required, not optional).
- Simulator is for layout only; the flick's short-vs-long feel **must be checked
  on a real iPhone** (spec §"The Simulator Lies"): confirm a small tick reels one
  clause, a full throw reels a sentence, and the two haptics feel distinct.

## Out of scope (YAGNI)

- Forward clause skip (see §6).
- Paragraph-level flick (a third, longer detent) — revisit only if sentence
  rewind itself feels too fine in long-paragraph text.
- Within-stroke progressive multi-step (clause *then* sentence in one throw) —
  one commit per throw keeps the reel-back model predictable; repeat to go further.
