import Foundation

/// Builds the local prose around the reading position so the UI can show a
/// faint "where am I" strip — the words just read, the current word, and a
/// glimpse of what's next. Pure and side-effect free so `CoreChecks` can verify
/// the windowing without an app. See the spec's "Pause reveals local context."
public enum ReadingContext {
    /// The prose surrounding one token, split so the view can emphasize the
    /// current word. `before`/`after` are space-joined runs (possibly empty at
    /// the ends of the text).
    public struct Window: Equatable, Sendable {
        public let before: String
        public let current: String
        public let after: String

        public init(before: String, current: String, after: String) {
            self.before = before
            self.current = current
            self.after = after
        }
    }

    /// A window of up to `before` words behind `index` and `after` words ahead,
    /// clamped to the text. Returns empties if `index` is out of range.
    public static func window(
        tokens: [ReadingToken],
        index: Int,
        before: Int,
        after: Int
    ) -> Window {
        guard tokens.indices.contains(index) else {
            return Window(before: "", current: "", after: "")
        }
        let lo = max(0, index - before)
        let hi = min(tokens.count - 1, index + after)
        let pre = tokens[lo..<index].map(\.text).joined(separator: " ")
        let post = index < hi ? tokens[(index + 1)...hi].map(\.text).joined(separator: " ") : ""
        return Window(before: pre, current: tokens[index].text, after: post)
    }

    /// Reassemble the whole text from its tokens for the end-of-read review: words
    /// space-joined, with a blank line wherever the paragraph index advances so the
    /// original paragraph breaks read back as paragraphs. Markdown noise is already
    /// gone (the tokenizer stripped it), so this is clean reading prose, not the raw
    /// source. Empty token list → empty string.
    ///
    /// This is exactly `proseMap(tokens).text`; the two share one assembly rule so
    /// the string the paused Threadline highlights can never drift from this one.
    public static func fullText(_ tokens: [ReadingToken]) -> String {
        proseMap(tokens).text
    }

    /// The full clean prose (identical to `fullText`) paired with each token's
    /// character range *within that exact string*, so a view can highlight the
    /// active token and scroll its range into view without ever string-searching —
    /// which would mis-target repeated words. The range and the string are built in
    /// one pass, so `ranges[i]` is the source span of `tokens[i]` by construction.
    public struct ProseMap: Equatable, Sendable {
        public let text: String
        /// `NSRange` (UTF-16 offsets) into `text`, one per token, in token order.
        /// UTF-16 is what `NSAttributedString`/TextKit consume, so the app layer
        /// never re-derives offsets. Valid only against this map's own `text`.
        public let ranges: [NSRange]

        public init(text: String, ranges: [NSRange]) {
            self.text = text
            self.ranges = ranges
        }
    }

    /// Assemble the clean prose and the per-token character ranges together. Uses
    /// the same separator rule as `fullText` (`\n\n` when the paragraph index
    /// advances, a single space otherwise) and tracks a running UTF-16 cursor so
    /// each token's `NSRange` lands on its own characters. Empty tokens → empty.
    public static func proseMap(_ tokens: [ReadingToken]) -> ProseMap {
        guard let first = tokens.first else { return ProseMap(text: "", ranges: []) }

        var text = first.text
        var ranges: [NSRange] = [NSRange(location: 0, length: first.text.utf16.count)]
        var cursor = first.text.utf16.count
        var lastParagraph = first.paragraphIndex

        for token in tokens.dropFirst() {
            let separator = token.paragraphIndex != lastParagraph ? "\n\n" : " "
            text += separator + token.text
            cursor += separator.utf16.count
            ranges.append(NSRange(location: cursor, length: token.text.utf16.count))
            cursor += token.text.utf16.count
            lastParagraph = token.paragraphIndex
        }

        return ProseMap(text: text, ranges: ranges)
    }
}
