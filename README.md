# FlowRead

A clipboard-first, one-thumb RSVP reading app for iPhone. Copy text, open the
app, hold your thumb on the right side of the screen — it reads to your eyes.

This repo is the **minimal v1 slice**: clipboard load → tokenize → centered word
display → WPM-paced playback with punctuation rhythm → invisible right-thumb
hold-to-read with haptics. See `rsvp_casual_reader_spec.md` for the full vision
and `~/.claude/plans/` for the build plan.

## Layout

```
Sources/FlowReadCore/   Pure reading logic (no UIKit/SwiftUI) — tokenizer, pacing, models
Sources/CoreChecks/     Self-check executable that verifies the core (runs without Xcode)
App/                    SwiftUI app shell — view model, views, haptics
Package.swift           SwiftPM manifest for the core + checks
project.yml             xcodegen definition for the iOS app
```

The iOS app target compiles `App/` and `Sources/FlowReadCore/` together as one
module (so the app code uses the core types directly, no `import`).

## Verify the core (no Xcode needed)

```sh
swift build          # compiles FlowReadCore under Swift 6
swift run CoreChecks # asserts tokenizer / pacing / speed-band behavior
```

> Note: a normal XCTest/swift-testing target can't build with only the Command
> Line Tools (those test modules ship inside Xcode). `CoreChecks` is the
> dependency-free stand-in; promote it to XCTest once full Xcode is installed.

## Build & run the app (needs Xcode)

```sh
brew install xcodegen   # if not already installed
xcodegen generate       # regenerates FlowRead.xcodeproj
open FlowRead.xcodeproj  # then Run on an iPhone simulator or device
```

Try it: copy a paragraph → launch → the first word waits → press and hold the
right ~38% of the screen to read → release to pause → reaching the end gives a
finish haptic and a "Read again" prompt. Empty clipboard shows the paste screen.

## Not in this slice (next passes)

Vertical-slide speed bands, flick-left replay / flick-right skip, pause context,
cruise (double-tap autoplay), first-run overlay, settings, recent sessions,
phrase/dense chunking. Sentence & paragraph indices are already emitted by the
tokenizer so the recovery features drop in cleanly later.
