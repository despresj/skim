# SpeedReader

SpeedReader is a simple macOS speed-reading app: paste text (or open a `.txt` file) and play it back word-by-word at your chosen WPM.

## Install (Homebrew)

`brew install --cask despresj/speed-reader/speed-reader`

If Homebrew doesn’t auto-tap, run:

`brew tap despresj/speed-reader`

If you haven’t codesigned/notarized the app yet, you may need `--no-quarantine` or to remove the quarantine attribute after install.

## Build

Requirements:

- macOS 14+
- Xcode 15+
- Rust (stable)
- `xcodegen` (`brew install xcodegen`)

Build and run:

`make run`

## Configuration

Copy `config.example.toml` to:

`~/Library/Application Support/SpeedReader/config.toml`

## Release

Build the release zip:

`make dist`

Upload `dist/SpeedReader.zip` to your GitHub release (tag `vX.Y.Z`), then bump the Homebrew cask in the tap repo (`despresj/homebrew-speed-reader`) to the matching `version` + `sha256`.
