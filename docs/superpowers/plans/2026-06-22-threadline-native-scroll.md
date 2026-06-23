# Premium Native-Scroll Paused Threadline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the paused Threadline a native, momentum-scrolling inspection surface where dragging scrolls, a still press-and-hold reads, double-tap cruises, and an amber locator returns you to the active word.

**Architecture:** The paused Threadline becomes a *front interactive layer* whose `UITextView` is natively scrollable (`UIScrollView` physics → momentum/bounce). All band gestures are owned in UIKit: the scroll view's pan scrolls; a `UILongPressGestureRecognizer` starts reading; a double-tap `UITapGestureRecognizer` toggles Cruise. The global SwiftUI surface gesture yields for touches that begin in the band. Highlight (token→range via `proseMap`) is decoupled from scroll: highlight follows `activeIndex`; recentering happens only on a discrete `contextRecenterTick` bump and lands the active word slightly above center.

**Tech Stack:** Swift 6, SwiftUI + UIKit (`UIViewRepresentable` over `UITextView`/TextKit 1), iOS 17+. App target compiles `App/` and `Sources/SkimCore/` as one module (no `import SkimCore`).

## Global Constraints

- Core stays pure: no `UIKit`/`SwiftUI` in `Sources/SkimCore`. All work here is in `App/` (UI layer) and is verified by **building**, not by the CLT `CoreChecks` harness (which cannot build UIKit views).
- Targets iOS 17+, Swift 6, portrait-only. Bundle `com.despresj.skim`, device UDID `00008140-001C28661142801C`.
- Build gate (must be green before any device install): `xcodebuild -project Skim.xcodeproj -scheme Skim -destination 'generic/platform=iOS' -configuration Debug build` → ends with `** BUILD SUCCEEDED **`.
- Device install (only on a green build): `scripts/deploy-device.sh` (build-gated; installs + launches).
- Do not change `SpeedBand`, WPM values, pacing, the gauge, the scrubber, or the `.ready` `ContextStrip`.
- Tunable constants (tune on device, do not hard-block on first values): `minHoldToRead` ≈ `0.12`s, long-press `allowableMovement` ≈ `10`pt, recenter bias `0.40` (active word 40% down from the viewport top), off-center comfort band `0.20…0.60`.

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `App/ReaderViewModel.swift` | Reader state machine + recenter ticks | Add `recenterContext()`; bump recenter on paused rewind/forward flicks. |
| `App/Threadline.swift` | Paused context surface (SwiftUI wrapper + `UIViewRepresentable` text view) | Full rewrite: native scroll, UIKit gesture recognizers, callbacks, recenter-above-center, off-center detection, amber locator. Remove `ThreadlineScroller`. |
| `App/ReadingView.swift` | Reading screen layout + global gesture layer | Host paused Threadline as a front interactive layer; yield the surface gesture for band-origin presses; delete the dead custom drag-offset scroll path; keep the layer mounted during a band-initiated hold. |

---

## Task 1: Recenter triggers in the view model

**Files:**
- Modify: `App/ReaderViewModel.swift` (`rewind12Words` ~580, `forward12Words` ~591, new method near `bumpRecenter` ~21)

**Interfaces:**
- Consumes: existing `private func bumpRecenter()`, `private(set) var contextRecenterTick`, `var state`, `enum ReaderState` (`.paused`).
- Produces: `func recenterContext()` — public-to-module; bumps `contextRecenterTick` only while paused. Paused flicks now bump the tick.

- [ ] **Step 1: Add `recenterContext()`**

In `App/ReaderViewModel.swift`, immediately after `private func bumpRecenter() { contextRecenterTick += 1 }` (line ~21), add:

```swift
    /// The reader asked to re-center the paused context on the active word (tapped
    /// the "back to word" locator). Only meaningful while paused — the context is
    /// hidden otherwise. Drives `contextRecenterTick`, the one recenter signal.
    func recenterContext() {
        guard state == .paused else { return }
        bumpRecenter()
    }
```

- [ ] **Step 2: Recenter on a paused rewind flick**

In `rewind12Words()`, after `restartPlaybackIfPlaying()` (line ~587), add:

```swift
        if state == .paused { bumpRecenter() }
```

- [ ] **Step 3: Recenter on a paused forward flick**

In `forward12Words()`, after `restartPlaybackIfPlaying()` (line ~598), add:

```swift
        if state == .paused { bumpRecenter() }
```

- [ ] **Step 4: Build gate**

