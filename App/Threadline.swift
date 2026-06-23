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
    final class Coordinator: NSObject, UITextViewDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
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
        var onOffCenterChange: (Bool) -> Void = { _ in }
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
