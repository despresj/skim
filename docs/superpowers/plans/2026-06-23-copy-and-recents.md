# Copy Current Text & Recents Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Copy control to the parked reading surface that copies the full read text with a calm in-place confirmation, and give the Paste/New Text screen a path to the saved-reads shelf (`Recents` when standalone, `‹ Reads` when truly going back).

**Architecture:** Both features live in the app layer. Feature 1 appends a fourth button to the existing top-left utility rail in `ReadingView` and adds a `copyCurrentText()` method + a `.copy` haptic. Feature 2 adds a `ReaderViewModel.openRecents()` that opens the shelf (`ResumeView`) from the most-recent read of any status, and makes `PasteView` show the right pill based on `canReturnToReads` vs. a non-empty library.

**Tech Stack:** Swift 6, SwiftUI, `@Observable` view model, UIKit (`UIPasteboard`, `UIImpactFeedbackGenerator`), SQLite-backed `SkimStore`. iOS 17+, portrait-only.

## Global Constraints

- Core (`Sources/SkimCore`) stays pure — no UIKit/SwiftUI. These features touch only the app layer; **no new `SkimStore` method is needed** (reuse `recentReads(limit:)`), so no `CoreChecks` assertion is required.
- The reading surface is sacred: no chrome while streaming/cruising. The copy button must inherit the existing parked-only gate (`utilityOpacity` / `shouldShowPauseChrome`).
- Any write to `UIPasteboard.general` MUST be followed by `lastPasteboardChange = UIPasteboard.general.changeCount` so the VM does not re-detect its own copy as freshly-pasted text on the next foreground (mirror `copyLink`).
- Confirmation stays local and calm: a soft haptic + a ~1s in-place icon swap. No global toast/banner in v1.
- App code compiles only under Xcode. After app-layer edits, verify with a clean `xcodebuild` build; final acceptance is on-device via `scripts/deploy-device.sh` (build-gated — only lands on a green build). `swift build` only proves `SkimCore` still compiles.
- Keep `‹ Reads` (back navigation) and `Recents` (standalone library access) distinct. `Recents` must never perform back-navigation.
- Edit `project.yml`, never the generated pbxproj. No new files are added here, so `xcodegen generate` is not required.

---

### Task 1: `.copy` haptic + `ReaderViewModel.copyCurrentText()`

**Files:**
- Modify: `App/Haptics.swift` (the `Event` enum and the `tick(_:)` switch)
- Modify: `App/ReaderViewModel.swift` (add `copyCurrentText()`)

**Interfaces:**
- Consumes: `reviewText: String` (existing, the canonical full prose), `haptics` (existing private `Haptics`), `lastPasteboardChange` (existing var the clipboard-watcher compares against).
- Produces: `Haptics.Event.copy`; `ReaderViewModel.copyCurrentText()` — copies `reviewText` to the pasteboard and fires `.copy`. Consumed by Task 2.

- [ ] **Step 1: Add the `.copy` event case**

In `App/Haptics.swift`, add to the `Event` enum (after `case newText`):

```swift
        case copy        // copied the full read text to the clipboard
```

- [ ] **Step 2: Handle `.copy` in `tick(_:)`**

In `App/Haptics.swift`, add a case to the `switch` in `tick(_:)`, alongside `.newText` (which uses `soft`):

```swift
        case .copy:       soft.impactOccurred(intensity: 0.5)
```

- [ ] **Step 3: Add `copyCurrentText()` to the view model**

In `App/ReaderViewModel.swift`, add this method (place it near the other pasteboard helpers such as `copyLink`/`pasteFromClipboard`):

```swift
    /// Copy the full prose of the current read to the system pasteboard, so the
    /// user can grab the text back out while parked. Bumps `lastPasteboardChange`
    /// so the foreground clipboard-watch never mistakes our own write for freshly
    /// copied text. Fires a soft confirmation haptic; the view shows a brief
    /// in-place checkmark. A no-op when there's nothing loaded.
    func copyCurrentText() {
        let text = reviewText
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        lastPasteboardChange = UIPasteboard.general.changeCount
        haptics.tick(.copy)
    }
```

- [ ] **Step 4: Verify the core still compiles**

Run: `swift build`
Expected: builds with no errors (proves `SkimCore`/`CoreChecks` untouched; app-layer types are checked by xcodebuild in Task 2).

- [ ] **Step 5: Commit**

```bash
git add App/Haptics.swift App/ReaderViewModel.swift
git commit -m "feat: add copy-current-text VM method and .copy haptic"
```

---

### Task 2: Copy button in the utility rail

**Files:**
- Modify: `App/ReadingView.swift` (the `utilityRail` VStack ~lines 263-276, the `utilityButton(...)` Image ~lines 290-296, and add a `didCopy` state + `copyText()` helper)