Run: `xcodebuild -project Skim.xcodeproj -scheme Skim -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **` (new method is unused so far — that is fine).

- [ ] **Step 5: Commit**

```bash
git add App/ReaderViewModel.swift
git commit -m "feat: recenter paused context on flick and on demand

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Native-scroll Threadline (momentum + recenter-above-center)

Rewrites `Threadline.swift` so the `UITextView` scrolls itself (native momentum/bounce), recenters slightly above center only on a `recenterKey` change, and exposes callbacks (wired but inert until Task 3/4). Updates `ReadingView` to host the paused Threadline as a front layer, yield the surface gesture for band touches, and delete the old custom drag-offset path. `ThreadlineScroller` is removed.

**Files:**
- Modify (full rewrite): `App/Threadline.swift`
- Modify: `App/ReadingView.swift` (`@State contextScroller` ~107; `bottomContent` ~381-420; root `ZStack` ~188-226; `surfaceDragGesture` ~628-777; `contextBand` ~440-444)

**Interfaces:**
- Consumes: `ReaderViewModel` (`.tokens`, `.currentIndex`, `.contextRecenterTick`, `.state`, `.shouldShowContext`), `ReadingContext.proseMap(_:)` + `ReadingContext.ProseMap`, `Color.readingAccent/readingForeground/readingMuted/readingSurface/readingBorder`.
- Produces:
  - `struct Threadline: View` with init `Threadline(viewModel:height:leftHanded:onHoldRead:onRelease:onCruiseToggle:onRecenter:)` where the four trailing params are `@escaping () -> Void` callbacks. (`onRecenter` is invoked by the locator added in Task 4; passed now so the signature is final.)
  - Removes the `ThreadlineScroller` type entirely.

- [ ] **Step 1: Rewrite `App/Threadline.swift`**

Replace the **entire file** with:

```swift
import SwiftUI
import UIKit

/// The paused "where am I" surface. When the reader rests, the foot of the screen
/// shows a calm, natively scrollable window of the surrounding prose — the active
/// word in amber, the current sentence in full ink, the rest dimmer — so you can
/// inspect where you are without leaving the reading surface.
///
/// Native momentum is the whole point: the `UITextView` owns its own pan, so the
/// window glides, decelerates, and rubber-bands like any iOS scroll surface. The
/// reader's other actions (hold-to-read, double-tap Cruise) are owned here too, by
/// UIKit gesture recognizers, so the band is a self-contained instrument.
///
///   • **Correct occurrence.** The active word is highlighted by token *index* →
///     character range (`ReadingContext.proseMap`), never by string search, so the
///     third "the" in "the the the" lights up — not the first one a search finds.
///   • **Highlight ≠ scroll.** The highlight follows the active token every render;
///     the viewport only re-centers on a discrete `recenterKey` bump (pause, scrub,
///     flick, locator tap), so free manual scrolling never snaps back.
struct Threadline: View {
    let viewModel: ReaderViewModel
    /// Fixed viewport height — sized by the caller so the block never collides with
    /// the pivot word up top or the progress cluster below.
    let height: CGFloat
    /// Which hand holds the gauge — places the locator on the open side.
    let leftHanded: Bool
    /// A still press-and-hold crossed the read gate: start reading.
    let onHoldRead: () -> Void
    /// The read-initiating hold lifted: pause.
    let onRelease: () -> Void
    /// A clean double tap: toggle Cruise.
    let onCruiseToggle: () -> Void
    /// The locator was tapped: re-center on the active word.
    let onRecenter: () -> Void

    /// True once the user has scrolled the active word out of the comfortable
    /// central band — drives the amber "back to word" locator. Owned here, fed by
    /// the text view's scroll callback.
    @State private var offCenter = false

