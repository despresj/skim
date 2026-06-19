import Foundation

/// Strips common Markdown syntax so the reader streams clean words — never a
/// literal `**`, `#`, backtick, or link URL. Works line-by-line to preserve
/// blank lines, which the tokenizer reads as paragraph breaks.
///
/// This is intentionally not a full CommonMark parser; it targets the marks
/// that actually show up in prose people paste in. Underscore emphasis is
/// boundary-guarded so identifiers like `snake_case` survive intact.
public enum Markdown {
    public static func strip(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var out: [String] = []
        var inFence = false

        for rawLine in normalized.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks (``` or ~~~): drop the fence lines, keep the
            // code inside verbatim (no inline stripping).
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { out.append(rawLine); continue }

            // Thematic breaks (---, ***, ___) carry no words.
            if isHorizontalRule(trimmed) { continue }

            out.append(stripInline(stripLinePrefixes(rawLine)))
        }

        return out.joined(separator: "\n")
    }

    /// True for a line that is only 3+ of the same rule character (-, *, _).
    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, "-*_".contains(first), trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    /// Removes leading block markers: blockquotes, list bullets/numbers, and
    /// ATX heading hashes (plus the leading indentation around them).
    private static func stripLinePrefixes(_ line: String) -> String {
        var s = Substring(line)

        func dropSpaces() { while let c = s.first, c == " " || c == "\t" { s = s.dropFirst() } }

        dropSpaces()
        // Blockquotes, possibly nested: "> > "
        while s.first == ">" { s = s.dropFirst(); dropSpaces() }

        // ATX heading: up to 6 leading '#', then a space.
        if s.first == "#" {
            var t = s, hashes = 0
            while t.first == "#" { t = t.dropFirst(); hashes += 1 }
            if hashes <= 6, t.first == " " || t.isEmpty { s = t; dropSpaces() }
        }

        // Unordered list marker: -, *, or + then a space.
        if let f = s.first, f == "-" || f == "*" || f == "+", s.dropFirst().first == " " {
            s = s.dropFirst(); dropSpaces()
        } else {
            // Ordered list marker: digits then '.' or ')' then a space.
            var t = s, digits = 0
            while let c = t.first, c.isNumber { t = t.dropFirst(); digits += 1 }
            if digits > 0, let c = t.first, c == "." || c == ")", t.dropFirst().first == " " {
                s = t.dropFirst(); dropSpaces()
            }
        }

        return String(s)
    }

    /// Unwraps inline marks: images/links to their text, code spans, and
    /// emphasis (bold, italic, strikethrough).
    private static func stripInline(_ line: String) -> String {
        var s = line

        // Protect backslash-escaped marks behind private-use placeholders so the
        // emphasis rules below skip them (e.g. `5 \* 3` keeps its star).
        let escapes: [(String, String)] = [
            ("\\*", "\u{E001}"), ("\\_", "\u{E002}"),
            ("\\`", "\u{E003}"), ("\\~", "\u{E004}"),
        ]
        for (mark, placeholder) in escapes { s = s.replacingOccurrences(of: mark, with: placeholder) }

        s = replace(s, #"!\[([^\]]*)\]\([^)]*\)"#, "$1")          // image -> alt
        s = replace(s, #"\[([^\]]*)\]\([^)]*\)"#, "$1")           // link -> label
        s = replace(s, #"`([^`]+)`"#, "$1")                        // inline code
        s = replace(s, #"(\*\*\*)(.+?)\1"#, "$2")                  // ***bold italic***
        s = replace(s, #"(\*\*)(.+?)\1"#, "$2")                    // **bold**
        s = replace(s, #"(\*)(.+?)\1"#, "$2")                      // *italic*
        s = replace(s, #"~~(.+?)~~"#, "$1")                        // ~~strike~~
        // Underscore emphasis only when flanked by non-word chars, so
        // snake_case / file_names are left alone.
        s = replace(s, #"(?<![\w])(___)(?=\S)(.+?)(?<=\S)\1(?![\w])"#, "$2")
        s = replace(s, #"(?<![\w])(__)(?=\S)(.+?)(?<=\S)\1(?![\w])"#, "$2")
        s = replace(s, #"(?<![\w])(_)(?=\S)(.+?)(?<=\S)\1(?![\w])"#, "$2")

        // Drop any remaining backslash before other punctuation (\# -> #).
        s = replace(s, #"\\([\\{}\[\]()#+\-.!>])"#, "$1")

        // Restore the protected marks as their literal characters.
        for (mark, placeholder) in escapes {
            s = s.replacingOccurrences(of: placeholder, with: String(mark.dropFirst()))
        }
        return s
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }
}
