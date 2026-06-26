import Foundation

/// The pure rules behind a comprehension check: how many questions a read earns,
/// which question types fill those slots, whether a read is eligible for silent
/// background pre-generation, and the cache keys that make `promptVersion` bumps
/// invalidate stale questions. No I/O, no model calls.
public enum QuestionPlan {
    /// Bump whenever the prompt, schema, validation, or question mix changes, so
    /// old cached questions stop being served as if still valid.
    public static let currentPromptVersion = 1

    /// The floor for a check to exist at all — also the floor for background
    /// pre-generation, so any read that can have a check pre-generates on load.
    public static let minWordCount = 150
    /// The 1-question → 2-question boundary (not a pre-gen gate).
    public static let twoQuestionWordCount = 350
    public static let generateMoreCount = 3
    public static let softCap = 8
    public static let hardCap = 12

    /// Words → initial question count. `0` means "too short for a check".
    public static func initialQuestionCount(wordCount: Int) -> Int {
        switch wordCount {
        case ..<minWordCount: return 0
        case minWordCount..<twoQuestionWordCount: return 1
        case twoQuestionWordCount..<900: return 2
        case 900..<2000: return 3
        default: return 5
        }
    }

    /// The type allocation for an initial check of `count` questions.
    public static func types(forCount count: Int) -> [QuestionType] {
        switch count {
        case ..<1: return []
        case 1: return [.mainPoint]
        case 2: return [.mainPoint, .supportingDetail]
        case 3: return [.mainPoint, .supportingDetail, .implication]
        case 4: return [.mainPoint, .supportingDetail, .supportingDetail, .implication]
        default: return [.mainPoint, .supportingDetail, .supportingDetail, .implication, .implication]
        }
    }

    /// The deeper mix used when the user asks for more questions.
    public static func generateMoreTypes() -> [QuestionType] {
        [.supportingDetail, .implication, .pressureTest]
    }

    /// Whether to silently start background generation on paste/import. Fires for
    /// any read long enough to earn a check (`>= minWordCount`). Requires consent
    /// to be *already* accepted — pre-gen never raises a consent modal.
    public static func shouldPreGenerate(
        wordCount: Int, aiEnabled: Bool, consentAccepted: Bool,
        hasKey: Bool, hasInitialCheck: Bool
    ) -> Bool {
        wordCount >= minWordCount
            && aiEnabled && consentAccepted && hasKey && !hasInitialCheck
    }

    public static func initialCacheKey(textHash: String, model: String, promptVersion: Int) -> String {
        "\(textHash)|\(model)|\(promptVersion)"
    }

    public static func generateMoreCacheKey(
        parentCheckId: UUID, model: String, promptVersion: Int, batchIndex: Int
    ) -> String {
        "\(parentCheckId.uuidString)|\(model)|\(promptVersion)|\(batchIndex)"
    }
}