    var body: some View {
        ThreadlineTextView(
            tokens: viewModel.tokens,
            activeIndex: viewModel.currentIndex,
            recenterKey: viewModel.contextRecenterTick,
            onHoldRead: onHoldRead,
            onRelease: onRelease,
            onCruiseToggle: onCruiseToggle,
            onOffCenterChange: { off in
                // Cheap: only flips when the active word crosses the comfort band.
                if off != offCenter { offCenter = off }
            }
        )
        .frame(maxWidth: .infinity)
        .frame(height: height)
        // Soft top/bottom dissolve so the outer lines melt into the reading space
        // and the eye settles on the centered active word.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.14),
                    .init(color: .black, location: 0.86),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        // The "back to word" locator: a small amber glyph on the open side, shown
        // only once the active word has scrolled out of view. Tapping re-centers.
        .overlay(alignment: leftHanded ? .bottomTrailing : .bottomLeading) {
            if offCenter {
                Button(action: onRecenter) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.readingAccent)
                        .frame(width: 34, height: 34)
                        .background(Color.readingSurface.opacity(0.85), in: Circle())
                        .overlay(Circle().stroke(Color.readingBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to current word")
                .padding(10)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: offCenter)
    }
}

/// A natively scrollable `UITextView` bridge. Renders the full clean prose as one
/// attributed string, highlights the active token's range, scrolls that range to
/// slightly-above-center on a `recenterKey` bump, and owns the band's gesture
/// recognizers (long-press → read, double-tap → Cruise). TextKit handles long
/// single paragraphs (500+ words) cheaply and gives the exact glyph rect needed to
/// center precisely.
private struct ThreadlineTextView: UIViewRepresentable {
    let tokens: [ReadingToken]
    let activeIndex: Int
    /// Bumped by the view model on each pause/scrub/flick/locator-tap; the window
    /// re-centers on the active word only when this changes.
    let recenterKey: Int
    let onHoldRead: () -> Void
    let onRelease: () -> Void
    let onCruiseToggle: () -> Void
    let onOffCenterChange: (Bool) -> Void

    // Tunables (see plan Global Constraints).
    private static let minHoldToRead: TimeInterval = 0.12
    private static let holdAllowableMovement: CGFloat = 10
    private static let recenterBias: CGFloat = 0.40       // active word 40% down
    private static let comfortLow: CGFloat = 0.20         // off-center below this…
    private static let comfortHigh: CGFloat = 0.60        // …or above this

    // Calm, rounded body type matching the reading surface. Scaled for Dynamic Type.
    private static func font(bold: Bool) -> UIFont {
        let base = UIFont.systemFont(ofSize: 18, weight: bold ? .semibold : .regular)
        let rounded = base.fontDescriptor.withDesign(.rounded).map {
            UIFont(descriptor: $0, size: 18)
        } ?? base
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: rounded)
    }

    // Three legibility tiers: surrounding text dim but readable, the current
    // sentence full ink as the "you are here" line, the active word amber on top.
    private static let surroundColor = UIColor(Color.readingForeground).withAlphaComponent(0.55)
    private static let sentenceColor = UIColor(Color.readingForeground)
    private static let activeColor = UIColor(Color.readingAccent)

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Owns recognizer targets + scroll delegate, and caches what is needed to
    /// recompute the active range's on-screen position as the user scrolls.
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var signature = ""
        var map = ReadingContext.ProseMap(text: "", ranges: [])
        var previousSentence: NSRange?
        var lastRecenterKey = Int.min
        var lastActiveIndex = Int.min
        /// Range currently highlighted active — its rect drives off-center detection.
        var activeRange = NSRange(location: NSNotFound, length: 0)
        /// True between long-press `.began` and its end: a read started from the band.
        var didHoldRead = false
        /// Latched off-center value, so the SwiftUI binding only fires on a change.
        var reportedOffCenter = false

        // Closures refreshed every `updateUIView` so they never go stale.
        var onHoldRead: () -> Void = {}
        var onRelease: () -> Void = {}
        var onCruiseToggle: () -> Void = {}
        var onOffCenterChange: (Bool) -> Void = {}
        var recenterBias: CGFloat = 0.40
        var comfortLow: CGFloat = 0.20
        var comfortHigh: CGFloat = 0.60
        weak var textView: UITextView?

        @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            switch gr.state {
            case .began:
                didHoldRead = true
                onHoldRead()
            case .ended, .cancelled, .failed:
                if didHoldRead { onRelease() }
                didHoldRead = false
            default:
                break
            }
        }

        @objc func handleDoubleTap(_ gr: UITapGestureRecognizer) {
            onCruiseToggle()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateOffCenter()
        }

        /// Where the active word's vertical mid-point sits in the viewport (0 = top,
        /// 1 = bottom); off-center when it leaves the comfort band or scrolls away.
        func updateOffCenter() {
            guard let tv = textView, tv.bounds.height > 0,
                  activeRange.location != NSNotFound else { return }
            let layout = tv.layoutManager
            let glyphRange = layout.glyphRange(forCharacterRange: activeRange, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer)
            rect.origin.y += tv.textContainerInset.top
            let frac = (rect.midY - tv.contentOffset.y) / tv.bounds.height
            let off = frac < comfortLow || frac > comfortHigh
            if off != reportedOffCenter {
                reportedOffCenter = off
                onOffCenterChange(off)
            }
        }