**Interfaces:**
- Consumes: `viewModel.copyCurrentText()` (Task 1), existing `utilityButton(icon:label:tint:action:)`, existing `utilityOpacity` gate.
- Produces: a fourth parked-only rail control; no new public surface.

- [ ] **Step 1: Add copy-confirmation state**

In `App/ReadingView.swift`, add a `@State` near the other view-local state (e.g. beside `showGestureHints`/`yieldToThreadline`):

```swift
    /// Briefly true after a copy, swapping the rail's copy glyph to a checkmark.
    @State private var didCopy = false
```

- [ ] **Step 2: Add the Copy button as the fourth rail control**

In `utilityRail`, inside the `VStack(spacing: 12)`, append after the Ideas button (`utilityButton(icon: "lightbulb", ...)`):

```swift
                    utilityButton(icon: didCopy ? "checkmark" : "doc.on.doc",
                                  label: "Copy text",
                                  tint: .readingMuted, action: copyText)
```

- [ ] **Step 3: Add the `copyText()` helper**

In `App/ReadingView.swift`, near `openExport`/`openIdeas`/`openSettings`:

```swift
    /// Copy the full read text, then flash a brief in-place checkmark on the rail
    /// button (the haptic fires inside the view model). Calm and local — no toast.
    private func copyText() {
        dbg("control tap: copy")
        viewModel.copyCurrentText()
        withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.easeOut(duration: 0.3)) { didCopy = false }
        }
    }
```

- [ ] **Step 4: Give the rail glyph a clean morph on swap**

In `utilityButton(...)`, add a content transition to the `Image` so `doc.on.doc` ↔ `checkmark` morphs rather than hard-cuts. Change the `Image(systemName: icon)` modifier chain to include:

```swift
                .contentTransition(.symbolEffect(.replace))
```

(Add it after the existing `.foregroundStyle(tint)` line. Harmless for the three static buttons; iOS 17+.)

- [ ] **Step 5: Build the app target**

Run: `xcodebuild -project Skim.xcodeproj -scheme Skim -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
Expected: `BUILD SUCCEEDED`. If the scheme/destination differs locally, any clean Xcode build of the app target that compiles `ReadingView.swift` is acceptable.

- [ ] **Step 6: Commit**

```bash
git add App/ReadingView.swift
git commit -m "feat: copy button in reading-surface utility rail"
```

---

### Task 3: `ReaderViewModel.openRecents()`

**Files:**
- Modify: `App/ReaderViewModel.swift` (add `openRecents()` near `returnToReads()`/`dismissResume()` ~lines 954-970)

**Interfaces:**
- Consumes: `store` (existing), `store.recentReads(limit:)` (existing — returns reads of any status, newest first), `pendingResume` (existing `private(set)`), `state` (existing), `canReturnToReads` (existing).
- Produces: `openRecents()` — opens the saved-reads shelf from a standalone paste state. Consumed by Task 4.

- [ ] **Step 1: Add `openRecents()`**

In `App/ReaderViewModel.swift`, add alongside `returnToReads()`:

```swift
    /// Open the saved-reads shelf from a *standalone* New Text state (no back
    /// stack). Leads with the most-recent read regardless of status, so the shelf
    /// opens even when every saved read is finished — distinct from
    /// `returnToReads()`, which is true back navigation to the shelf we came from.
    /// Setting a non-nil `pendingResume` while idle routes `ContentView` to
    /// `ResumeView` (the shelf), which renders finished items correctly and
    /// reopens them at the top via the existing `resume(_:)` path. A no-op when the
    /// library is empty. Creates no records.
    func openRecents() {
        guard let store, let recent = (try? store.recentReads(limit: 1))?.first else { return }
        pendingResume = recent
        canReturnToReads = false
        state = .idle
    }
```

- [ ] **Step 2: Verify the core still compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add App/ReaderViewModel.swift
git commit -m "feat: openRecents() opens the shelf from standalone paste state"
```

---

### Task 4: `Recents` / `‹ Reads` pill on PasteView

**Files:**
- Modify: `App/PasteView.swift` (the `.overlay(alignment: .topLeading)` block ~lines 58-64, the `backToReads` view ~lines 96-113, and add a recents-load on appear)

**Interfaces:**
- Consumes: `viewModel.canReturnToReads` (existing), `viewModel.returnToReads()` (existing), `viewModel.recents` (existing `private(set)` array), `viewModel.refreshRecents()` (existing), `viewModel.openRecents()` (Task 3).
- Produces: no new public surface.

- [ ] **Step 1: Load the library when the paste screen appears**

In `App/PasteView.swift`, so `recents` is populated on a cold launch into PasteView, add an `.onAppear` to the root `ZStack` (place it next to the existing `.sheet`/`.overlay` modifiers, e.g. right after the `.sheet(isPresented: $showingSettings)` block):

