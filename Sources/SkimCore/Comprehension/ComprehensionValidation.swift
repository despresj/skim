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
}

public enum ComprehensionValidation {
    public static let minQuoteWords = 8
    public static let maxQuoteWords = 40

    public static func validate(
        _ draft: ComprehensionCheckDraft, requestedCount: Int, sourceText: String
    ) -> [ComprehensionValidationError] {
        var errors: [ComprehensionValidationError] = []

        guard draft.questions.count == requestedCount else {
            return [.wrongCount(got: draft.questions.count, want: requestedCount)]
        }

        let normalizedSource = QuoteNormalize.normalize(sourceText)
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
}
