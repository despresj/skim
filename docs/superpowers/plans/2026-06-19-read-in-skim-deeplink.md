# Read in Skim — Deep-Link Input Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users send text or a URL into Skim from iOS Shortcuts via a `skim://read` deep link — text lands armed on the reading surface, a URL lands on a calm fallback card — without a paste prompt or autoplay.

**Architecture:** A pure `DeepLinkParser` in `SkimCore` validates/decodes the URL (fully testable with `CoreChecks`, no Xcode). `ReaderViewModel.handleDeepLink` routes `.text` into the existing `load(_:)` pipeline (arms `.ready`) and `.url` into a new `pendingLink` property. `ContentView` shows a new `LinkFallbackView` when a link is pending; `SkimApp` wires `.onOpenURL` as the single delivery hook. The deep link banks the pasteboard change count so the clipboard re-read can't clobber it.

**Tech Stack:** Swift 6, SwiftUI, UIKit (`UIPasteboard`), XcodeGen (`project.yml` → `Skim.xcodeproj`). Pure core checked by `swift run CoreChecks`; app built with `xcodebuild` via `scripts/deploy-device.sh`.

## Global Constraints

- Swift 6.0; iOS 17+ deployment target; portrait-only. (verbatim from `project.yml`)
- Core stays pure: **no `UIKit`/`SwiftUI`/Foundation-UI** in `Sources/SkimCore`. Plain Foundation (`URL`, `URLComponents`) is allowed.
- Any new pacing/tokenizer/core behavior gets a matching `CoreChecks/main.swift` assertion in the same change.
- App code uses core types directly — **no `import SkimCore`** in `App/` (compiled as one module).
- `Skim.xcodeproj` is generated — **edit `project.yml`, never the pbxproj**; run `xcodegen generate` after.
- `.build/` is committed and noisy in `git status` — stage only the files you touched.
- Length cap: `text` payload capped at 100_000 characters (truncate, never block).
- No autoplay anywhere — text lands in `.ready`, URL never loads the reader.
- Deploy to device only on a clean `xcodebuild` build (`scripts/deploy-device.sh` is build-gated).

---

### Task 1: Pure `DeepLinkParser` in SkimCore (+ CoreChecks)

The testable heart. Fully verifiable on macOS with CLT — no Xcode needed.

**Files:**
- Create: `Sources/SkimCore/DeepLink.swift`
- Modify: `Sources/CoreChecks/main.swift` (append a `DeepLink` check block before the final `if failures.isEmpty` summary at line ~268)

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces:
  - `public enum DeepLink: Equatable { case text(String); case url(String) }`
  - `public enum DeepLinkParser { public static let maxTextLength = 100_000; public static func parse(_ url: URL) -> DeepLink? }`

- [ ] **Step 1: Write the failing tests**

Append this block to `Sources/CoreChecks/main.swift`, immediately before the `print("")` / summary at the end (around line 268):

```swift
print("DeepLink")
do {
    let d = DeepLinkParser.parse(URL(string: "skim://read?text=Hello%20world")!)
    expectEqual(d, .text("Hello world"), "text param decodes to readable words")
}
do {
    let d = DeepLinkParser.parse(URL(string: "skim://read?text=a%20%20b")!)
    expectEqual(d, .text("a  b"), "internal spacing preserved")
}
do {
    let d = DeepLinkParser.parse(URL(string: "skim://read?text=")!)
    expectEqual(d, nil, "empty text -> nil")
}
do {
    let d = DeepLinkParser.parse(URL(string: "skim://read?text=%20%20%20")!)
    expectEqual(d, nil, "whitespace-only text -> nil")
}
do {
    let d = DeepLinkParser.parse(URL(string: "skim://read?url=https%3A%2F%2Fexample.com")!)
    expectEqual(d, .url("https://example.com"), "url param decodes")
}
do {
    let d = DeepLinkParser.parse(URL(string: "skim://read?text=hi&url=https%3A%2F%2Fx.com")!)
    expectEqual(d, .text("hi"), "text wins when both params present")
}
do {
    let d = DeepLinkParser.parse(URL(string: "http://read?text=hi")!)
    expectEqual(d, nil, "wrong scheme -> nil")
}
do {
    let d = DeepLinkParser.parse(URL(string: "skim://other?text=hi")!)
    expectEqual(d, nil, "wrong host -> nil")
}
do {
    let d = DeepLinkParser.parse(URL(string: "skim://read")!)
    expectEqual(d, nil, "no query items -> nil")
}
do {
    let big = String(repeating: "a", count: 120_000)
    let d = DeepLinkParser.parse(URL(string: "skim://read?text=" + big)!)
    if case let .text(s)? = d {
        expectEqual(s.count, 100_000, "over-cap text truncated to maxTextLength")
    } else {
        expect(false, "over-cap text should still parse to .text")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift run CoreChecks`
