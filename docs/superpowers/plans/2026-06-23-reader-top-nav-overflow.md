# Reader Top Nav Bar + Overflow Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Reader's left vertical utility rail with a parked-only top bar — `‹ Reads` (top-left navigation) and a `…` overflow menu (top-right tools) — and give the Threadline more room.

**Architecture:** All in `App/ReadingView.swift`. A new `topBar` (with `backToReads` + `overflowMenu`) and a transient `copiedPill` replace `utilityRail` and the centered `editControl` in the body ZStack. `‹ Reads` reuses the existing `viewModel.clearText()` (already routes to the Reads shelf). Tools move into a native SwiftUI `Menu`; Copy confirms via the existing `.copy` haptic plus the pill. `backReserve` drops 64 → 28 since the back chevron no longer sits on the Threadline's edge.

**Tech Stack:** Swift 6, SwiftUI (`Menu`, `Label`), `@Observable` view model. iOS 17+, portrait-only.

## Global Constraints

- App-layer UI only, one file (`App/ReadingView.swift`). `copyCurrentText()` already exists in the view model. No core / `CoreChecks` change.
- Verify with: `xcodebuild -project Skim.xcodeproj -scheme Skim -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`. Final acceptance on-device via `scripts/deploy-device.sh` (build-gated).
- No new files → no `xcodegen generate`.
- Both top controls gate on `viewModel.shouldShowPauseChrome` (parked-only); fixed top-left / top-right (NOT mirrored by reading hand).
- No duplicate controls: the four tools (settings/export/ideas/copy) live only in the overflow menu after this change.
- Reuse existing helpers unchanged: `openSettings()`, `openExport()`, `openIdeas()`, `viewModel.copyCurrentText()`, `showGestureHints`.

---

### Task 1: Swap the utility rail for the top nav bar + overflow menu

**Files:**
- Modify: `App/ReadingView.swift`

**Interfaces:**
- Consumes (existing): `viewModel.clearText()`, `viewModel.shouldShowPauseChrome`, `viewModel.copyCurrentText()`, `openSettings()`, `openExport()`, `openIdeas()`, `showGestureHints`, `dbg(_:)`, theme colors.
- Produces: `topBar`, `backToReads`, `overflowMenu`, `copiedPill` views; `showCopied` state; `showGestureTips()` helper. Removes `utilityRail`, `utilityButton`, `utilityOpacity`, `editControl`, `editVisible`, `didCopy`.

- [ ] **Step 1: Replace the `didCopy` state with `showCopied`**

In `App/ReadingView.swift`, replace:

```swift
    /// Briefly true after a copy, swapping the rail's copy glyph to a checkmark.
    @State private var didCopy = false
```

with:

```swift
    /// Briefly true after a copy from the overflow menu — drives the "Copied" pill.
    @State private var showCopied = false
```

- [ ] **Step 2: Swap the body layers**

In `body`'s root `ZStack`, replace:

```swift
                edgeSpeedRailLayer(size: geo.size)

                editControl

                utilityRail

                newTextChip
```

with:

```swift
                edgeSpeedRailLayer(size: geo.size)

                topBar

                copiedPill

                newTextChip
```

- [ ] **Step 3: Replace the utility rail + its helpers with the top bar views**

Replace this whole block (the two `// MARK:` lines, the doc comment, `utilityRail`, `utilityButton`, and `utilityOpacity` — from `// MARK: Secondary action rail (export + ideas)` through the end of `utilityOpacity`):

```swift
    // MARK: Secondary action rail (export + ideas)

    // MARK: Top-left utility rail (settings · export · ideas)

    /// The utility rail gathers the screen's *tools* in the top-left, so the
    /// bottom-right reading zone (toast, progress, scrubber, thumb rail, context)
    /// stays clean — tools live top-left, reading control lives right/bottom, the
    /// word owns the center. Three soft circular controls on one left x-axis, top →
    /// bottom: Settings, Video export (film, accent — "make a video of this read"),
    /// and Ideas (lightbulb, muted). It tucks just under the status bar, well above
    /// both the active word and the centered rewind chevron. The whole rail fades
    /// together — clear at rest, a quiet whisper while streaming, gone during a thumb
    /// hold — so it never competes with the focal word.
    private var utilityRail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    utilityButton(icon: "gearshape", label: "Settings",
                                  tint: .readingMuted, action: openSettings)
                    utilityButton(icon: "film.fill", label: "Export reading video",
                                  tint: .readingAccent, action: openExport)
                    utilityButton(icon: "lightbulb", label: "Add idea",
                                  tint: .readingMuted, action: openIdeas)
                    utilityButton(icon: didCopy ? "checkmark" : "doc.on.doc",
                                  label: "Copy text",
                                  tint: .readingMuted, action: copyText)
                }
                .padding(.leading, 16)
                Spacer(minLength: 0)
            }
            // Just below the status bar / Dynamic Island.
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .opacity(utilityOpacity)
        .allowsHitTesting(utilityOpacity > 0.2)
        .animation(.easeOut(duration: 0.22), value: utilityOpacity)
    }

    /// One floating circular control in the utility rail — shared size and style so
    /// the three tools read as a set. 44pt meets the touch-target minimum.
    private func utilityButton(icon: String, label: String, tint: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .background(Color.readingSurface.opacity(0.6), in: Circle())
                .overlay(Circle().stroke(Color.readingBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// How present the utility rail is. Full while parked (ready/paused) — these are
    /// setup/inspection tools and they belong to the parked surface. Gone entirely
    /// while actively reading (a thumb hold *or* cruise) and on idle/completed:
    /// active reading is for reading, not configuration, and visible tools there
    /// would blur whether the reader is parked or driving.
    private var utilityOpacity: Double {
        viewModel.shouldShowPauseChrome ? 1 : 0
    }
```

