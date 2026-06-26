import Foundation

/// The four answer slots of a multiple-choice comprehension question.
public enum ChoiceKey: String, Codable, Sendable, CaseIterable {
    case a, b, c, d
}

/// What a question probes. Raw values are snake_case to match the model's JSON
/// and the on-disk `type` column.
public enum QuestionType: String, Codable, Sendable, CaseIterable {
    case mainPoint = "main_point"
    case supportingDetail = "supporting_detail"
    case implication
    case pressureTest = "pressure_test"
}

/// Whether a stored batch is the read's first check or a user-requested follow-up.
public enum ComprehensionGenerationKind: String, Codable, Sendable {
    case initial
    case generateMore = "generate_more"
}

/// A read's comprehension state, derived from its stored checks/answers.
public enum ComprehensionStatus: String, Codable, Sendable {
    case unavailable        // too short, or AI disabled
    case notStarted = "not_started"
    case generating
    case ready
    case answered
    case failed
}

/// The four answer texts for one question.
public struct ComprehensionChoices: Codable, Equatable, Sendable {
    public let a: String
    public let b: String
    public let c: String
    public let d: String

    public init(a: String, b: String, c: String, d: String) {
        self.a = a; self.b = b; self.c = c; self.d = d
    }

    public func text(for key: ChoiceKey) -> String {
        switch key {
        case .a: return a
        case .b: return b
        case .c: return c
        case .d: return d
        }
    }

    public var all: [String] { [a, b, c, d] }
}

/// One question exactly as the model returns it — no identity, no UI state.
/// This is what `ComprehensionValidation` checks before we mint persisted rows.
public struct ComprehensionQuestionDraft: Codable, Equatable, Sendable {
    public let question: String
    public let choices: ComprehensionChoices
    public let correctChoice: ChoiceKey
    public let explanation: String
    public let supportingQuote: String
    public let type: QuestionType
    /// Internal item-writing diagnostics — what understanding the item probes, and why
    /// each distractor is tempting-but-wrong. Requested from the model to force it to
    /// *reason about* the distractors (which lifts their quality); logged on rejection,
    /// not shown to the reader and not persisted in V0. Decoded leniently so an omitted
    /// field never fails the parse.
    public let testedInsight: String
    public let distractorRationales: [String]

    public init(question: String, choices: ComprehensionChoices, correctChoice: ChoiceKey,
                explanation: String, supportingQuote: String, type: QuestionType,
                testedInsight: String = "", distractorRationales: [String] = []) {
        self.question = question
        self.choices = choices
        self.correctChoice = correctChoice
        self.explanation = explanation
        self.supportingQuote = supportingQuote
        self.type = type
        self.testedInsight = testedInsight
        self.distractorRationales = distractorRationales
    }

    enum CodingKeys: String, CodingKey {
        case question, choices, correctChoice, explanation, supportingQuote, type
        case testedInsight, distractorRationales
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try c.decode(String.self, forKey: .question)
        choices = try c.decode(ComprehensionChoices.self, forKey: .choices)
        correctChoice = try c.decode(ChoiceKey.self, forKey: .correctChoice)
        explanation = try c.decode(String.self, forKey: .explanation)
        supportingQuote = try c.decode(String.self, forKey: .supportingQuote)
        type = try c.decode(QuestionType.self, forKey: .type)
        testedInsight = try c.decodeIfPresent(String.self, forKey: .testedInsight) ?? ""
        distractorRationales = try c.decodeIfPresent([String].self, forKey: .distractorRationales) ?? []
    }
}

/// The model's full structured response: a flat list of question drafts.
public struct ComprehensionCheckDraft: Codable, Equatable, Sendable {
    public let questions: [ComprehensionQuestionDraft]
    public init(questions: [ComprehensionQuestionDraft]) { self.questions = questions }
}

/// A persisted question: a validated draft plus identity, optional source span,
/// and the "this seems off" dispute flag.
public struct ComprehensionQuestion: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let question: String
    public let choices: ComprehensionChoices
    public let correctChoice: ChoiceKey
    public let explanation: String
    public let supportingQuote: String
    public let type: QuestionType
    public var sourceStartTokenIndex: Int?
    public var sourceEndTokenIndex: Int?
    public var disputed: Bool

    public init(id: UUID = UUID(), question: String, choices: ComprehensionChoices,
                correctChoice: ChoiceKey, explanation: String, supportingQuote: String,
                type: QuestionType, sourceStartTokenIndex: Int? = nil,
                sourceEndTokenIndex: Int? = nil, disputed: Bool = false) {
        self.id = id
        self.question = question
        self.choices = choices
        self.correctChoice = correctChoice
        self.explanation = explanation
        self.supportingQuote = supportingQuote
        self.type = type
        self.sourceStartTokenIndex = sourceStartTokenIndex
        self.sourceEndTokenIndex = sourceEndTokenIndex
        self.disputed = disputed
    }

    /// Mint a persisted question from a validated draft.
    public init(draft: ComprehensionQuestionDraft, id: UUID = UUID()) {
        self.init(id: id, question: draft.question, choices: draft.choices,
                  correctChoice: draft.correctChoice, explanation: draft.explanation,
                  supportingQuote: draft.supportingQuote, type: draft.type)
    }
}

/// One generated batch of questions for a read — the unit we cache and persist.
public struct ComprehensionCheck: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let readId: String
    public let textHash: String
    public let model: String
    public let promptVersion: Int
    public let generatedAt: Date
    public let kind: ComprehensionGenerationKind
    public let parentCheckId: UUID?
    public let batchIndex: Int
    public var questions: [ComprehensionQuestion]
    public var completedAt: Date?
    public var score: Int?

    public init(id: UUID = UUID(), readId: String, textHash: String, model: String,
                promptVersion: Int, generatedAt: Date, kind: ComprehensionGenerationKind,
                parentCheckId: UUID? = nil, batchIndex: Int = 0,
                questions: [ComprehensionQuestion], completedAt: Date? = nil, score: Int? = nil) {
        self.id = id
        self.readId = readId
        self.textHash = textHash
        self.model = model
        self.promptVersion = promptVersion
        self.generatedAt = generatedAt
        self.kind = kind
        self.parentCheckId = parentCheckId
        self.batchIndex = batchIndex
        self.questions = questions
        self.completedAt = completedAt
        self.score = score
    }
}
