import Foundation

/// Structural + grounding checks on a model-produced draft, before we mint
/// persisted questions. Catches shape problems and fabricated quotes; it cannot
/// catch a confidently-wrong answer key, which is why the UI also offers a
/// "this seems off" escape. Pure: returns the list of problems (empty = valid).
public enum ComprehensionValidationError: Error, Equatable {
    case wrongCount(got: Int, want: Int)
    case emptyQuestion(index: Int)
    case emptyChoice(index: Int, key: ChoiceKey)
    case duplicateChoices(index: Int)
    case emptyExplanation(index: Int)
    case quoteWrongLength(index: Int, words: Int)
    case quoteNotGrounded(index: Int)
    case duplicateQuestion(first: Int, second: Int)
    // Item-quality (anti-cueing) problems: the choice *shape* leaks the answer, or a
    // distractor is junk rather than a plausible misread.
    case choicesImbalanced(index: Int)                          // longest choice dwarfs shortest
    case bannedChoicePhrase(index: Int, key: ChoiceKey)         // "all/none of the above"
    case unsupportedAbsolute(index: Int, key: ChoiceKey, word: String)  // extreme word absent from source
    case choiceTooShort(index: Int, key: ChoiceKey)             // trivially short / junk filler
}

public enum ComprehensionValidation {
    public static let minQuoteWords = 8
    public static let maxQuoteWords = 40

    /// A distractor under this many characters reads as junk filler, not a plausible
    /// misunderstanding — the longest choice must not exceed `maxChoiceLengthRatio`× the
    /// shortest, so the right answer can't be picked out by being conspicuously detailed.
    public static let minChoiceChars = 3
    public static let maxChoiceLengthRatio = 1.8
    /// Extreme absolutes are allowed only when the *source* itself uses the word; an
    /// unsupported "never"/"always" is a classic giveaway-or-overreach distractor flaw.
    public static let absoluteWords: Set<String> = [
        "always", "never", "completely", "only", "guarantees", "eliminates",
    ]
    public static let bannedChoicePhrases = ["all of the above", "none of the above"]

    public static func validate(
        _ draft: ComprehensionCheckDraft, requestedCount: Int, sourceText: String
    ) -> [ComprehensionValidationError] {
        var errors: [ComprehensionValidationError] = []

        guard draft.questions.count == requestedCount else {
            return [.wrongCount(got: draft.questions.count, want: requestedCount)]
        }

        let normalizedSource = QuoteNormalize.normalize(sourceText)
        let sourceWords = Set(words(of: sourceText))
        var seenQuestions: [(index: Int, text: String)] = []

        for (i, q) in draft.questions.enumerated() {
            if q.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyQuestion(index: i))
            }
            if q.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyExplanation(index: i))
            }
            for key in ChoiceKey.allCases where
                q.choices.text(for: key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyChoice(index: i, key: key))
            }
            // Duplicate choices (normalized, so "Same" == "same.").
            let normChoices = q.choices.all.map { QuoteNormalize.normalize($0) }
            if Set(normChoices).count != normChoices.count {
                errors.append(.duplicateChoices(index: i))
            }
            // Item-quality (anti-cueing): no choice should give the answer away by shape.
            let keyedChoices = ChoiceKey.allCases.map { (key: $0, text: q.choices.text(for: $0)) }
            for (key, text) in keyedChoices {
                let norm = QuoteNormalize.normalize(text)
                if norm.count < minChoiceChars {
                    errors.append(.choiceTooShort(index: i, key: key))
                }
                let lower = norm.lowercased()
                if bannedChoicePhrases.contains(where: { lower.contains($0) }) {
                    errors.append(.bannedChoicePhrase(index: i, key: key))
                }
                // Extreme absolutes are flaws only when the source doesn't back them up.
                for word in Set(words(of: text)) where
                    absoluteWords.contains(word) && !sourceWords.contains(word) {
                    errors.append(.unsupportedAbsolute(index: i, key: key, word: word))
                }
            }
            // Length giveaway: the correct answer must not be the conspicuously long one.
            let lengths = normChoices.map(\.count)
            if let lo = lengths.min(), let hi = lengths.max(), lo > 0,
               Double(hi) / Double(lo) > maxChoiceLengthRatio {
                errors.append(.choicesImbalanced(index: i))
            }
            // Quote length (word count after normalization).
            let normQuote = QuoteNormalize.normalize(q.supportingQuote)
            let words = normQuote.isEmpty ? 0
                : normQuote.split(separator: " ").count
            if words < minQuoteWords || words > maxQuoteWords {
                errors.append(.quoteWrongLength(index: i, words: words))
            } else if !normalizedSource.contains(normQuote) {
                errors.append(.quoteNotGrounded(index: i))
            }
            // Duplicate questions (normalized text).
            let normQ = QuoteNormalize.normalize(q.question)
            if let prior = seenQuestions.first(where: { $0.text == normQ }) {
                errors.append(.duplicateQuestion(first: prior.index, second: i))
            } else {
                seenQuestions.append((i, normQ))
            }
        }
        return errors
    }

    /// Lowercased alphanumeric word tokens, for whole-word membership tests
    /// (so "only" matches the word, never the tail of "commonly").
    private static func words(of s: String) -> [String] {
        QuoteNormalize.normalize(s).lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
