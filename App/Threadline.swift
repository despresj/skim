import SwiftUI
import UIKit

/// An imperative handle the reader's drag gesture uses to scroll the context. The
/// context view itself takes no touches (so it can never block hold/tap); instead
/// the one persistent gesture layer drives it through this, keeping a single owner
/// for every touch. Holds a weak ref to the live text view and clamps to bounds.
@MainActor final class ThreadlineScroller {
    weak var textView: UITextView?

    /// Nudge the content by `dy` points, clamped to the scrollable range. Drag the
    /// finger down (positive) to reveal earlier text (offset decreases) — call with
    /// the negated incremental translation for natural touch scrolling.
    func scroll(by dy: CGFloat) {
        guard let textView, textView.bounds.height > 0 else { return }
        let maxOffset = max(0, textView.contentSize.height - textView.bounds.height)
        let y = min(max(0, textView.contentOffset.y + dy), maxOffset)
        textView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }
}

/// The paused "where am I" surface. When the reader rests, the foot of the screen
/// shows a calm, auto-centered window of the surrounding prose — the active word
/// in amber, the current sentence in full ink, the rest dimmer — so you can see
/// where you are without leaving the reading surface.
///
/// It is a *decorative orientation strip*, deliberately simple: it never takes
/// touches (the caller hosts it behind the gesture surface with hit-testing off),
/// and it lays out as a plain reserved column — no text wrapping around controls.
/// The one bit of machinery it keeps is the thing that makes it trustworthy:
///
///   • **Correct occurrence.** The active word is highlighted by token *index* →
///     character range (`ReadingContext.proseMap`), never by string search, so the
///     third "the" in "the the the" lights up — not the first one a search finds.
struct Threadline: View {
    let viewModel: ReaderViewModel
    /// Fixed viewport height — sized by the caller to the screen so the block
    /// never collides with the pivot word up top or the progress cluster below.
    let height: CGFloat
    /// Handle the reader's drag gesture uses to scroll this (the view stays
    /// non-interactive; the persistent gesture layer drives it).
    let scroller: ThreadlineScroller

    var body: some View {
        ThreadlineTextView(
            tokens: viewModel.tokens,
            activeIndex: viewModel.currentIndex,
            recenterKey: viewModel.contextRecenterTick,
            scroller: scroller
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
    }
}

/// A `UITextView` bridge: renders the full clean prose as one attributed string,
/// highlights the active token's range, and scrolls that range to the vertical
/// center. TextKit handles long single paragraphs (500+ words) cheaply and gives
/// the exact glyph rect needed to center precisely. The view never takes touches
/// (`isUserInteractionEnabled = false`); centering is purely programmatic, so it
/// can never block the reader's tap/hold/flick gestures.
private struct ThreadlineTextView: UIViewRepresentable {
    let tokens: [ReadingToken]
    let activeIndex: Int
    /// Bumped by the view model on each pause/scrub, so the window recenters on the
    /// active word whenever the reader settles or scrubs.
    let recenterKey: Int
    /// Registered with the live text view so the reader's drag can scroll it.
    let scroller: ThreadlineScroller

    // Calm, rounded body type matching the reading surface. Scaled for Dynamic
    // Type via UIFontMetrics.
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

    final class Coordinator {
        /// Identity of the currently rendered token set, so the attributed string
        /// is rebuilt only when the text actually changes.
        var signature = ""
        var map = ReadingContext.ProseMap(text: "", ranges: [])
        /// The active sentence's range, lit to full ink last render — reset to dim
        /// before lighting the next. (It contains the active word, so resetting it
        /// also clears the old amber word in one stroke.)
        var previousSentence: NSRange?
        var lastRecenterKey = Int.min
        var lastActiveIndex = Int.min
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
        // Never takes touches — purely decorative orientation. The reader gesture
        // surface beneath owns every tap/hold; centering is programmatic.
        textView.isUserInteractionEnabled = false
        textView.backgroundColor = .clear
        textView.showsVerticalScrollIndicator = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        scroller.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coord = context.coordinator
        scroller.textView = textView

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

        let indexChanged = activeIndex != coord.lastActiveIndex
        let keyChanged = recenterKey != coord.lastRecenterKey
        guard indexChanged || keyChanged else { return }

        // Light the current sentence to full ink, then the active word in amber —
        // editing the storage in place (not reassigning text) preserves position.
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
        }

        coord.lastActiveIndex = activeIndex
        coord.lastRecenterKey = recenterKey

        // Center after layout settles.
        DispatchQueue.main.async {
            center(textView, on: active)
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

    /// Scroll so the active range sits at the vertical center, clamped to the
    /// scrollable bounds. The clamp alone handles begin (pins near top), end (pins
    /// at bottom), and text shorter than the viewport (nothing to scroll).
    private func center(_ textView: UITextView, on range: NSRange) {
        guard textView.bounds.height > 0, range.location != NSNotFound else { return }
        let layout = textView.layoutManager
        layout.ensureLayout(for: textView.textContainer)

        let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
        rect.origin.y += textView.textContainerInset.top

        let target = rect.midY - textView.bounds.height / 2
        let maxOffset = max(0, textView.contentSize.height - textView.bounds.height)
        let y = min(max(0, target), maxOffset)
        textView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }
}