Expected: FAIL — compile error `cannot find 'DeepLinkParser' in scope` (the type doesn't exist yet).

- [ ] **Step 3: Write the parser**

Create `Sources/SkimCore/DeepLink.swift`:

```swift
import Foundation

/// A validated, decoded `skim://read` deep link. The pure result of parsing an
/// inbound URL — UI-free so it can be exercised by `CoreChecks` without Xcode.
public enum DeepLink: Equatable {
    /// Ready-to-read text payload (already trimmed and length-capped).
    case text(String)
    /// A URL payload. v1 does not extract article text — the app surfaces this
    /// on a calm fallback card rather than reading the raw link.
    case url(String)
}

/// Parses inbound `skim://read?text=…` / `skim://read?url=…` deep links.
///
/// Rules: scheme must be `skim` and host `read`; `text` wins over `url` when
/// both are present; values are trimmed and empty input is rejected (`nil`);
/// `text` is capped at `maxTextLength`. Never throws — malformed input is `nil`.
public enum DeepLinkParser {
    /// Largest `text` payload accepted; longer input is truncated so tokenizing
    /// a pathological paste can't stall the UI.
    public static let maxTextLength = 100_000

    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == "skim",
              url.host?.lowercased() == "read",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return nil
        }

        // `text` is authoritative over `url` when a link carries both.
        if let raw = items.first(where: { $0.name == "text" })?.value {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .text(String(trimmed.prefix(maxTextLength)))
        }
        if let raw = items.first(where: { $0.name == "url" })?.value {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .url(trimmed)
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift build && swift run CoreChecks`
Expected: PASS — the `DeepLink` block prints all `✓` lines and the run ends with `All checks passed ✅` (exit 0).

- [ ] **Step 5: Commit**

```bash
git add Sources/SkimCore/DeepLink.swift Sources/CoreChecks/main.swift
git commit -m "feat: pure DeepLinkParser for skim://read deep links"
```

---

### Task 2: Register the `skim` URL scheme (`project.yml`)

`CFBundleURLTypes` is an array, so move from a generated Info.plist to an XcodeGen-managed one and add the scheme.

**Files:**
- Modify: `project.yml:24-37` (the `Skim` target's `settings.base` block, plus add a sibling `info:` block)
- Generated (do not hand-edit): `App/Info.plist`

**Interfaces:**
- Consumes: nothing.
- Produces: an installed app whose Info.plist registers scheme `skim`, so iOS routes `skim://…` URLs to it.

- [ ] **Step 1: Replace the Info.plist generation settings**

In `project.yml`, under `targets: Skim:`, **add** this `info:` block as a direct child of the target (sibling of `settings:`), and **remove** the four `INFOPLIST_KEY_*` lines plus `GENERATE_INFOPLIST_FILE` from `settings.base` (keep the others: bundle id, app icon name, device family, code sign style, development team).

Add (target-level, indented under `Skim:`):

```yaml
    info:
      path: App/Info.plist
      properties:
        UILaunchScreen: {}
        UIApplicationSupportsIndirectInputEvents: true
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
        UIStatusBarHidden: true
        CFBundleURLTypes:
          - CFBundleURLName: com.despresj.skim
            CFBundleURLSchemes: [skim]
```

After editing, the target's `settings.base` should contain exactly:

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.despresj.skim
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        TARGETED_DEVICE_FAMILY: "1"
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: Z26YTV7798
```

- [ ] **Step 2: Regenerate the project**

Run: `xcodegen generate`
Expected: `Created project at .../Skim.xcodeproj` (no errors). `App/Info.plist` is created.

- [ ] **Step 3: Verify the scheme is registered**

Run: `plutil -p App/Info.plist`
Expected: output includes a `CFBundleURLTypes` array whose entry has `"CFBundleURLSchemes" => [ 0 => "skim" ]`, and the four moved keys (`UILaunchScreen`, `UIApplicationSupportsIndirectInputEvents`, `UISupportedInterfaceOrientations`, `UIStatusBarHidden`) are present.

- [ ] **Step 4: Verify the app still builds**

Run: `xcodebuild -project Skim.xcodeproj -scheme Skim -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add project.yml App/Info.plist Skim.xcodeproj
git commit -m "feat: register skim:// URL scheme via XcodeGen Info.plist"
```

---

### Task 3: Route deep links in `ReaderViewModel`

Add the entry point that turns a parsed link into reader state, and make the link authoritative over the clipboard.

**Files:**
- Modify: `App/ReaderViewModel.swift` — add `pendingLink` property near the other `private(set)` state (around line 51), and add `handleDeepLink`/`dismissLink`/`copyLink` in the `MARK: Loading` section (around line 144).

**Interfaces:**
- Consumes: `DeepLinkParser.parse(_:) -> DeepLink?`, `DeepLink` (Task 1); existing `load(_ text: String)`; existing `lastPasteboardChange`.
- Produces:
  - `private(set) var pendingLink: String?`
  - `func handleDeepLink(_ url: URL)`
  - `func dismissLink()`
  - `func copyLink()`

- [ ] **Step 1: Add the `pendingLink` property**

In `App/ReaderViewModel.swift`, after the `hasPendingClipboard` property block (ends line 51), add:

```swift

    /// A URL delivered by a `skim://read?url=…` deep link, awaiting the user's
    /// choice on the fallback card. v1 doesn't extract article text, so the URL
    /// is parked here (the reader is left untouched) and `ContentView` shows
    /// `LinkFallbackView` while it's set. `nil` when no link is pending.
    private(set) var pendingLink: String?
```

- [ ] **Step 2: Add the deep-link handlers**

In the `// MARK: Loading` section, after `pasteFromClipboard()` (ends line 144), add:

```swift

    /// Route an inbound `skim://read` deep link. Text loads straight into the
    /// reader (armed in `.ready`, no autoplay); a URL is parked on the fallback
    /// card. Invalid/empty links are ignored so they never disturb a current
    /// read or crash. The link is authoritative over the clipboard: we bank the
    /// current pasteboard change count up front so the foreground re-read can't
    /// clobber the link or trigger iOS's paste prompt (resolves the cold-launch
    /// race between `onOpenURL` and `scenePhase == .active`, in either order).
    func handleDeepLink(_ url: URL) {
        lastPasteboardChange = UIPasteboard.general.changeCount
        switch DeepLinkParser.parse(url) {
        case .text(let text):
            pendingLink = nil
            load(text)
        case .url(let link):
            pendingLink = link
        case nil:
            break
        }
    }

    /// The reader dismissed the fallback card without opening the link — drop it
    /// and fall back to whatever was showing before (paste screen if idle).
    func dismissLink() {
        pendingLink = nil
    }

    /// "Copy Link" on the fallback card: put the URL on the pasteboard and
    /// re-bank the change count so the link we just copied doesn't loop back as
    /// readable clipboard text on the next foreground.
    func copyLink() {
        guard let link = pendingLink else { return }
        UIPasteboard.general.string = link
        lastPasteboardChange = UIPasteboard.general.changeCount
    }
```

- [ ] **Step 3: Verify it builds**

Run: `xcodebuild -project Skim.xcodeproj -scheme Skim -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. (No unit harness here — `ReaderViewModel` imports UIKit, so it's out of `CoreChecks`' reach; the parser logic it depends on is already covered by Task 1, and behavior is checked end-to-end in the Task 5 manual acceptance.)

- [ ] **Step 4: Commit**

```bash
git add App/ReaderViewModel.swift
git commit -m "feat: route skim:// deep links through ReaderViewModel"
```

---

### Task 4: `LinkFallbackView` + routing + `onOpenURL` wiring

The calm "Link received" card, plus the two wiring points that make deep links live.

**Files:**
- Create: `App/LinkFallbackView.swift`
- Modify: `App/ContentView.swift:7-17` (route to the card when a link is pending)
- Modify: `App/SkimApp.swift:9-20` (add `.onOpenURL`)

**Interfaces:**
- Consumes: `ReaderViewModel.pendingLink`, `dismissLink()`, `copyLink()`, `handleDeepLink(_:)`, `isLeftHanded` (Task 3); `ReadingCanvas`, `PrimaryPillStyle`, `SecondaryPillStyle`, `Color.reading*` (existing `Theme.swift`).
- Produces: `struct LinkFallbackView: View` (init `LinkFallbackView(viewModel:)`).

- [ ] **Step 1: Create the fallback card**

Create `App/LinkFallbackView.swift`:

```swift
import SwiftUI

/// The calm landing for a `skim://read?url=…` deep link. v1 can't extract
/// article text yet, so rather than pretend — RSVP-ing a raw URL would feel
/// broken — Skim acknowledges the link and offers to open it. This view is the
/// seam where real article extraction drops in later (a "Read it" action).
struct LinkFallbackView: View {
    let viewModel: ReaderViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            ReadingCanvas()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                VStack(spacing: 14) {
                    Text("Link received")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.readingForeground)

                    Text(viewModel.pendingLink ?? "")
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.readingMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(Color.readingSurface,
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.readingBorder, lineWidth: 1)
                        )

                    Text("Article extraction coming soon.")
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.readingMuted)
                }

                Spacer(minLength: 24)
                Spacer(minLength: 24)

                actions
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    /// Thumb-range actions: open the link (primary), copy it (quiet), or back
    /// out to the paste screen. Kept low on the surface, within reach.
    private var actions: some View {
        VStack(spacing: 12) {
            Button("Open Link") {
                if let link = viewModel.pendingLink, let url = URL(string: link) {
                    openURL(url)
                }
                viewModel.dismissLink()
            }
            .buttonStyle(PrimaryPillStyle())

            Button("Copy Link") {
                viewModel.copyLink()
            }
            .buttonStyle(SecondaryPillStyle())

            Button("Not now") {
                viewModel.dismissLink()
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(Color.readingMuted)
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }
}
```

- [ ] **Step 2: Route to the card in `ContentView`**

In `App/ContentView.swift`, replace the `Group { … }` body (lines 8-14) so a pending link wins over the idle/reading split:

```swift
        Group {
            if viewModel.pendingLink != nil {
                LinkFallbackView(viewModel: viewModel)
            } else if viewModel.state == .idle {
                PasteView(viewModel: viewModel)
            } else {
                ReadingView(viewModel: viewModel)
            }
        }
```

- [ ] **Step 3: Wire `onOpenURL` in `SkimApp`**

In `App/SkimApp.swift`, add an `.onOpenURL` handler to the `ContentView` inside `WindowGroup` (after the existing `.task { … }` modifier that ends at line 19):

```swift
                .onOpenURL { url in
                    viewModel.handleDeepLink(url)
                }
```

- [ ] **Step 4: Verify it builds**

Run: `xcodebuild -project Skim.xcodeproj -scheme Skim -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add App/LinkFallbackView.swift App/ContentView.swift App/SkimApp.swift Skim.xcodeproj
git commit -m "feat: LinkFallbackView + onOpenURL routing for deep links"
```

---

### Task 5: Manual acceptance + Shortcuts documentation

Verify on-device behavior the unit harness can't reach, and ship the three Shortcuts so the path is usable.

**Files:**
- Create: `docs/shortcuts.md`

**Interfaces:**
- Consumes: the installed app from Tasks 2–4.
- Produces: documented Shortcuts + a recorded acceptance pass.

- [ ] **Step 1: Deploy to device**

Run: `scripts/deploy-device.sh`
Expected: green build, then install + launch on the iPhone (`com.despresj.skim`). The script is build-gated — it won't touch the phone on a red build.

- [ ] **Step 2: Run the manual acceptance checks**

Trigger each deep link (Safari address bar, Notes tap, or a Shortcut) and confirm:

- `skim://read?text=Hello%20world` (cold launch — app force-quit first) → opens armed on the reading surface showing "Hello", **not** moving until you hold.
- `skim://read?text=Reading%20machine` (app already running) → swaps in the new text, armed in `.ready`.
- `skim://read?text=From%20background` (app backgrounded, not quit) → foregrounds and shows the text; the clipboard re-read does **not** replace it.
- `skim://read?url=https%3A%2F%2Fexample.com` → shows the "Link received" card with the URL; "Open Link" opens Safari; "Copy Link" copies; "Not now" returns to the paste screen; the reader is untouched throughout.
- `skim://read?text=` (empty) → no crash; lands on the paste screen.
- `skim://read?garbage` → no crash; lands on the paste screen.

- [ ] **Step 3: Document the Shortcuts**

Create `docs/shortcuts.md`:

```markdown
# Read in Skim — iOS Shortcuts

Three Shortcuts feed Skim through its `skim://read` deep link. Each ends in an
**Open URLs** action; the encoded payload is built with **URL Encode**.

## 1. Read Clipboard in Skim
1. **Get Clipboard**
2. **URL Encode** (input: Clipboard)
3. **Text**: `skim://read?text=` + [URL Encoded] (use the Text action to concatenate)
4. **Open URLs** (input: the Text from step 3)

## 2. Read URL in Skim
Accepts a URL from the Share Sheet or as Shortcut input.
1. **URL Encode** (input: Shortcut Input)
2. **Text**: `skim://read?url=` + [URL Encoded]
3. **Open URLs** (input: the Text)

## 3. Read Text in Skim
Accepts text as Shortcut input.
1. **URL Encode** (input: Shortcut Input)
2. **Text**: `skim://read?text=` + [URL Encoded]
3. **Open URLs** (input: the Text)

Notes:
- `text` wins if a link carries both `text` and `url`.
- Empty/whitespace input is ignored — Skim opens to its normal entry screen.
- Text over 100k characters is truncated.
```

- [ ] **Step 4: Commit**

```bash
git add docs/shortcuts.md
git commit -m "docs: Read in Skim Shortcuts + acceptance checklist"
```

---

## Self-Review

**Spec coverage:**

- URL scheme registration (`skim`, host `read`, params `text`/`url`) → Task 2 + Task 1 parser.
- Deep-link handling for cold launch / running / foreground → Task 4 (`onOpenURL`, single hook) + Task 5 manual checks.
- Route into existing manual-text path → Task 3 (`handleDeepLink` → `load`).
- Validation: trim, reject empty, 100k cap, non-blocking → Task 1 parser + tests.
- Preserve reading behavior (tokenizer, pacing, hand, UI, no autoplay) → Task 3 reuses `load`; armed `.ready`; Task 4 routing leaves reader paths intact.
- URL fallback card: "Link received" / truncated URL / "Open Link" / "Article extraction coming soon." / "Copy Link" → Task 4 `LinkFallbackView`.
- Deep link authoritative over clipboard (change-count banking) → Task 3.
- Parser CoreChecks (the 10 listed cases) → Task 1 Step 1.
- Lifecycle checks as manual acceptance → Task 5 Step 2.
- Three Shortcuts → Task 5 Step 3.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every command has expected output.

**Type consistency:** `DeepLink`/`DeepLinkParser.parse`/`maxTextLength` defined in Task 1 and consumed verbatim in Tasks 3. `pendingLink`/`handleDeepLink`/`dismissLink`/`copyLink` defined in Task 3 and consumed verbatim in Task 4. `LinkFallbackView(viewModel:)` defined in Task 4 and routed in Task 4 Step 2. `Color.reading*`, `ReadingCanvas`, `PrimaryPillStyle`, `SecondaryPillStyle` are existing `Theme.swift` symbols.
