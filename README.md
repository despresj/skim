# SpeedReader

SpeedReader is a simple macOS speed-reading app: paste text (or open a `.txt` file) and play it back word-by-word at your chosen WPM.

## Install (Homebrew)

1. Create a GitHub release and upload `SpeedReader.zip` (see “Release” below).
2. Install the cask:

   `brew install --cask https://raw.githubusercontent.com/despresj/speed-reader/main/Casks/speed-reader.rb`

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

Upload `dist/SpeedReader.zip` to your GitHub release. The Homebrew cask downloads from `releases/latest/download/SpeedReader.zip`.
