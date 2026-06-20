import Foundation

/// Turns raw text into a stream of `ReadingToken`s (word mode), assigning each
/// a delay multiplier for rhythm plus sentence/paragraph indices. The indices
/// are cheap to compute now and unlock semantic replay later.
public enum Tokenizer {
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…"]
    private static let clauseEnders: Set<Character> = [",", ";", ":"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}"]
    private static let openers: Set<Character> = ["\"", "'", "“", "‘", "«", "(", "[", "{"]
    private static let dashes: Set<Character> = ["—", "–"]

    // Common abbreviations whose trailing period is NOT a sentence end. Stored
    // lowercased; the candidate token is lowercased before lookup.
    private static let abbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "st.", "vs.",
        "etc.", "e.g.", "i.e.", "u.s.", "u.s.a.", "d.c.", "a.m.", "p.m.",
    ]

    // Delay multipliers, from the spec's pacing rules.
    private static let longWord = 1.15
    private static let clausePause = 1.4
    private static let sentencePause = 2.0
    private static let paragraphPause = 2.8
    private static let longWordThreshold = 8

    public static func tokenize(_ text: String) -> [ReadingToken] {
        // Clean Markdown first so the reader never shows literal `**`, `#`,
        // backticks, or link URLs.
        let paragraphs = paragraphize(Markdown.strip(text))

        var tokens: [ReadingToken] = []
        var tokenIndex = 0
        var sentenceIndex = 0

        for (paragraphIndex, words) in paragraphs.enumerated() {
            var lastWasSentenceEnd = false

            for (wordIndex, word) in words.enumerated() {
                let punctuation = trailingPunctuation(of: word)
                let isParagraphEnd = wordIndex == words.count - 1
                // An abbreviation's trailing period reads as part of the word,
                // not as a sentence boundary, so it neither pauses nor advances.
                let isAbbreviation = isKnownAbbreviation(word)
                let endsSentence = !isAbbreviation && (punctuation.map(sentenceEnders.contains) ?? false)

                var multiplier = 1.0
                if coreLength(of: word) > longWordThreshold { multiplier = max(multiplier, longWord) }
                if isComplexNumber(word) { multiplier = max(multiplier, longWord) }
                if hasInternalDash(word) { multiplier = max(multiplier, clausePause) }
                if let p = punctuation {
                    if clauseEnders.contains(p) { multiplier = max(multiplier, clausePause) }
                    else if sentenceEnders.contains(p), !isAbbreviation { multiplier = max(multiplier, sentencePause) }
                }
                if isParagraphEnd { multiplier = max(multiplier, paragraphPause) }

                tokens.append(
                    ReadingToken(
                        text: word,
                        delayMultiplier: multiplier,
                        sentenceIndex: sentenceIndex,
                        paragraphIndex: paragraphIndex,
                        tokenIndex: tokenIndex
                    )
                )
                tokenIndex += 1

                if endsSentence { sentenceIndex += 1 }
                lastWasSentenceEnd = endsSentence
            }

            // A paragraph break always starts a fresh sentence, even when the
            // paragraph didn't end with terminal punctuation.
            if !lastWasSentenceEnd && !words.isEmpty { sentenceIndex += 1 }
        }

        return tokens
    }

    /// Splits text into paragraphs (arrays of words). Blank lines separate
    /// paragraphs; all other whitespace separates words.
    private static func paragraphize(_ text: String) -> [[String]] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var paragraphs: [[String]] = []
        var current: [String] = []

        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { paragraphs.append(current); current = [] }
            } else {
                let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                current.append(contentsOf: words)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }

        return paragraphs
    }

    /// The trailing punctuation mark of a word, looking past closing quotes and
    /// brackets (e.g. `pipeline.")` → `.`). Returns nil when none applies.
    private static func trailingPunctuation(of word: String) -> Character? {
        let chars = Array(word)
        var i = chars.count - 1
        while i >= 0, closers.contains(chars[i]) { i -= 1 }
        guard i >= 0 else { return nil }
        let c = chars[i]
        return (sentenceEnders.contains(c) || clauseEnders.contains(c)) ? c : nil
    }

    /// Number of letters/digits in a word, ignoring punctuation.
    private static func coreLength(of word: String) -> Int {
        word.reduce(0) { $0 + (($1.isLetter || $1.isNumber) ? 1 : 0) }
    }

    /// Whether the word is a known abbreviation (e.g. "Mr.", "e.g.") whose
    /// trailing period must not be read as a sentence boundary. The display
    /// text is never altered; only a normalized copy is matched: surrounding
    /// quote/bracket chars are stripped from both ends, then lowercased.
    private static func isKnownAbbreviation(_ word: String) -> Bool {
        var chars = Array(word)
        while let first = chars.first, openers.contains(first) || closers.contains(first) {
            chars.removeFirst()
        }
        while let last = chars.last, openers.contains(last) || closers.contains(last) {
            chars.removeLast()
        }
        return abbreviations.contains(String(chars).lowercased())
    }

    /// Whether the word contains an em-dash or en-dash flanked by word
    /// characters (so "Wait—really" qualifies but a leading/trailing dash does
    /// not). Used to apply a clause pause without splitting the token.
    private static func hasInternalDash(_ word: String) -> Bool {
        let chars = Array(word)
        for i in chars.indices where dashes.contains(chars[i]) {
            let hasLeft = i > 0 && (chars[i - 1].isLetter || chars[i - 1].isNumber)
            let hasRight = i < chars.count - 1 && (chars[i + 1].isLetter || chars[i + 1].isNumber)
            if hasLeft && hasRight { return true }
        }
        return false
    }

    /// Whether a numeric token is visually complex enough to warrant a small
    /// slow-down: it contains a digit plus a separator (`,`/`.`), or has 6+
    /// numeric/separator characters total (e.g. "1,000,000", "3.14159",
    /// "100000", "12.5%"). Tokens without any digit never qualify.
    private static func isComplexNumber(_ word: String) -> Bool {
        var digits = 0
        var separators = 0
        for c in word {
            if c.isNumber { digits += 1 }
            else if c == "," || c == "." { separators += 1 }
        }
        guard digits > 0 else { return false }
        if separators > 0 { return true }
        return (digits + separators) >= 6
    }
}