        // Let the scroll view's pan run alongside our recognizers.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    func makeUIView(context: Context) -> UITextView {
        // Explicit TextKit 1 stack so `layoutManager` glyph metrics are available.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: .zero)
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let textView = UITextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = false
        // Interactive + natively scrollable: this is what buys momentum/bounce.
        textView.isUserInteractionEnabled = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = true
        textView.indicatorStyle = .white
        textView.delaysContentTouches = false
        textView.backgroundColor = .clear
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)

        let coord = context.coordinator
        coord.textView = textView
        textView.delegate = coord

        // Hold-to-read: a still press past the gate starts reading; moving past the
        // small allowance fails this and the scroll pan wins.
        let longPress = UILongPressGestureRecognizer(target: coord, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = Self.minHoldToRead
        longPress.allowableMovement = Self.holdAllowableMovement
        longPress.delegate = coord
        textView.addGestureRecognizer(longPress)

        // Double-tap → Cruise. A clean quick double tap won't trip the longer press.
        let doubleTap = UITapGestureRecognizer(target: coord, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = coord
        textView.addGestureRecognizer(doubleTap)

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coord = context.coordinator
        coord.textView = textView
        coord.onHoldRead = onHoldRead
        coord.onRelease = onRelease
        coord.onCruiseToggle = onCruiseToggle
        coord.onOffCenterChange = onOffCenterChange
        coord.recenterBias = Self.recenterBias
        coord.comfortLow = Self.comfortLow
        coord.comfortHigh = Self.comfortHigh

        // Rebuild the prose + ranges only when the token set changes.
        let signature = "\(tokens.first?.id.uuidString ?? "")#\(tokens.count)"
        if signature != coord.signature {
            coord.signature = signature
            coord.map = ReadingContext.proseMap(tokens)
            coord.previousSentence = nil
            coord.lastActiveIndex = Int.min
            coord.lastRecenterKey = Int.min
            textView.textStorage.setAttributedString(baseAttributed(coord.map.text))
        }

        guard coord.map.ranges.indices.contains(activeIndex) else { return }
        let active = coord.map.ranges[activeIndex]
        coord.activeRange = active

        let indexChanged = activeIndex != coord.lastActiveIndex
        let keyChanged = recenterKey != coord.lastRecenterKey

        // Highlight follows the active token every time it changes — independent of
        // scrolling, so the amber word is always correct even mid-scroll.
        if indexChanged {
            let sentence = sentenceRange(activeIndex: activeIndex, map: coord.map)
            let storage = textView.textStorage
            storage.beginEditing()
            if let previous = coord.previousSentence, previous.location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: Self.surroundColor, range: previous)
                storage.addAttribute(.font, value: Self.font(bold: false), range: previous)
            }
            storage.addAttribute(.foregroundColor, value: Self.sentenceColor, range: sentence)
            storage.addAttribute(.font, value: Self.font(bold: false), range: sentence)
            storage.addAttribute(.foregroundColor, value: Self.activeColor, range: active)
            storage.addAttribute(.font, value: Self.font(bold: true), range: active)
            storage.endEditing()
            coord.previousSentence = sentence
            coord.lastActiveIndex = activeIndex
        }

        // Re-center ONLY on a discrete recenter bump — never just because the active
        // index moved — so free manual scrolling is never yanked back.
        if keyChanged {
            coord.lastRecenterKey = recenterKey
            DispatchQueue.main.async {
                center(textView, on: active, bias: Self.recenterBias)
                coord.updateOffCenter()
            }
        }
    }

    /// The whole prose, dim and calm — the base every render starts from.
    private func baseAttributed(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        paragraph.paragraphSpacing = 12
        paragraph.alignment = .natural
        return NSAttributedString(string: text, attributes: [
            .font: Self.font(bold: false),
            .foregroundColor: Self.surroundColor,
            .paragraphStyle: paragraph,
        ])
    }

    /// The character span of the sentence the active token belongs to. Tokens carry
    /// a monotonic `sentenceIndex` (and a sentence never crosses a paragraph break),
    /// so the sentence's tokens are contiguous — widen out from the active token
    /// while the index holds, then union the end ranges.
    private func sentenceRange(activeIndex: Int, map: ReadingContext.ProseMap) -> NSRange {
        let sentence = tokens[activeIndex].sentenceIndex
        var lo = activeIndex, hi = activeIndex
        while lo - 1 >= 0, tokens[lo - 1].sentenceIndex == sentence { lo -= 1 }
        while hi + 1 < tokens.count, tokens[hi + 1].sentenceIndex == sentence { hi += 1 }
        let start = map.ranges[lo].location
        let end = map.ranges[hi].location + map.ranges[hi].length
        return NSRange(location: start, length: end - start)
    }

    /// Scroll so the active range sits `bias` of the way down the viewport (0.40 =
    /// slightly above center), clamped to the scrollable bounds. The clamp alone
    /// handles begin (pins near top), end (pins at bottom), and text shorter than
    /// the viewport (nothing to scroll).
    private func center(_ textView: UITextView, on range: NSRange, bias: CGFloat) {
        guard textView.bounds.height > 0, range.location != NSNotFound else { return }
        let layout = textView.layoutManager
        layout.ensureLayout(for: textView.textContainer)

        let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
        rect.origin.y += textView.textContainerInset.top

        let target = rect.midY - textView.bounds.height * bias
        let maxOffset = max(0, textView.contentSize.height - textView.bounds.height)
        let y = min(max(0, target), maxOffset)
        textView.setContentOffset(CGPoint(x: 0, y: y), animated: true)
    }
}
```

- [ ] **Step 2: Remove `contextScroller` state from `ReadingView`**

In `App/ReadingView.swift`, delete the line (~107):

```swift
    @State private var contextScroller = ThreadlineScroller()
