import Foundation

/// Sanitizes the raw contents of an imported `.txt` file before it reaches the
/// reader. Pure and UI-free so `CoreChecks` can exercise it without Xcode.
///
/// The file path exists so a Shortcut / Action Button can hand Skim a large body
/// of text without stuffing it through a `skim://` URL (which truncates) or
/// reaching for the pasteboard (which prompts). Unlike `DeepLinkParser`, this
/// deliberately does *not* cap length — the whole point is that long documents
/// arrive intact — so it mirrors the uncapped clipboard load path.
public enum ImportedText {
    /// Trim surrounding whitespace/newlines and reject empty input.
    /// Returns `nil` for whitespace-only (or empty) content so a blank file
    /// falls back quietly rather than loading a zero-word "read". Interior
    /// newlines and punctuation are preserved untouched for the tokenizer.
    public static func sanitize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
