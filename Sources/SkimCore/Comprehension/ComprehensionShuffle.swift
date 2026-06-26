import Foundation

/// Randomises answer order so the correct choice isn't always slot `a` (the model's
/// habit) — a positional tell would let a reader pass without keeping the thread.
/// Runs *after* validation, so duplicate-free choices are guaranteed and the correct
/// text is locatable again. Pure and generic over the RNG so `CoreChecks` can seed it.
public enum ComprehensionShuffle {
    /// Reorder one question's four choices and remap `correctChoice` to wherever the
    /// correct text landed. Every other field is carried through untouched.
    public static func shuffled<R: RandomNumberGenerator>(
        _ draft: ComprehensionQuestionDraft, using rng: inout R
    ) -> ComprehensionQuestionDraft {
        let correctText = draft.choices.text(for: draft.correctChoice)
        let order = ChoiceKey.allCases.map { draft.choices.text(for: $0) }.shuffled(using: &rng)
        let choices = ComprehensionChoices(a: order[0], b: order[1], c: order[2], d: order[3])
        // Validation has already rejected duplicate choices, so the correct text is unique.
        let correct = ChoiceKey.allCases[order.firstIndex(of: correctText) ?? 0]
        return ComprehensionQuestionDraft(
            question: draft.question, choices: choices, correctChoice: correct,
            explanation: draft.explanation, supportingQuote: draft.supportingQuote,
            type: draft.type, testedInsight: draft.testedInsight,
            distractorRationales: draft.distractorRationales)
    }

    /// Shuffle every question in a batch.
    public static func shuffled<R: RandomNumberGenerator>(
        _ draft: ComprehensionCheckDraft, using rng: inout R
    ) -> ComprehensionCheckDraft {
        ComprehensionCheckDraft(questions: draft.questions.map { shuffled($0, using: &rng) })
    }
}
