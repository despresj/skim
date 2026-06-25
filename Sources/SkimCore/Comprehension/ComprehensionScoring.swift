import Foundation

/// The outcome of a completed check: how many of the *scorable* questions were
/// right, plus the calm, non-accusatory headline and speed suggestion to show.
public struct ComprehensionResult: Equatable, Sendable {
    public let correct: Int
    public let scored: Int          // denominator: non-disputed, answered questions
    public let percent: Double      // 0...1, 0 when nothing scored
    public let headline: String
    public let guidance: String

    public init(correct: Int, scored: Int, percent: Double, headline: String, guidance: String) {
        self.correct = correct
        self.scored = scored
        self.percent = percent
        self.headline = headline
        self.guidance = guidance
    }
}

/// Turns answers into a result. A question is scored only if it's not disputed
/// and has an answer, so a hallucinated ("this seems off") item can never push a
/// false "too fast". The guidance is a suggestion — V0 never changes speed.
public enum ComprehensionScoring {
    public static func result(
        questions: [ComprehensionQuestion], answers: [UUID: ChoiceKey]
    ) -> ComprehensionResult {
        let scorable = questions.filter { !$0.disputed && answers[$0.id] != nil }
        let scored = scorable.count
        let correct = scorable.filter { answers[$0.id] == $0.correctChoice }.count

        guard scored > 0 else {
            return ComprehensionResult(correct: 0, scored: 0, percent: 0,
                                       headline: "Nothing scored yet.", guidance: "")
        }
        let percent = Double(correct) / Double(scored)
        let headline: String
        let guidance: String
        if correct == scored {
            headline = "Clean comprehension."
            guidance = "Your current speed looks good for this kind of text."
        } else if percent <= 1.0 / 3.0 {
            headline = "Thread got shaky."
            guidance = "This one may have been too fast. Try dropping 50\u{2013}100 WPM on similar text."
        } else {
            headline = "Mostly kept the thread."
            guidance = "Consider slowing slightly for dense reads."
        }
        return ComprehensionResult(correct: correct, scored: scored, percent: percent,
                                   headline: headline, guidance: guidance)
    }
}