```swift
        .onAppear { viewModel.refreshRecents() }
```

- [ ] **Step 2: Make the top-left pill context-dependent**

Replace the existing top-leading overlay:

```swift
        .overlay(alignment: .topLeading) {
            if viewModel.canReturnToReads {
                backToReads
                    .padding(.leading, 16)
                    .padding(.top, 8)
            }
        }
```

with one that shows the back pill when we came from Reads, otherwise a standalone `Recents` pill when the library is non-empty:

```swift
        .overlay(alignment: .topLeading) {
            Group {
                if viewModel.canReturnToReads {
                    backToReads
                } else if !viewModel.recents.isEmpty {
                    recentsPill
                }
            }
            .padding(.leading, 16)
            .padding(.top, 8)
        }
```

- [ ] **Step 3: Add the `recentsPill` view**

In `App/PasteView.swift`, add next to `backToReads`. Same calm capsule family, but a recents glyph (not a back chevron) and the `openRecents()` action — it *opens* the library, it does not go back:

```swift
    /// Standalone access to the saved-reads shelf, shown on a paste screen the user
    /// reached directly (not from Reads) when the library is non-empty. A clock-list
    /// glyph + "Recents" — deliberately not a back chevron, because this opens the
    /// library rather than returning to a shelf we came from.
    private var recentsPill: some View {
        Button { viewModel.openRecents() } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                Text("Recents")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
            }
            .foregroundStyle(Color.readingMuted)
            .padding(.leading, 13)
            .padding(.trailing, 15)
            .frame(height: 40)
            .background(Color.readingSurface.opacity(0.6), in: Capsule())
            .overlay(Capsule().stroke(Color.readingBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open recents")
    }
```

- [ ] **Step 4: Build the app target**

Run: `xcodebuild -project Skim.xcodeproj -scheme Skim -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add App/PasteView.swift
git commit -m "feat: Recents pill opens shelf from standalone New Text; keep back ‹ Reads"
```

---

### Task 5: On-device verification & acceptance

**Files:** none (verification only)

- [ ] **Step 1: Deploy to device on a green build**

Run: `scripts/deploy-device.sh`
Expected: clean build, then install + launch on the iPhone. A failing build exits before touching the phone.

- [ ] **Step 2: Walk the Feature 1 acceptance checks**

- Copy button appears only when parked/pause chrome is visible (Settings · Export · Ideas · **Copy**).
- It is absent during an active thumb hold and during Cruise.
- Tapping it puts the full read text on the pasteboard (paste into Notes/Messages to confirm).
- The glyph briefly shows a checkmark, then returns to `doc.on.doc`.
- A soft haptic fires.
- The existing three rail buttons do not jump.
- Switch away and back: the read does **not** reset to a "new clipboard" because of our own copy (confirms `lastPasteboardChange` guard).

- [ ] **Step 3: Walk the Feature 2 acceptance checks**

- From Reads → New text: the pill reads `‹ Reads` and returns to that shelf.
- Cold launch / standalone into New Text with saved reads: the pill reads `Recents` and opens the shelf.
- `Recents` opens the shelf even when every saved read is finished (test with a library of only completed reads).
- Opening the shelf creates no duplicate records (the recents list count is unchanged).
- Launch behavior is unchanged: app still opens to Welcome Back/Reads when there's something to resume.

- [ ] **Step 4: Final commit (if any acceptance fixes were needed)**

```bash
git add -A
git commit -m "fix: address copy/recents on-device acceptance"
```

---

## Self-Review

**Spec coverage:**
- Feature 1 placement/order/style/gate → Task 2. Icon/label → Task 2. Action + `reviewText` + `copyCurrentText()` → Task 1. Haptic `.copy` + checkmark swap + no toast → Tasks 1-2. Acceptance → Task 5 Step 2. ✓
- Feature 2 `‹ Reads` vs `Recents` distinction → Task 4. `hasAnyReads` (via non-empty `recents`) + open-shelf-when-finished-only + most-recent lead + no-dup + launch unchanged → Tasks 3-4, verified in Task 5 Step 3. ✓
- "No new store method / no CoreChecks needed" justified in Global Constraints (reuse `recentReads`). ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows complete code. ✓

**Type consistency:** `copyCurrentText()`, `openRecents()`, `Haptics.Event.copy`, `didCopy`, `copyText()`, `recentsPill` are named identically wherever referenced across tasks. `recentReads(limit:)` and `refreshRecents()` match existing signatures. ✓

**Note on testing:** This plan uses build gates + on-device acceptance rather than CLI unit tests, because the changed code is app-layer (Xcode-only) and the repo's `CoreChecks` harness covers pure `SkimCore` only — which is untouched here.