```

- [ ] **Step 3: Add front-layer + yield state to `ReadingView`**

Near the other `@State` gesture fields (after `@State private var adjustingSpeed = false`, ~85), add:

```swift
    /// A press that began inside the paused Threadline band: the band's own UIKit
    /// recognizers own it, so the surface gesture yields (no hold, no steer).
    @State private var yieldToThreadline = false
    /// A read that was started by a hold *inside* the Threadline band. Keeps the
    /// band layer mounted through the hold so its long-press `.ended` can pause,
    /// even though the reader has left `.paused`.
    @State private var holdStartedInThreadline = false
```

- [ ] **Step 4: Stop rendering the paused Threadline inside `bottomContent`**

In `bottomContent` (~390-403), replace:

```swift
            if showsContext {
                if viewModel.state == .paused {
                    Threadline(viewModel: viewModel,
                               height: threadlineHeight(height),
                               scroller: contextScroller)
                        .padding(.leading, leftHanded ? gaugeReserve : backReserve)
                        .padding(.trailing, leftHanded ? backReserve : gaugeReserve)
                        .transition(.opacity)
                } else {
                    ContextStrip(viewModel: viewModel)
                        .padding(.horizontal, 28)
                        .transition(.opacity)
                }
            }
```

with (the paused Threadline now lives in its own front layer; only the calm `.ready` strip remains here):

```swift
            if showsContext && viewModel.state != .paused {
                ContextStrip(viewModel: viewModel)
                    .padding(.horizontal, 28)
                    .transition(.opacity)
            }
```

- [ ] **Step 5: Add the front interactive Threadline layer**

In the root `ZStack` (`body`, ~188-226), insert directly **after** `readingSurfaceGestureLayer(size: geo.size)` and **before** `navFlashLayer`:

```swift
                pausedThreadlineLayer(size: geo.size)
```

Then add the layer + geometry helpers near `bottomContent` (after `contextBand`, ~444):

```swift
    /// Is the paused context band currently interactive on screen? Visible when
    /// paused, and kept up through a band-initiated hold so its release can pause.
    private var showsPausedThreadline: Bool {
        viewModel.shouldShowContext &&
        (viewModel.state == .paused || holdStartedInThreadline)
    }

    /// The paused Threadline as a front sibling that owns its touches (native
    /// scroll + hold/cruise). Positioned absolutely over the same band/column the
    /// `.ready` strip would occupy, so nothing reflows. Faded while a hold reads.
    @ViewBuilder
    private func pausedThreadlineLayer(size: CGSize) -> some View {
        if showsPausedThreadline {
            let band = contextBand(size)
            let midY = (band.lowerBound + band.upperBound) / 2
            let leading = leftHanded ? gaugeReserve : backReserve
            let colWidth = max(0, size.width - gaugeReserve - backReserve)
            Threadline(
                viewModel: viewModel,
                height: threadlineHeight(size.height),
                leftHanded: leftHanded,
                onHoldRead: {
                    holdStartedInThreadline = true
                    viewModel.startHolding()
                },
                onRelease: {
                    viewModel.stopHolding()
                    holdStartedInThreadline = false
                },
                onCruiseToggle: { viewModel.toggleCruise() },
                onRecenter: { viewModel.recenterContext() }
            )
            .frame(width: colWidth, height: threadlineHeight(size.height))
            .position(x: leading + colWidth / 2, y: midY)
            // Fade the map while a hold streams words, so the pivot word stays hero.
            .opacity(viewModel.state == .paused ? 1 : 0.18)
            .animation(.easeOut(duration: 0.2), value: viewModel.state)
            .transition(.opacity)
        }
    }

    /// On-screen rect of the interactive paused band — used to yield the surface
    /// gesture for presses that start inside it.
    private func threadlineHitRect(_ size: CGSize) -> CGRect {
        let band = contextBand(size)
        let midY = (band.lowerBound + band.upperBound) / 2
        let h = threadlineHeight(size.height)
        let leading = leftHanded ? gaugeReserve : backReserve
        let colWidth = max(0, size.width - gaugeReserve - backReserve)
        return CGRect(x: leading, y: midY - h / 2 - 12, width: colWidth, height: h + 24)
    }
