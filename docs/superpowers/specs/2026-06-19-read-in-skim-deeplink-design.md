# Design: "Read in Skim" deep-link input path

**Status:** approved (brainstorm), ready for implementation plan
**Date:** 2026-06-19

## Purpose

Give Skim a fast v1 input path so users can send text or a URL into the app from
iOS Shortcuts (or any deep link) and land directly on the reading surface — no
paste prompt, no form. This is **not** the full Share Extension; it's the
lighter, testable-today routing path that the Share Extension will later reuse.

Guiding intent: text deep links should feel _magical_ (your words are already in
the machine, waiting under your thumb); URL deep links should feel _gracefully
handled_ without pretending Skim can extract article text yet.

## Scope

In scope:

- Custom URL scheme `skim://read?text=…` and `skim://read?url=…`.
- Routing parsed input into the existing reader pipeline (`ReaderViewModel.load`).
- A calm fallback card for URL input.
- Parser unit checks in `CoreChecks`; lifecycle checks documented as manual.
- Three ready-to-run iOS Shortcuts.

Explicit non-goals for this pass: full Share Extension, article readability
extraction, PDF import, queue/history, accounts, cloud sync.

## Decisions (resolved during brainstorm)

- **Text auto-start:** deep-linked text lands **armed in `.ready`** — first word
  shown, **no auto-play**. The user starts reading with their thumb, preserving
  the "physical gesture starts reading" principle of the sacred surface. ("Start
  reading immediately" means _land on the reading surface, armed_ — not autoplay.)
- **URL handling:** `?url=` lands on a calm fallback card and **does not load the
  reader**. No autoplay, no RSVP-ing the raw URL string (technically honest but
  product-broken — a user who taps a URL expects article text, not the literal
  link). The card offers "Open Link" externally instead, with a "coming soon"
  note for extraction.
- **Text wins over url** when a link carries both params.
- **Length cap:** 100k characters for v1; longer input is truncated, never blocks.
- **Deep link is authoritative** over the clipboard: handling a link banks the
  pasteboard change count so the foreground clipboard re-read can't clobber it
  or trigger the iOS paste prompt.

## Architecture

Two layers, per the existing split — pure parsing in `SkimCore`, routing and UI
in `App/`.

### 1. URL scheme registration (`project.yml`)

`CFBundleURLTypes` is an array and can't be expressed as a scalar
`INFOPLIST_KEY_*`, so the Skim target moves from a fully-generated Info.plist to
an XcodeGen-managed one:

- Add an `info:` block at `path: App/Info.plist`.
- Move the four existing generated keys into `properties:`:
  - `UILaunchScreen: {}` (replaces `INFOPLIST_KEY_UILaunchScreen_Generation`)
  - `UIApplicationSupportsIndirectInputEvents: true`
  - `UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]`
  - `UIStatusBarHidden: true`
- Add:
  ```yaml
  CFBundleURLTypes:
    - CFBundleURLName: com.despresj.skim
      CFBundleURLSchemes: [skim]
  ```
- Remove `GENERATE_INFOPLIST_FILE` and the corresponding `INFOPLIST_KEY_*`
  settings (they conflict with `INFOPLIST_FILE`).
- Regenerate with `xcodegen generate`. `App/Info.plist` is XcodeGen-managed —
  edit `project.yml`, not the plist or pbxproj.

### 2. Pure parser — `Sources/SkimCore/DeepLink.swift`

The testable heart, no UI imports (plain Foundation `URLComponents` only):

```swift
public enum DeepLink: Equatable {
    case text(String)
    case url(String)
}

public enum DeepLinkParser {
    /// Max characters of `text` payload accepted; longer is truncated.
    public static let maxTextLength = 100_000
    public static func parse(_ url: URL) -> DeepLink?
}
```

Rules:

- Scheme must equal `skim` (case-insensitive); host must equal `read`. Otherwise
  `nil`.
- Read query items. If a `text` item exists, it **wins** over `url`.
- Trim leading/trailing whitespace on the chosen value. **Empty → `nil`.**
  (Internal spacing is preserved; the tokenizer collapses runs anyway.)
- For `text`, truncate to `maxTextLength` characters.
- Malformed URL / undecodable components → `nil`. Never throws, never crashes.

Returns `.text(trimmed)` or `.url(trimmed)` or `nil`.

### 3. `ReaderViewModel.handleDeepLink(_:)` (App layer)

Single entry the app calls from `.onOpenURL`:

- `.text(t)` → `load(t)` — tokenizes and arms `.ready` via the existing path.
- `.url(u)` → set new `private(set) var pendingLink: String?` to `u`. Does **not**
  touch tokens/state, so any in-progress read is left intact behind the card.
- `nil` → no-op: don't disturb an existing read; an empty/invalid link with
  nothing loaded simply stays on the paste screen.

**Clipboard authority:** at the start of `handleDeepLink`, bank
`lastPasteboardChange = UIPasteboard.general.changeCount`. This makes the link
authoritative over the foreground clipboard re-read and suppresses the iOS paste
prompt, resolving the cold-launch race between `.onOpenURL` and
`scenePhase == .active` (either order is then safe).

### 4. `LinkFallbackView` (new, App layer)

Calm card shown when `pendingLink != nil`. Reuses `ReadingCanvas`, the palette,
and the existing pill button styles; mirrors handedness like the rest of the app.

- **Title:** "Link received"
- **Body:** the URL in a calm, truncated display (`readingMuted`, `.middle`
  truncation, monospaced-ish or rounded to taste; single line).
- **Primary thumb-range action** (`PrimaryPillStyle`, bottom, hand-mirrored):
  **"Open Link"** — opens the URL externally (`@Environment(\.openURL)` /
  Safari). Clears `pendingLink` afterward and returns to the prior state
  (paste screen if nothing was loaded).
- **Secondary muted copy:** "Article extraction coming soon."
- **Optional secondary action** (`SecondaryPillStyle` or quiet link):
  **"Copy Link"** — writes the URL to the pasteboard. Re-banks
  `lastPasteboardChange` so the copied link doesn't loop back as readable
  clipboard text on the next foreground.
- A quiet back-out (e.g. tap-away / "Done") that clears `pendingLink` to the
  paste screen.

No "Read it" button — it returns only once real extraction exists. This view is
the seam where article extraction drops in later.

### 5. Wiring

- `ContentView`: show `LinkFallbackView` when `viewModel.pendingLink != nil`;
  otherwise the existing routing (`.idle` → `PasteView`, else → `ReadingView`).
- `SkimApp`: add `.onOpenURL { viewModel.handleDeepLink($0) }` to the
  `WindowGroup` content — one hook covering cold launch, already-running, and
  foreground-from-URL (iOS delivers all three through `onOpenURL`).

## Data flow

```
skim://read?text=Hello%20world
  → onOpenURL → handleDeepLink → DeepLinkParser.parse → .text("Hello world")
  → load("Hello world") → tokens armed, state .ready
  → ReadingView shows first word, waits for thumb

skim://read?url=https%3A%2F%2Fexample.com
  → onOpenURL → handleDeepLink → DeepLinkParser.parse → .url("https://example.com")
  → pendingLink set → ContentView shows LinkFallbackView
  → "Open Link" opens Safari; "Copy Link" copies; back-out → paste screen

skim://read?text=            (empty)
  → parse → nil → no-op → paste screen (if nothing loaded)

malformed / wrong scheme / wrong host
  → parse → nil → no-op, no crash
```

## Error handling

- Empty or whitespace-only payload → `nil` → quiet fallback (paste screen),
  no error UI needed.
- Malformed encoding / non-`skim` scheme / wrong host → `nil`, no crash.
- Oversized text → truncated to 100k chars, tokenization stays responsive.
- A link arriving mid-read: text replaces the session (explicit user intent via
  the shortcut); url raises the card over the existing read without discarding it.

## Testing

### Parser checks (`Sources/CoreChecks/main.swift`, appended)

- `skim://read?text=Hello%20world` → `.text("Hello world")`
- internal spacing preserved (e.g. `text=a%20%20b` keeps the gap the tokenizer sees)
- `skim://read?text=` (empty) → `nil`
- whitespace-only text → `nil`
- `skim://read?url=https%3A%2F%2Fexample.com` → `.url("https://example.com")`
- both params present → `.text(...)` wins
- wrong scheme (`http://read?text=hi`) → `nil`
- wrong host (`skim://other?text=hi`) → `nil`
- no query items → `nil`
- over-cap text (> 100k chars) → `.text` truncated to 100k

### Manual acceptance (require Xcode / device — integration-level)

- Deep link on **cold launch** opens reader armed with the text.
- Deep link while **already running** swaps in the text.
- Deep link while **backgrounded** foregrounds and routes correctly, with the
  clipboard re-read not clobbering it (change-count banking).
- `?url=` shows the card; "Open Link" opens Safari; no crash; reader untouched.

### Shortcuts to ship/document

1. **Read Clipboard in Skim** — Get Clipboard → URL Encode → Open URL
   `skim://read?text=[encoded clipboard]`.
2. **Read URL in Skim** — accept URL from Share Sheet/input → URL Encode →
   Open URL `skim://read?url=[encoded url]`.
3. **Read Text in Skim** — accept text input → URL Encode → Open URL
   `skim://read?text=[encoded text]`.

## Acceptance criteria

- "Read Clipboard in Skim" opens Skim with the clipboard text armed on the
  reading surface.
- A `?text=` deep link routes text into the reader, armed in `.ready`.
- A `?url=` deep link shows the calm "Link received" card with "Open Link".
- Empty/broken input never crashes; it falls back quietly to the paste screen.
- Existing app design and reader flow remain intact (no autoplay introduced).
```
