# Cruise mode + 12-word rewind / fast-forward

**Date:** 2026-06-19
**Status:** Implemented (App + one `SkimCore` enum case); pending on-device feel check.
**Scope:** `SkimCore/ReaderState`, `App/ReaderViewModel`, `App/ReadingView`, `App/Haptics`.

## Decision

A clean physical grammar with no dynamic math and no ambiguity:

- **Canvas double-tap** → enter **cruise** (hands-free autoplay).
- **Canvas single-tap while cruising** → pause.
- **Rail flick left** → rewind **exactly 12 words**.
- **Rail flick right** → fast-forward **exactly 12 words**.
- **Rail touch / hold** → precision read (unchanged); **release** → pause.
- **Rail vertical drag** → speed band (unchanged).

Fixed 12-word jump. No WPM-scaled rewind. No sentence/clause replay (the prior
clause-granularity spec is superseded). Flicks **preserve state**: paused stays
paused, precision keeps reading, cruise keeps cruising.

## Surface split (no tap/hold ambiguity)

- **Canvas** owns *mode switching* only (double-tap → cruise, single-tap →
  pause-cruise). Implemented as a transparent full-surface tap layer
  (`canvasTapLayer`) sitting **above** the passive word/context views but
  **below** the rail and back chevron, which win their own regions. Inert
  (`allowsHitTesting(false)`) while `precisionHeld`/`completed`/`idle`, so the
  reading surface stays sacred and the catcher can't swallow a rail touch.
- **Rail** owns *manual control + navigation*. Preserves instant hold-to-read —
  no tap/double-tap recognizer on the rail, so zero added latency.

## State machine (`ReaderState`)

`readingHeld` renamed to **`precisionHeld`** (matches `ReadingMode`); added
**`cruisePlaying`**:

```
idle · ready · precisionHeld · paused · cruisePlaying · completed
```

Transitions added: `ready|paused → cruisePlaying` (double-tap),
`cruisePlaying → paused` (single-tap), `cruisePlaying → completed` (end of text),
`cruisePlaying → paused` on background.

## ViewModel (`ReaderViewModel`)

- `mode` is now `private(set) var` (was `let`); flips `.cruise` ⇄ `.precisionHeld`.
- `enterCruise()` — guard `paused|ready`; `mode = .cruise`; `state = .cruisePlaying`;
  `haptics.tick(.cruiseOn)`; `startPlayback()` (the existing loop never needed a held thumb).
- `pauseCruise()` — guard `cruisePlaying`; `cancelPlayback()`; `mode = .precisionHeld`;
  `state = .paused`; `haptics.tick(.pause)`.
- `rewind12Words()` / `forward12Words()` — `currentIndex` ± `navigationJumpWords (=12)`,
  clamped to `[0, tokens.count-1]`, empty-safe; haptic tick; then
  `restartPlaybackIfPlaying()` so the landed word gets a full beat (no-op when
  paused/ready, so a flick there never starts playback).
- `pauseForBackground()` now also catches `.cruisePlaying`.
- Removed `replayCurrentSentence`, `skipSentence`, `firstIndex(ofSentence:)`,
  `jump(to:haptic:)` — dead once flicks became fixed jumps. `sentenceIndex` is
  still emitted by the tokenizer (cheap, unblocks future semantic features).

## Rail gesture (`ReadingView.holdGesture`)

- Captures `gestureStartState` on touch-down. From a resting state it
  `startHolding()`s immediately (instant precision read); **mid-cruise it does
  not** — the thumb only steers (speed / flick) or taps to pause.
- Horizontal flick → `rewind12Words()` / `forward12Words()` (one jump per
  out-and-back; re-arms through the deadzone).
- `onEnded`: cruise + never steered → `pauseCruise()` (it was a tap); cruise +
  steered → keep cruising; otherwise `stopHolding()`.
- `didSteer` flag tracks whether speed/flick ever committed, surviving a return
  through the deadzone — so a cruise *steer-then-recenter-then-lift* isn't
  misread as a tap and doesn't falsely pause.

## Haptics (`Haptics.Event`)

Dropped `.replay`/`.skip`; added:

- `.cruiseOn` — two soft `light(0.6)` ticks ~90 ms apart (engaging autopilot
  feels distinct from the single start tick).
- `.rewind` — `medium(0.7)`. `.forward` — `medium(0.5)` (lighter).

Boundaries clamp silently (no modal/error); the jump haptic still fires at the
edges. Kept `.start`, `.pause`, `.bandChange`, `.finish`.

## Verification

- `swift build` + `swift run CoreChecks` pass (the only core change is the
  `ReaderState` case; no tokenizer/pacing behavior changed, so no new assertion).
- **Unverified here:** the iOS app target needs Xcode, and the gesture feel must
  be checked on a real device (spec §"The Simulator Lies") — specifically:
  double-tap reliably enters cruise without firing a stray rail read; single-tap
  reliably pauses; flicks move exactly 12 in all three states; the cruise
  steer-then-lift case doesn't pause.

## Known judgment calls (flag for review)

- **`restartPlaybackIfPlaying()` on flick** isn't in the literal spec bodies, but
  matches the old `jump`'s polish (landed word gets a full beat). Drop it if a
  jump mid-read should instead keep the current sleep.
- **Cruise speed-adjust** works, but the dial stays dim during cruise (active
  styling is still tied to `precisionHeld`). Cheap to extend later if wanted.
- **Renaming `readingHeld → precisionHeld`** was taken from the spec's enum
  verbatim; it's a pure rename (compiler-checked, no behavior change).