with:

```swift
    // MARK: Top navigation bar (‹ Reads · overflow menu)

    /// The Reader's top chrome: navigation at the top-left (`‹ Reads`), tools tucked
    /// into a top-right overflow menu. Fixed corners — not mirrored by reading hand,
    /// because this is app navigation and it rides above the Threadline band. Fades
    /// on the shared pause-chrome gate: present while parked, gone during hold-to-read
    /// and Cruise, so the active word is never crowded.
    private var topBar: some View {
        HStack(spacing: 0) {
            backToReads
            Spacer(minLength: 0)
            overflowMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(viewModel.shouldShowPauseChrome ? 1 : 0)
        .allowsHitTesting(viewModel.shouldShowPauseChrome)
        .animation(.easeOut(duration: 0.22), value: viewModel.shouldShowPauseChrome)
    }

    /// App navigation back to the Reads/Recents shelf. `clearText()` saves progress
    /// (the read stays resumable) and re-offers the resume candidate, so this lands
    /// on the shelf — navigation, not a reading control.
    private var backToReads: some View {
        Button {
            dbg("nav tap: reads")
            viewModel.clearText()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                Text("Reads")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
            }
            .foregroundStyle(Color.readingMuted)
            .padding(.leading, 11)
            .padding(.trailing, 15)
            .frame(height: 40)
            .background(Color.readingSurface.opacity(0.7), in: Capsule())
            .overlay(Capsule().stroke(Color.readingBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to Reads")
    }

    /// Tools, tucked behind a single `…` so they never sit on the reading surface.
    /// Native menu styling; each item carries its icon. Settings/Export/Ideas reuse
    /// the existing helpers (cruise pause-on-open etc. unchanged); Copy copies the
    /// full read with a haptic + the "Copied" pill; Gesture tips re-shows the hints.
    private var overflowMenu: some View {
        Menu {
            Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
            Button { openExport() } label: { Label("Export video", systemImage: "film.fill") }
            Button { openIdeas() } label: { Label("Add idea", systemImage: "lightbulb") }
            Button { copyText() } label: { Label("Copy text", systemImage: "doc.on.doc") }
            Button { showGestureTips() } label: { Label("Gesture tips", systemImage: "questionmark.circle") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.readingMuted)
                .frame(width: 44, height: 44)
                .background(Color.readingSurface.opacity(0.7), in: Circle())
                .overlay(Circle().stroke(Color.readingBorder, lineWidth: 1))
        }
        .accessibilityLabel("More")
    }

    /// A brief, calm "Copied" confirmation — the same translucent pill family as the
    /// flick flash, centered so it clears the high active word. Never hit-testable.
    @ViewBuilder
    private var copiedPill: some View {
        if showCopied {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                Text("Copied")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Color.readingForeground)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.readingSurface.opacity(0.92), in: Capsule())
            .overlay(Capsule().stroke(Color.readingBorder, lineWidth: 1))
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
```

- [ ] **Step 4: Retarget `copyText()` and add `showGestureTips()`**

Replace:

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

with:

```swift
    /// Copy the full read text from the overflow menu: the haptic fires in the view
    /// model; this flashes the brief centered "Copied" pill (the menu has already
    /// closed, so confirmation lives on the surface, not a button).
    private func copyText() {
        dbg("menu tap: copy")
        viewModel.copyCurrentText()
        withAnimation(.easeOut(duration: 0.2)) { showCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.easeOut(duration: 0.35)) { showCopied = false }
        }
    }

    /// Re-show the one-time gesture coaching on demand from the menu.
    private func showGestureTips() {
        dbg("menu tap: gesture tips")
        withAnimation(.easeOut(duration: 0.22)) { showGestureHints = true }
    }
```

- [ ] **Step 5: Remove the centered back chevron (`editControl` + `editVisible`)**

Delete this whole block:

