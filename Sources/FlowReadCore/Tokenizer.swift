import Foundation

/// Turns raw text into a stream of `ReadingToken`s (word mode), assigning each
/// a delay multiplier for rhythm plus sentence/paragraph indices. The indices
/// are cheap to compute now and unlock semantic replay later.
public enum Tokenizer {
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…"]
    private static let clauseEnders: Set<Character> = [",", ";", ":"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}"]

    // Delay multipliers, from the spec's pacing rules.
    private static let longWord = 1.15
    private static let clausePause = 1.4
    private static let sentencePause = 2.0
    private static let paragraphPause = 2.8
    private static let longWordThreshold = 8

    public static func tokenize(_ text: String) -> [ReadingToken] {
        let paragraphs = paragraphize(text)

        var tokens: [ReadingToken] = []
        var tokenIndex = 0
        var sentenceIndex = 0

        for (paragraphIndex, words) in paragraphs.enumerated() {
            var lastWasSentenceEnd = false

            for (wordIndex, word) in words.enumerated() {
                let punctuation = trailingPunctuation(of: word)
                let isParagraphEnd = wordIndex == words.count - 1
                let endsSentence = punctuation.map(sentenceEnders.contains) ?? false

                var multiplier = 1.0
                if coreLength(of: word) > longWordThreshold { multiplier = max(multiplier, longWord) }
                if let p = punctuation {
                    if clauseEnders.contains(p) { multiplier = max(multiplier, clausePause) }
                    else if sentenceEnders.contains(p) { multiplier = max(multiplier, sentencePause) }
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
}