```

- [ ] **Step 6: Yield the surface gesture for band-origin presses; delete the old custom-scroll path**

In `surfaceDragGesture(size:)` `onChanged`, replace the first-touch context block (~644-651):

```swift
                    // Eligible to scroll the paused context: the press began in the
                    // context band, on the bare canvas (not the steering rail).
                    gestureStartInContext = gestureStartState == .paused
                        && gestureStartZone == .canvas
                        && contextBand(size).contains(value.startLocation.y)
                    contextScrolling = false
                    lastScrollTranslation = 0
```

with:

```swift
                    // A press that begins inside the paused Threadline band belongs
                    // to the band's own native scroll / hold / cruise recognizers —
                    // the surface gesture yields entirely so it never double-handles.
                    yieldToThreadline = gestureStartState == .paused
                        && threadlineHitRect(size).contains(value.startLocation)
```

Then replace the whole context-arbitration block (~659-682):

```swift
                // Paused-context arbitration: a press that began in the context band
                // becomes a scroll the moment vertical travel clearly wins — which
                // cancels the pending read — but a still press falls through to the
                // hold gate and reads. Once a read has started (state left .paused),
                // the context is gone, so we never scroll it.
                if gestureStartInContext {
                    if viewModel.state == .paused {
                        let dy = value.translation.height
                        let dx = value.translation.width
                        if !contextScrolling, abs(dy) > 10, abs(dy) > abs(dx) {
                            contextScrolling = true
                            cancelHoldRead()        // movement won: no read
                            lastScrollTranslation = dy
                            dbg("threadline scroll start")
                        }
                        if contextScrolling {
                            let incremental = dy - lastScrollTranslation
                            lastScrollTranslation = dy
                            // Drag down → reveal earlier text (offset decreases).
                            contextScroller.scroll(by: -incremental)
                        }
                    }
                    return
                }
```

with:

```swift
                // The band owns its own touches; the surface gesture stays out.
                if yieldToThreadline {
                    cancelHoldRead()
                    return
                }
```

- [ ] **Step 7: Reset `yieldToThreadline` on end; drop dead resets**

In `surfaceDragGesture(size:)` `onEnded` (~769-775), replace:

```swift
                gestureActive = false
                axis = nil
                flickArmed = true
                adjustingSpeed = false
                gestureStartInContext = false
                contextScrolling = false
                lastScrollTranslation = 0
```

with:

```swift
                gestureActive = false
                axis = nil
                flickArmed = true
                adjustingSpeed = false
                yieldToThreadline = false
```

- [ ] **Step 8: Delete the now-dead gesture state fields**

In `App/ReadingView.swift`, delete these three `@State` declarations (they are now unreferenced — search to confirm zero remaining uses):

```swift
    @State private var gestureStartInContext = false
```
```swift
    @State private var contextScrolling = false
```
```swift
    @State private var lastScrollTranslation: CGFloat = 0
```

Run: `grep -n "gestureStartInContext\|contextScrolling\|lastScrollTranslation\|contextScroller\|ThreadlineScroller\|\.scroll(by:" App/ReadingView.swift App/Threadline.swift`
Expected: no matches.

- [ ] **Step 9: Build gate**

Run: `xcodebuild -project Skim.xcodeproj -scheme Skim -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 10: Install + on-device check**

