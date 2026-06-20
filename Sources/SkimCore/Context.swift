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
    public static func fullText(_ tokens: [ReadingToken]) -> String {
        guard let first = tokens.first else { return "" }
        var result = first.text
        var lastParagraph = first.paragraphIndex
        for token in tokens.dropFirst() {
            if token.paragraphIndex != lastParagraph {
                result += "\n\n" + token.text
                lastParagraph = token.paragraphIndex
            } else {
                result += " " + token.text
            }
        }
        return result
    }
}
