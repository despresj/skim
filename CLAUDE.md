# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Skim** (repo dir: `skim`) is a clipboard-first, one-thumb RSVP reading app for iPhone. Copy text → open app → hold thumb on the right edge → words stream by at a WPM-paced rhythm. This repo is the **minimal v1 slice**. The full product vision lives in `rsvp_casual_reader_spec.md` — read it before adding any reading/gesture/pacing feature; it defines the intended UX (semantic replay, cruise mode, pause context, speed bands) and the build order.

Guiding principle from the spec: this is a *calm casual flow-reading instrument*, not a speed-reading app. The reading surface is "sacred" — no buttons/toolbars/sliders during reading; controls are physical gestures confirmed by subtle haptics.

## Build & test

The codebase is split so the **pure reading logic builds and is verified on macOS without Xcode** (Command Line Tools only):

```sh
swift build          # compiles SkimCore under Swift 6
swift run CoreChecks # runs the core's assertion suite; exits non-zero on failure
```

`CoreChecks` (`Sources/CoreChecks/main.swift`) is a hand-rolled, dependency-free test harness — XCTest/swift-testing swiftmodules don't ship with the CLT, so a normal test target can't build here. **Add new core tests by appending `expect`/`expectEqual` blocks to `main.swift`.** Promote to real XCTest only once full Xcode is assumed.

The iOS app needs Xcode:

```sh
brew install xcodegen    # if needed
xcodegen generate        # regenerate Skim.xcodeproj from project.yml
open Skim.xcodeproj   # run on simulator/device
```

`Skim.xcodeproj` is generated from `project.yml` — **edit `project.yml`, not the pbxproj.** Targets iOS 17+, Swift 6, portrait-only.

Dev shortcut: set the `SKIM_SAMPLE` env var (Xcode scheme) to preload sample text instead of the clipboard (see `App/SkimApp.swift`).

### Deploy to device

Joe runs this on a physical **iPhone** (UDID `00008140-001C28661142801C`, bundle `com.despresj.skim`). After making app changes, **reload them onto the device — but only once you're confident the change is good** (clean `xcodebuild` build, not mid-refactor/broken):

```sh
scripts/deploy-device.sh   # builds for the device, then installs + launches ONLY on a green build
```

The script is build-gated: a failing build exits before anything touches the phone, so broken code never lands on the device. Don't deploy while the tree doesn't compile.

## Architecture

Two layers, deliberately separated so the core stays UIKit/SwiftUI-free and testable:

**`Sources/SkimCore/`** — pure reading logic, no UI imports:
- `Tokenizer` — splits raw text into `[ReadingToken]` (word mode). Assigns each token a `delayMultiplier` for rhythm (clause 1.4×, sentence 2.0×, paragraph 2.8×, long word 1.15×; the *larger* wins) plus `sentenceIndex`/`paragraphIndex`. **Those indices are unused by v1 but emitted now so semantic replay/skip drop in cleanly later** — keep populating them.
- `Pacing` — `secondsPerToken(wpm:multiplier:)` = `60/wpm * multiplier`.
- `SpeedBand` — discrete WPM enum (slow 225 → blast 650) with `faster()`/`slower()` stepping. User feels "faster/slower", never a number.
- `ReadingToken`, `ReaderState` (idle/ready/readingHeld/paused/completed), `ReadingMode`.

**`App/`** — SwiftUI shell. Compiled *together with* `Sources/SkimCore` as one module in the app target (see `project.yml`), so app code uses core types directly with **no `import SkimCore`**.
- `ReaderViewModel` — the only stateful object (`@MainActor @Observable`). Owns clipboard loading, tokenization, the playback loop (a cancellable `Task` that sleeps per `Pacing` then advances `currentIndex`), the state machine, and haptic triggers. **All reading state flows through here; views are otherwise stateless and forward gesture intent (`startHolding`/`stopHolding`/`setBandIndex`).**
- `ReadingView` — the sacred surface: centered word, bottom progress line, invisible right-edge thumb rail (hold = read, vertical slide = change band).
- `ContentView` routes idle→`PasteView`, else→`ReadingView`. `PasteView` is the calm empty/manual-paste state. `Theme.swift` holds the system-aware palette + button styles. `Haptics` maps reader events to `UIImpactFeedbackGenerator`.

Clipboard is re-read on every foreground (`scenePhase == .active`), but `ReaderViewModel.loadedText` guards against reloading identical text so switching away and back never resets your place.

## Conventions

- Core stays pure: no `UIKit`/`SwiftUI`/`Foundation`-UI in `Sources/SkimCore`. If logic can live in the core and be checked by `CoreChecks`, put it there.
- When adding pacing/tokenizer behavior, add a matching assertion to `CoreChecks/main.swift` in the same change.
- The `.build/` directory is committed to this repo (no `.gitignore`), so `git status` is noisy with build artifacts — ignore those entries; they're not your changes unless you touched source.