Run: `scripts/deploy-device.sh`
On device (paste text, hold to read, release to pause):
- The paused band scrolls with **native momentum** on a flick and rubber-bands at the ends.
- A slow drag tracks the finger smoothly.
- Scrolling far away does **not** snap back.
- Pausing re-centers the active word slightly above center.
(Hold-to-read and double-tap-cruise inside the band, and the locator, arrive in Tasks 3–4 — not expected to fully work yet, though the wiring is present.)

- [ ] **Step 11: Commit**

```bash
git add App/Threadline.swift App/ReadingView.swift
git commit -m "feat: native momentum scroll for paused Threadline

UITextView owns its pan; recenter only on discrete tick, slightly above
center; surface gesture yields for band touches. Removes custom drag-offset
path and ThreadlineScroller.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Validate hold-to-read and double-tap-Cruise arbitration on device

The recognizers and callbacks were added in Task 2. This task verifies the arbitration on device and tunes the thresholds — the part that can only be judged by feel. No new code unless a defect is found.

**Files:**
- Possibly modify: `App/Threadline.swift` (`minHoldToRead`, `holdAllowableMovement`) — only if device feel demands.

**Interfaces:**
- Consumes: Task 2's `ThreadlineTextView` recognizers + `Threadline` callbacks; `ReadingView`'s `onHoldRead`/`onRelease` keep-alive (`holdStartedInThreadline`).
- Produces: tuned constants; no signature changes.

- [ ] **Step 1: On-device arbitration pass**

With the Task 2 build on device, verify each:
1. Press-and-hold **still** in the band → reading starts (start haptic), band fades.
2. Lift the held finger → reader pauses, band returns and re-centers.
3. A slight finger drift under ~10pt during the hold → still reads.
4. Vertical movement past threshold before the hold fires → scrolls; **no** read starts.
5. Clean double-tap in the band → Cruise toggles.
6. Scrolling fires **no** reading/cruise haptics.

- [ ] **Step 2: Tune if needed**

If a hold is too eager/sluggish or scroll steals stationary holds, adjust in `App/Threadline.swift`:
- `minHoldToRead` (raise toward `0.15` if accidental reads; lower toward `0.10` if holds feel laggy).
- `holdAllowableMovement` (raise toward `12` if scroll steals intended holds; lower toward `8` if reads fire when the user meant to scroll).

If no change is needed, state that explicitly and skip to Step 4.

- [ ] **Step 3: Rebuild + reinstall (only if tuned)**

Run: `xcodebuild -project Skim.xcodeproj -scheme Skim -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`
Run: `scripts/deploy-device.sh`

- [ ] **Step 4: Commit (only if tuned)**

```bash
git add App/Threadline.swift
git commit -m "tune: paused Threadline hold-to-read thresholds for device feel

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

If nothing changed, record "no tuning required" and proceed to Task 4 with no commit.

---

## Task 4: Validate the "Back to word" locator on device

The amber locator (`location.fill`), its `offCenter` visibility, and the `onRecenter` wiring were all added in Task 2. This task confirms the affordance behaves and tunes the comfort band.

**Files:**
- Possibly modify: `App/Threadline.swift` (`comfortLow`/`comfortHigh`, locator placement/padding) — only if device feel demands.

**Interfaces:**
- Consumes: Task 2's `offCenter` state, `onOffCenterChange` callback, `viewModel.recenterContext()` (Task 1).
- Produces: tuned comfort band; no signature changes.

- [ ] **Step 1: On-device locator pass**

With the latest build on device, paused:
1. Scroll the active word out of view → the amber locator fades in on the open side (right side for left-hand, left side for right-hand).
2. Tap the locator → the window smoothly re-centers the active word slightly above center, and the locator fades out.
3. Scroll only slightly (active word still near center) → locator stays hidden.
4. Scrub to a new position → highlight + window re-center on the scrubbed word; locator hidden.
5. Flick rewind/forward while paused → window re-centers on the new word.

- [ ] **Step 2: Tune if needed**

In `App/Threadline.swift` adjust only if needed:
- `comfortLow`/`comfortHigh` (widen, e.g. `0.12…0.72`, if the locator appears too eagerly; narrow if it lingers when the word is clearly gone).
- Locator `.padding(10)` / `frame(width:34,height:34)` for placement polish.

If no change is needed, state that explicitly and skip to Step 4.

- [ ] **Step 3: Rebuild + reinstall (only if tuned)**

Run: `xcodebuild -project Skim.xcodeproj -scheme Skim -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`
Run: `scripts/deploy-device.sh`

- [ ] **Step 4: Commit (only if tuned)**