```swift
    // MARK: Back-to-new-text (revealed only when not actively reading)

    /// A quiet back chevron pinned to the edge *opposite* the thumb rail and
    /// vertically centered, mirroring the control. Tapping it drops the loaded
    /// text and returns to the calm empty state, ready to pick up whatever you
    /// copy next — Skim is clipboard-first, so "back" means "read something
    /// else," not "edit this." Hidden the instant a hold begins, so the surface
    /// stays sacred.
    private var editControl: some View {
        HStack {
            if leftHanded { Spacer() }
            Button {
                dbg("control tap: back")
                viewModel.clearText()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.readingMuted)
                    .frame(width: 44, height: 44)
                    .background(Color.readingSurface.opacity(0.7), in: Circle())
                    .overlay(Circle().stroke(Color.readingBorder, lineWidth: 1))
            }
            .padding(leftHanded ? .trailing : .leading, 16)
            if !leftHanded { Spacer() }
        }
        .opacity(editVisible ? 1 : 0)
        .allowsHitTesting(editVisible)
        .animation(.easeOut(duration: 0.22), value: editVisible)
    }

    /// Visible whenever the reader is parked (ready or paused) — the safe state to
    /// leave, restart, or read something else. Gone the instant a hold or cruise
    /// begins, so active reading has one dominant action (pause), never "navigate
    /// away." The paused Threadline routes its text around this button (it is one of
    /// the Threadline's exclusion zones), so the two never collide.
    private var editVisible: Bool {
        viewModel.shouldShowPauseChrome
    }
```

- [ ] **Step 6: Reduce `backReserve` 64 → 28**

Replace:

```swift
    /// Column reserve clearing the back button on the far edge, so the paused prose
    /// is a clean rectangle that never collides with it — no text wrapping needed.
    private var backReserve: CGFloat { 64 }
```

with:

```swift
    /// Margin on the edge opposite the speed control. The back chevron that used to
    /// sit here has moved to the top bar, so this is now just a calm text margin
    /// (matching `ContextStrip`'s 28) and the paused Threadline reclaims the strip.
    private var backReserve: CGFloat { 28 }
```

- [ ] **Step 7: Build the app target**

Run: `xcodebuild -project Skim.xcodeproj -scheme Skim -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`. If it fails on a leftover reference, search for `utilityRail`, `utilityButton`, `utilityOpacity`, `editControl`, `editVisible`, or `didCopy` and remove the stragglers.

- [ ] **Step 8: Commit**

```bash
git add App/ReadingView.swift
git commit -m "feat: reader top nav bar + overflow menu; remove left utility rail"
```

---

### Task 2: On-device verification & acceptance

**Files:** none (verification only)

- [ ] **Step 1: Deploy on a green build**

Run: `scripts/deploy-device.sh`
Expected: clean build, then install + launch on the iPhone.

- [ ] **Step 2: Walk the acceptance criteria**

- Pause a read: `‹ Reads` shows top-left, `…` shows top-right; the left vertical rail is gone.
- Tap `‹ Reads` → lands on the Reads/Recents shelf with the read resumable at top.
- Open `…`: Settings, Export video, Add idea, Copy text, Gesture tips — each with its icon.
- Settings / Export / Add idea open their existing sheets; cruise pauses on open and resumes on close where it did before.
- Copy text: full read lands on the pasteboard (paste into Notes), the soft haptic fires, and the centered "Copied" pill flashes ~1s then fades.
- Gesture tips: the hints overlay re-appears and dismisses normally.
- Start hold-to-read and Cruise: the top bar (both `‹ Reads` and `…`) fades out; the active word is uncrowded. Pause → it returns.
- Threadline visibly has more room on the back-button edge (28 vs 64 margin); no tool buttons overlap the prose.
- Toggle reading hand: the top bar stays top-left / top-right (fixed); the Threadline + edge slider mirror as before.
- Repeat on a small phone (iPhone SE) and a large one (Pro Max): the top bar fits under the status bar / Dynamic Island with no clipping.

- [ ] **Step 3: Commit any tuning**

```bash
git add App/ReadingView.swift
git commit -m "fix: tune reader top bar from on-device pass"
```

---

## Self-Review

**Spec coverage:**
- `‹ Reads` top-left + `…` top-right, parked-only, fixed corners → Task 1 Steps 2-3 (`topBar`, `backToReads`, `overflowMenu`). ✓
- `clearText()` routes to the shelf (no new nav) → `backToReads` action; verified Task 2 Step 2. ✓
- Menu items Settings/Export/Ideas/Copy/Gesture tips with icons, reusing helpers → Step 3 + Step 4. ✓
- Copy = full read + haptic + "Copied" pill → Step 3 (`copiedPill`) + Step 4 (`copyText`). ✓
- Remove rail/utilityButton/utilityOpacity/editControl/editVisible/didCopy, no duplicates → Steps 1,3,5. ✓
- More breathing room (`backReserve` 64→28) → Step 6. ✓
- Active word hero / no overlap / fade on active+cruise / small+large → `shouldShowPauseChrome` gate + top placement; verified Task 2 Step 2. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete before/after code. ✓

**Type consistency:** `topBar`/`backToReads`/`overflowMenu`/`copiedPill`/`showCopied`/`showGestureTips()`/`copyText()` are defined and referenced consistently. Removed symbols (`utilityRail`, `utilityButton`, `utilityOpacity`, `editControl`, `editVisible`, `didCopy`) are deleted at both definition and the body call site (Step 2). `clearText()`, `shouldShowPauseChrome`, `copyCurrentText()`, `showGestureHints`, `backReserve` match existing signatures. ✓

**Note on testing:** Build gate + on-device acceptance — app-layer (Xcode-only) change; `CoreChecks` covers pure `SkimCore`, untouched here.
