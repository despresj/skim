import Foundation

/// Typography/whitespace normalization for grounding checks. The model's
/// `supportingQuote` is compared as a substring of the source *after* both are
/// normalized, so curly quotes, dash variants, non-breaking spaces, and line
/// breaks don't reject a genuinely grounded quote. Strict enough to still demand
/// real overlap; tolerant of cosmetics. Idempotent: `normalize(normalize(x)) == normalize(x)`.
public enum QuoteNormalize {
    public static func normalize(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\u{2018}", "\u{2019}", "\u{201B}", "\u{2032}":      // ' ' ‛ ′ → '
                out.append("'")
            case "\u{201C}", "\u{201D}", "\u{201F}", "\u{2033}":      // " " ‟ ″ → "
                out.append("\"")
            case "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}":      // – — ― − → -
                out.append("-")
            case "\u{00A0}", "\u{2007}", "\u{202F}", "\u{2009}", "\u{200A}", "\u{2002}", "\u{2003}":
                out.append(" ")                                       // unicode spaces → space
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        // Collapse any run of whitespace (incl. the spaces we just mapped) to one.
        let collapsed = out.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        // Trim leading/trailing whitespace and punctuation.
        let trimmable = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return collapsed.trimmingCharacters(in: trimmable)
    }
}