```bash
git add App/Threadline.swift
git commit -m "tune: paused Threadline locator comfort band

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

If nothing changed, record "no tuning required" and proceed to Task 5.

---

## Task 5: Full QA sweep + final decisions

**Files:**
- Possibly modify: `App/Threadline.swift` (scroll-indicator decision, `recenterBias`).

**Interfaces:** none new.

- [ ] **Step 1: Run the full QA checklist on device**

1. Pause → active word slightly above center.
2. Flick → momentum scroll.
3. Slow drag → smooth tracking.
4. Hold still → reading starts; release → pause.
5. Slight drift under threshold during hold → still reads.
6. Move past threshold → scroll wins, no read.
7. Scroll far → no snap-back, locator appears.
8. Tap locator → smooth recenter.
9. Repeated words ("the the the") → correct occurrence highlighted while scrolling.
10. Long paragraph (500+ words) → no jank; short text → no awkward bounce/clamp.
11. Left-hand and right-hand modes (toggle in Settings) → column + locator mirror correctly, never under the gauge/back/scrubber.
12. Small and large phone layouts (e.g. SE-class vs Max via simulator if no second device).

- [ ] **Step 2: Final decisions**

- **Scroll indicator:** if the native indicator reads as utilitarian, set `textView.showsVerticalScrollIndicator = false` in `App/Threadline.swift`. Otherwise keep it.
- **Recenter bias:** if "slightly above center" feels off, adjust `recenterBias` (toward `0.5` = dead center, toward `0.33` = higher).

- [ ] **Step 3: Build + install final**

Run: `xcodebuild -project Skim.xcodeproj -scheme Skim -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`
Run: `scripts/deploy-device.sh`

- [ ] **Step 4: Commit any final changes**

```bash
git add App/Threadline.swift
git commit -m "polish: paused Threadline scroll indicator + recenter bias

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

If nothing changed, record "QA passed, no changes" — the feature is complete.

---

## Self-Review

**Spec coverage**

| Spec requirement | Task |
| --- | --- |
| Native scroll physics (momentum/bounce/tracking) | Task 2 (`isScrollEnabled`, `alwaysBounceVertical`) |
| Drag scrolls / still press holds / double-tap cruise | Task 2 recognizers; Task 3 validates |
| Cancel hold on vertical move past threshold | Task 2 (`allowableMovement`); Task 3 validates |
| No scroll-fired reading/cruise haptics | Task 2 (scroll path calls no haptics); Task 3 verifies |
| Auto-center on pause via index→range (not string search) | Task 2 (`proseMap`, `center(on:bias:)`); recenter on `recenterKey` |
| Slightly above center | Task 2 (`recenterBias = 0.40`) |
| Don't fight manual scroll / recenter only on discrete triggers | Task 1 (tick bumps) + Task 2 (recenter gated on `keyChanged` only) |
| "Back to word" amber locator, appears/hides, recenters | Task 2 (overlay + `offCenter` + `onRecenter`); Task 4 validates |
| Highlight tiers + correct repeated-word occurrence while scrolling | Task 2 (highlight on `indexChanged`, `proseMap`) |
| Edge fades | Task 2 (mask retained) |
| Subtle scroll indicator (or hidden) | Task 2 default on; Task 5 final call |
| Layout zones (clear of gauge/back/scrubber/chip), both hands, device sizes | Task 2 (`threadlineHitRect`/column padding); Task 5 validates |
| Performance (cache attributed text, update only on meaningful change) | Task 2 (`signature` cache, in-place edits, threshold-gated Bool) |
| State behavior (faint during read, scrollable paused, scrub/flick recenter) | Task 2 (`opacity` fade, front layer) + Task 1 (flick/scrub ticks) |

**Placeholder scan:** No TBD/TODO; every code step shows complete code; tuning tasks specify exact constants and directions. ✓

**Type consistency:** `Threadline(viewModel:height:leftHanded:onHoldRead:onRelease:onCruiseToggle:onRecenter:)` is defined in Task 2 Step 1 and called identically in Task 2 Step 5. `recenterContext()` defined in Task 1, called in Task 2's `onRecenter`. `center(_:on:bias:)`, `updateOffCenter()`, `recenterBias`/`comfortLow`/`comfortHigh` named consistently across steps. `ThreadlineScroller` fully removed (no dangling refs after Task 2 Step 8 grep). ✓

**Deviation from spec, noted:** the spec's cleanup list said delete `contextBand`; it is instead **repurposed** to position the front layer and compute `threadlineHitRect` (it already encodes the band's exact on-screen geometry), which is simpler than recomputing. No behavior change.
