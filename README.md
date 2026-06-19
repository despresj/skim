# Skim

A clipboard-first, one-thumb RSVP reading app for iPhone. Copy text, open the
app, hold your thumb on the right side of the screen — it reads to your eyes.

This repo is the **minimal v1 slice**: clipboard load → tokenize → centered word
display → WPM-paced playback with punctuation rhythm → invisible right-thumb
hold-to-read with haptics. See `rsvp_casual_reader_spec.md` for the full vision
and `~/.claude/plans/` for the build plan.

## Layout

```
Sources/SkimCore/   Pure reading logic (no UIKit/SwiftUI) — tokenizer, pacing, models
Sources/CoreChecks/     Self-check executable that verifies the core (runs without Xcode)
App/                    SwiftUI app shell — view model, views, haptics
Package.swift           SwiftPM manifest for the core + checks
project.yml             xcodegen definition for the iOS app
```

The iOS app target compiles `App/` and `Sources/SkimCore/` together as one
module (so the app code uses the core types directly, no `import`).

## Verify the core (no Xcode needed)

```sh
swift build          # compiles SkimCore under Swift 6
swift run CoreChecks # asserts tokenizer / pacing / speed-band behavior
```

> Note: a normal XCTest/swift-testing target can't build with only the Command
> Line Tools (those test modules ship inside Xcode). `CoreChecks` is the
> dependency-free stand-in; promote it to XCTest once full Xcode is installed.

## Build & run the app (needs Xcode)

```sh
brew install xcodegen   # if not already installed
xcodegen generate       # regenerates Skim.xcodeproj
open Skim.xcodeproj  # then Run on an iPhone simulator or device
```

Try it: copy a paragraph → launch → the first word waits → press and hold the
right ~38% of the screen to read → release to pause → reaching the end gives a
finish haptic and a "Read again" prompt. Empty clipboard shows the paste screen.

## Deploy to a device from the command line (no Xcode GUI / over SSH)

Build and install onto a paired iPhone (USB or network) headlessly:

```sh
./deploy.sh                        # build + install to the connected device
DEVICE="Joe’s iPhone" ./deploy.sh  # or target a device by name
```

`deploy.sh` runs `xcodegen generate`, builds a signed device build with
`xcodebuild -destination 'generic/platform=iOS' -allowProvisioningUpdates`, then
installs the `.app` with `xcrun devicectl device install app`. Code signing uses
the personal team already set in `project.yml` (`DEVELOPMENT_TEAM`,
`CODE_SIGN_STYLE: Automatic`). The raw one-liners, if you'd rather not use the
script:

```sh
xcodegen generate
xcodebuild -project Skim.xcodeproj -scheme Skim -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath .build/ios \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device "Joe’s iPhone" \
  .build/ios/Build/Products/Debug-iphoneos/Skim.app
```

**Over SSH:** code signing needs the login keychain unlocked. If a build fails
with `errSecInternalComponent` / "User interaction is not allowed", unlock it
first in the SSH session:

```sh
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

List paired devices any time with `xcrun devicectl list devices`. The phone must
be paired and within range; network ("wireless") pairing is set up once in
Xcode's Devices window, after which no cable is needed.

## Not in this slice (next passes)

Vertical-slide speed bands, flick-left replay / flick-right skip, pause context,
cruise (double-tap autoplay), first-run overlay, settings, recent sessions,
phrase/dense chunking. Sentence & paragraph indices are already emitted by the
tokenizer so the recovery features drop in cleanly later.
