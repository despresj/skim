# Comprehension Checks — Core & Storage Implementation Plan (Plan 1 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure, fully-tested foundation for BYOK comprehension checks — models, question-planning, quote normalization, response validation, long-read chunking, scoring, the SQLite tables + CRUD, and the API-key-store protocol — entirely inside `SkimCore`, verified by `CoreChecks`.

**Architecture:** Everything in this plan lives in `Sources/SkimCore` (Foundation + SQLite only, zero UI) so it compiles with `swift build` and is exercised by the `CoreChecks` executable on macOS without Xcode. The OpenAI provider, Keychain implementation, view models, and SwiftUI come in **Plan 2** and consume the interfaces produced here. Design spec: `docs/superpowers/specs/2026-06-25-comprehension-checks-design.md`.

**Tech Stack:** Swift 6 (strict concurrency), Foundation, SQLite3 C API (as already used by `SkimStore`), the hand-rolled `CoreChecks` harness (`expect`/`expectEqual`/`expectClose`).

## Global Constraints

- **Swift 6, strict concurrency.** New core types are `public` and `Sendable` where they hold only value data.
- **`SkimCore` stays pure:** no `UIKit`/`SwiftUI`/`Foundation`-UI imports. (`import Foundation` / `import SQLite3` only.)
- **Every core behavior change adds a matching `CoreChecks` assertion** in `Sources/CoreChecks/main.swift`, in the same task.
- **Verification command for every task:** `swift build && swift run CoreChecks` — must end with `All checks passed ✅` (exit 0).
- **`promptVersion` is part of both cache keys.** Current value: `QuestionPlan.currentPromptVersion = 1`.
- **Thresholds (verbatim):** `<150` words → no check; `150–349` → 1 question (manual only); `350–900` → 2; `900–2,000` → 3; `2,000–4,000` → 5; `4,000+` → 5. Auto pre-gen requires `≥350`.
- **Quote grounding:** `supportingQuote` is 8–40 words and must be a *normalized* substring of the source.
- **Score copy (verbatim):** 100% → "Clean comprehension." / "Your current speed looks good for this kind of text." · ~67% → "Mostly kept the thread." / "Consider slowing slightly for dense reads." · ≤33% → "Thread got shaky." / "This one may have been too fast. Try dropping 50–100 WPM on similar text."
- **Naming:** raw values are snake_case to match on-disk style (`generate_more`, `not_started`, `main_point`, `supporting_detail`, `pressure_test`).
- **No developer-owned API key anywhere in the repo** (enforced fully in Plan 2; this plan adds only the protocol + an in-memory test double).

---

### Task 1: Comprehension domain models

**Files:**
- Create: `Sources/SkimCore/Comprehension/Models.swift`
- Test: append a `Comprehension Models` section to `Sources/CoreChecks/main.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (relied on by every later task and by Plan 2):
  - `enum ChoiceKey: String, Codable, Sendable, CaseIterable { case a, b, c, d }`
  - `enum QuestionType: String, Codable, Sendable, CaseIterable` — `mainPoint="main_point"`, `supportingDetail="supporting_detail"`, `implication`, `pressureTest="pressure_test"`
  - `enum ComprehensionGenerationKind: String, Codable, Sendable { case initial; case generateMore = "generate_more" }`
  - `enum ComprehensionStatus: String, Codable, Sendable { case unavailable; case notStarted = "not_started"; case generating; case ready; case answered; case failed }`
  - `struct ComprehensionChoices: Codable, Equatable, Sendable` with `let a,b,c,d: String`, `func text(for: ChoiceKey) -> String`, `var all: [String]`
  - `struct ComprehensionQuestionDraft: Codable, Equatable, Sendable` — the raw model output: `question, choices, correctChoice, explanation, supportingQuote, type`
  - `struct ComprehensionCheckDraft: Codable, Equatable, Sendable { let questions: [ComprehensionQuestionDraft] }`
  - `struct ComprehensionQuestion: Identifiable, Codable, Equatable, Sendable` — persisted question: `id: UUID, question, choices, correctChoice, explanation, supportingQuote, type, sourceStartTokenIndex: Int?, sourceEndTokenIndex: Int?, disputed: Bool`
  - `struct ComprehensionCheck: Identifiable, Codable, Equatable, Sendable` — persisted batch: `id: UUID, readId: String, textHash: String, model: String, promptVersion: Int, generatedAt: Date, kind: ComprehensionGenerationKind, parentCheckId: UUID?, batchIndex: Int, questions: [ComprehensionQuestion], completedAt: Date?, score: Int?`

- [ ] **Step 1: Write the failing test** — append to the end of `Sources/CoreChecks/main.swift` (before the final `print("")` / failures block):

```swift
print("Comprehension Models")
do {
    expectEqual(ChoiceKey.allCases.count, 4, "four choice keys")
    expectEqual(QuestionType.mainPoint.rawValue, "main_point", "main_point raw value")
    expectEqual(QuestionType.supportingDetail.rawValue, "supporting_detail", "supporting_detail raw value")
    expectEqual(QuestionType.pressureTest.rawValue, "pressure_test", "pressure_test raw value")
    expectEqual(ComprehensionGenerationKind.generateMore.rawValue, "generate_more", "generate_more raw value")
    expectEqual(ComprehensionStatus.notStarted.rawValue, "not_started", "not_started raw value")

    let choices = ComprehensionChoices(a: "alpha", b: "bravo", c: "charlie", d: "delta")
    expectEqual(choices.text(for: .c), "charlie", "choices.text(for:) reads the right slot")
    expectEqual(choices.all, ["alpha", "bravo", "charlie", "delta"], "choices.all is a..d in order")

    // A draft decoded from the exact JSON shape the model returns.
    let json = """
    {"questions":[{"question":"Q?","choices":{"a":"A","b":"B","c":"C","d":"D"},
      "correctChoice":"b","explanation":"because B.","supportingQuote":"the supporting words here",
      "type":"main_point"}]}
    """.data(using: .utf8)!
    let draft = try! JSONDecoder().decode(ComprehensionCheckDraft.self, from: json)
    expectEqual(draft.questions.count, 1, "draft decodes one question")
    expectEqual(draft.questions[0].correctChoice, .b, "draft decodes correctChoice")
    expectEqual(draft.questions[0].type, .mainPoint, "draft decodes type from snake_case")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build`
Expected: FAIL — `cannot find 'ChoiceKey' in scope` (and the other new types).

- [ ] **Step 3: Write minimal implementation** — create `Sources/SkimCore/Comprehension/Models.swift`:

```swift
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

    public init(question: String, choices: ComprehensionChoices, correctChoice: ChoiceKey,
                explanation: String, supportingQuote: String, type: QuestionType) {
        self.question = question
        self.choices = choices
        self.correctChoice = correctChoice
        self.explanation = explanation
        self.supportingQuote = supportingQuote
        self.type = type
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift run CoreChecks`
Expected: PASS — section prints `✓` lines; run ends `All checks passed ✅`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkimCore/Comprehension/Models.swift Sources/CoreChecks/main.swift
git commit -m "feat(core): comprehension-check domain models"
```

---

### Task 2: Question planning (counts, types, eligibility, cache keys)

**Files:**
- Create: `Sources/SkimCore/Comprehension/QuestionPlan.swift`
- Test: append a `QuestionPlan` section to `Sources/CoreChecks/main.swift`

**Interfaces:**
- Consumes: `QuestionType` (Task 1).
- Produces:
  - `enum QuestionPlan` with:
    - `static let currentPromptVersion = 1`
    - `static let minWordCount = 150`, `autoPreGenWordCount = 350`
    - `static let generateMoreCount = 3`, `softCap = 8`, `hardCap = 12`
    - `static func initialQuestionCount(wordCount: Int) -> Int`
    - `static func types(forCount: Int) -> [QuestionType]`
    - `static func generateMoreTypes() -> [QuestionType]`
    - `static func shouldPreGenerate(wordCount: Int, aiEnabled: Bool, consentAccepted: Bool, hasKey: Bool, hasInitialCheck: Bool) -> Bool`
    - `static func initialCacheKey(textHash: String, model: String, promptVersion: Int) -> String`
    - `static func generateMoreCacheKey(parentCheckId: UUID, model: String, promptVersion: Int, batchIndex: Int) -> String`

- [ ] **Step 1: Write the failing test** — append to `Sources/CoreChecks/main.swift`:

```swift
print("QuestionPlan")
do {
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 149), 0, "<150 → no check")
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 150), 1, "150 → 1 (manual)")
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 349), 1, "349 → 1")
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 350), 2, "350 → 2")
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 900), 3, "900 → 3")
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 1999), 3, "1999 → 3")
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 2000), 5, "2000 → 5")
    expectEqual(QuestionPlan.initialQuestionCount(wordCount: 50000), 5, "huge → 5")

    expectEqual(QuestionPlan.types(forCount: 1), [.mainPoint], "1 → main point")
    expectEqual(QuestionPlan.types(forCount: 2), [.mainPoint, .supportingDetail], "2 → main+support")
    expectEqual(QuestionPlan.types(forCount: 3), [.mainPoint, .supportingDetail, .implication], "3 → +implication")
    expectEqual(QuestionPlan.types(forCount: 5),
                [.mainPoint, .supportingDetail, .supportingDetail, .implication, .implication],
                "5 → main, 2x support, 2x implication")
    expectEqual(QuestionPlan.generateMoreTypes(),
                [.supportingDetail, .implication, .pressureTest], "generate-more mix")

    // Eligibility: all four flags AND ≥350 words AND no existing initial check.
    expect(QuestionPlan.shouldPreGenerate(wordCount: 350, aiEnabled: true, consentAccepted: true,
            hasKey: true, hasInitialCheck: false), "eligible when all conditions hold")
    expect(!QuestionPlan.shouldPreGenerate(wordCount: 349, aiEnabled: true, consentAccepted: true,
            hasKey: true, hasInitialCheck: false), "349 words is below auto threshold")
    expect(!QuestionPlan.shouldPreGenerate(wordCount: 350, aiEnabled: false, consentAccepted: true,
            hasKey: true, hasInitialCheck: false), "AI disabled blocks pre-gen")
    expect(!QuestionPlan.shouldPreGenerate(wordCount: 350, aiEnabled: true, consentAccepted: false,
            hasKey: true, hasInitialCheck: false), "missing consent blocks pre-gen (no modal on paste)")
    expect(!QuestionPlan.shouldPreGenerate(wordCount: 350, aiEnabled: true, consentAccepted: true,
            hasKey: false, hasInitialCheck: false), "missing key blocks pre-gen")
    expect(!QuestionPlan.shouldPreGenerate(wordCount: 350, aiEnabled: true, consentAccepted: true,
            hasKey: true, hasInitialCheck: true), "existing check blocks duplicate pre-gen")

    expectEqual(QuestionPlan.initialCacheKey(textHash: "abc", model: "m1", promptVersion: 1),
                "abc|m1|1", "initial cache key includes promptVersion")
    let pid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    expectEqual(QuestionPlan.generateMoreCacheKey(parentCheckId: pid, model: "m1", promptVersion: 1, batchIndex: 2),
                "00000000-0000-0000-0000-000000000001|m1|1|2", "generate-more key shape")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build`
Expected: FAIL — `cannot find 'QuestionPlan' in scope`.

- [ ] **Step 3: Write minimal implementation** — create `Sources/SkimCore/Comprehension/QuestionPlan.swift`:

```swift
import Foundation

/// The pure rules behind a comprehension check: how many questions a read earns,
/// which question types fill those slots, whether a read is eligible for silent
/// background pre-generation, and the cache keys that make `promptVersion` bumps
/// invalidate stale questions. No I/O, no model calls.
public enum QuestionPlan {
    /// Bump whenever the prompt, schema, validation, or question mix changes, so
    /// old cached questions stop being served as if still valid.
    public static let currentPromptVersion = 1

    public static let minWordCount = 150
    public static let autoPreGenWordCount = 350
    public static let generateMoreCount = 3
    public static let softCap = 8
    public static let hardCap = 12

    /// Words → initial question count. `0` means "too short for a check".
    public static func initialQuestionCount(wordCount: Int) -> Int {
        switch wordCount {
        case ..<minWordCount: return 0
        case minWordCount..<autoPreGenWordCount: return 1   // manual-only
        case autoPreGenWordCount..<900: return 2
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

    /// Whether to silently start background generation on paste/import. Requires
    /// consent to be *already* accepted — pre-gen never raises a consent modal.
    public static func shouldPreGenerate(
        wordCount: Int, aiEnabled: Bool, consentAccepted: Bool,
        hasKey: Bool, hasInitialCheck: Bool
    ) -> Bool {
        wordCount >= autoPreGenWordCount
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift run CoreChecks`
Expected: PASS — `All checks passed ✅`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkimCore/Comprehension/QuestionPlan.swift Sources/CoreChecks/main.swift
git commit -m "feat(core): comprehension question planning + eligibility + cache keys"
```

---

### Task 3: Quote normalization

**Files:**
- Create: `Sources/SkimCore/Comprehension/QuoteNormalize.swift`
- Test: append a `QuoteNormalize` section to `Sources/CoreChecks/main.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum QuoteNormalize { static func normalize(_ s: String) -> String }` — maps curly quotes → straight, dash variants → `-`, NBSP/unicode spaces → space, collapses whitespace runs, trims leading/trailing whitespace and punctuation. Idempotent.

- [ ] **Step 1: Write the failing test** — append to `Sources/CoreChecks/main.swift`:

```swift
print("QuoteNormalize")
do {
    // Curly quotes and apostrophes → straight.
    expectEqual(QuoteNormalize.normalize("the \u{201C}data\u{201D} pipeline\u{2019}s edge"),
                "the \"data\" pipeline's edge", "curly quotes/apostrophes normalized")
    // En/em dash and minus → hyphen.
    expectEqual(QuoteNormalize.normalize("a\u{2014}b \u{2013} c \u{2212}d"), "a-b - c -d", "dash variants → hyphen")
    // NBSP and newlines and tabs collapse to single spaces.
    expectEqual(QuoteNormalize.normalize("the\u{00A0}data\tpipeline\n\nchanged"),
                "the data pipeline changed", "nbsp/tab/newline collapse")
    // Leading/trailing whitespace and punctuation trimmed.
    expectEqual(QuoteNormalize.normalize("  ...the pipeline changed.  "),
                "the pipeline changed", "edge punctuation/space trimmed")
    // Idempotence: normalizing twice equals normalizing once.
    let once = QuoteNormalize.normalize("  \u{201C}A\u{2014}B\u{201D}  pipeline\u{00A0}edge. ")
    expectEqual(QuoteNormalize.normalize(once), once, "normalize is idempotent")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build`
Expected: FAIL — `cannot find 'QuoteNormalize' in scope`.

- [ ] **Step 3: Write minimal implementation** — create `Sources/SkimCore/Comprehension/QuoteNormalize.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift run CoreChecks`
Expected: PASS — `All checks passed ✅`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkimCore/Comprehension/QuoteNormalize.swift Sources/CoreChecks/main.swift
git commit -m "feat(core): typography-tolerant quote normalization"
```

---

### Task 4: Draft validation

**Files:**
- Create: `Sources/SkimCore/Comprehension/ComprehensionValidation.swift`
- Test: append a `ComprehensionValidation` section to `Sources/CoreChecks/main.swift`

**Interfaces:**
- Consumes: `ComprehensionCheckDraft`, `ComprehensionQuestionDraft`, `ComprehensionChoices`, `ChoiceKey`, `QuestionType` (Task 1); `QuoteNormalize.normalize` (Task 3).
- Produces:
  - `enum ComprehensionValidationError: Error, Equatable` with cases: `wrongCount(got: Int, want: Int)`, `emptyQuestion(index: Int)`, `emptyChoice(index: Int, key: ChoiceKey)`, `duplicateChoices(index: Int)`, `emptyExplanation(index: Int)`, `quoteWrongLength(index: Int, words: Int)`, `quoteNotGrounded(index: Int)`, `duplicateQuestion(first: Int, second: Int)`
  - `enum ComprehensionValidation { static let minQuoteWords = 8; static let maxQuoteWords = 40; static func validate(_ draft: ComprehensionCheckDraft, requestedCount: Int, sourceText: String) -> [ComprehensionValidationError] }` — empty array means valid.

- [ ] **Step 1: Write the failing test** — append to `Sources/CoreChecks/main.swift`:

```swift
print("ComprehensionValidation")
do {
    let source = """
    Skim helps users finish long text faster without feeling lost. If getting text into the
    app is not instant, it becomes a cool demo instead of a daily reflex that people reach for.
    """
    func q(_ quote: String,
           choices: ComprehensionChoices = .init(a: "one", b: "two", c: "three", d: "four"),
           question: String = "What is the main point?",
           explanation: String = "Because the passage says so.") -> ComprehensionQuestionDraft {
        .init(question: question, choices: choices, correctChoice: .a,
              explanation: explanation, supportingQuote: quote, type: .mainPoint)
    }

    // A clean, grounded, right-length quote (10 words) passes. It's a contiguous
    // prefix of the source, ending just before the first period.
    let good = ComprehensionCheckDraft(questions: [q("Skim helps users finish long text faster without feeling lost")])
    expect(ComprehensionValidation.validate(good, requestedCount: 1, sourceText: source).isEmpty,
           "valid grounded draft passes")

    // A real excerpt with a non-breaking space spliced in still grounds — the NBSP
    // normalizes to a regular space before the substring check.
    let typo = ComprehensionCheckDraft(questions: [q("becomes a cool demo instead of a daily\u{00A0}reflex that people reach for")])
    expect(ComprehensionValidation.validate(typo, requestedCount: 1, sourceText: source).isEmpty,
           "typography-tolerant grounding accepts a real excerpt")

    // Wrong count.
    expectEqual(ComprehensionValidation.validate(good, requestedCount: 2, sourceText: source).first,
                .wrongCount(got: 1, want: 2), "rejects wrong count")

    // Fabricated quote (not in source).
    let fake = ComprehensionCheckDraft(questions: [q("the quick brown fox jumped over the lazy sleeping dog twice")])
    expectEqual(ComprehensionValidation.validate(fake, requestedCount: 1, sourceText: source).first,
                .quoteNotGrounded(index: 0), "rejects ungrounded quote")

    // Too-short quote (3 words).
    let short = ComprehensionCheckDraft(questions: [q("Skim helps users")])
    expectEqual(ComprehensionValidation.validate(short, requestedCount: 1, sourceText: source).first,
                .quoteWrongLength(index: 0, words: 3), "rejects sub-8-word quote")

    // Duplicate answer choices within a question.
    let dupChoice = ComprehensionCheckDraft(questions: [q(
        "Skim helps users finish long text faster without feeling lost",
        choices: .init(a: "same", b: "same", c: "x", d: "y"))])
    expectEqual(ComprehensionValidation.validate(dupChoice, requestedCount: 1, sourceText: source).first,
                .duplicateChoices(index: 0), "rejects duplicate choices")

    // Duplicate questions across the set.
    let g = q("Skim helps users finish long text faster without feeling lost")
    let dupQ = ComprehensionCheckDraft(questions: [g, g])
    expectEqual(ComprehensionValidation.validate(dupQ, requestedCount: 2, sourceText: source).first,
                .duplicateQuestion(first: 0, second: 1), "rejects duplicate questions")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build`
Expected: FAIL — `cannot find 'ComprehensionValidation' in scope`.

- [ ] **Step 3: Write minimal implementation** — create `Sources/SkimCore/Comprehension/ComprehensionValidation.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift run CoreChecks`
Expected: PASS — `All checks passed ✅`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkimCore/Comprehension/ComprehensionValidation.swift Sources/CoreChecks/main.swift
git commit -m "feat(core): comprehension draft validation with grounded-quote check"
```

---

### Task 5: Long-read chunk sampling

**Files:**
- Create: `Sources/SkimCore/Comprehension/ComprehensionChunking.swift`
- Test: append a `ComprehensionChunking` section to `Sources/CoreChecks/main.swift`

**Interfaces:**
- Consumes: nothing (operates on raw text).
- Produces:
  - `enum ComprehensionChunking` with `static let fullTextWordLimit = 4000`, `static let targetChunkWords = 600`, `static let sampleCount = 5`, `static func wordCount(_ text: String) -> Int`, `static func sampleForGeneration(_ text: String) -> String`.
- Behavior: `≤4000` words → returns the text unchanged. `>4000` → returns up to 5 paragraph-aligned excerpts (begin / early-middle / middle / late-middle / end), each ~600 words, never cutting mid-sentence, joined by a `\n\n[…]\n\n` separator; total sampled words `< wordCount`.

- [ ] **Step 1: Write the failing test** — append to `Sources/CoreChecks/main.swift`:

```swift
print("ComprehensionChunking")
do {
    let short = "word " + String(repeating: "lorem ", count: 100)   // ~101 words
    expectEqual(ComprehensionChunking.sampleForGeneration(short), short, "short text passes through unchanged")

    // Build a long doc: 200 short paragraphs, ~30 words each ≈ 6000 words.
    let paras = (0..<200).map { p in "Paragraph \(p) " + String(repeating: "alpha beta gamma. ", count: 8) }
    let long = paras.joined(separator: "\n\n")
    expect(ComprehensionChunking.wordCount(long) > ComprehensionChunking.fullTextWordLimit, "long doc exceeds limit")

    let sample = ComprehensionChunking.sampleForGeneration(long)
    expect(sample != long, "long text is sampled, not sent whole")
    expect(ComprehensionChunking.wordCount(sample) < ComprehensionChunking.wordCount(long),
           "sample is smaller than the source")
    expect(sample.contains("Paragraph 0"), "sample includes the beginning")
    expect(sample.contains("Paragraph 199") || sample.contains("Paragraph 198"),
           "sample includes the ending")
    // Whole paragraphs only → it never ends a chunk on a bare 'alpha beta' mid-sentence
    // fragment; every excerpt boundary falls on a paragraph we pulled whole.
    expect(sample.contains("[…]"), "excerpts are joined with an elision marker")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build`
Expected: FAIL — `cannot find 'ComprehensionChunking' in scope`.

- [ ] **Step 3: Write minimal implementation** — create `Sources/SkimCore/Comprehension/ComprehensionChunking.swift`:

```swift
import Foundation

/// Picks what text to send the model. Short reads go whole; long reads are
/// sampled into a handful of paragraph-aligned excerpts spread across the
/// document, so questions still span beginning-to-end without paying to send
/// (or upload) tens of thousands of words. Whole paragraphs are taken, so no
/// excerpt ends mid-sentence.
public enum ComprehensionChunking {
    public static let fullTextWordLimit = 4000
    public static let targetChunkWords = 600
    public static let sampleCount = 5
    private static let elision = "\n\n[…]\n\n"

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    public static func sampleForGeneration(_ text: String) -> String {
        guard wordCount(text) > fullTextWordLimit else { return text }

        let paragraphs = splitParagraphs(text)
        guard paragraphs.count > 1 else {
            // One enormous paragraph: fall back to sentence boundaries.
            return firstSentences(text, targetWords: targetChunkWords)
        }

        // Anchor paragraph indices evenly across the document.
        let anchors = (0..<sampleCount).map { i -> Int in
            guard sampleCount > 1 else { return 0 }
            let frac = Double(i) / Double(sampleCount - 1)        // 0, .25, .5, .75, 1
            return min(paragraphs.count - 1, Int((Double(paragraphs.count - 1) * frac).rounded()))
        }

        var usedIndices = Set<Int>()
        var chunks: [String] = []
        for anchor in anchors {
            var idx = anchor
            // Don't re-emit a paragraph already pulled into a prior chunk.
            while idx < paragraphs.count && usedIndices.contains(idx) { idx += 1 }
            guard idx < paragraphs.count else { continue }
            var words = 0
            var taken: [String] = []
            while idx < paragraphs.count, !usedIndices.contains(idx), words < targetChunkWords {
                taken.append(paragraphs[idx])
                words += wordCount(paragraphs[idx])
                usedIndices.insert(idx)
                idx += 1
            }
            if !taken.isEmpty { chunks.append(taken.joined(separator: "\n\n")) }
        }
        return chunks.joined(separator: elision)
    }

    private static func splitParagraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .split(whereSeparator: { $0.isEmpty })
            .map { $0.joined(separator: " ") }
    }

    /// Take whole sentences from the front until ~targetWords (single-paragraph fallback).
    private static func firstSentences(_ text: String, targetWords: Int) -> String {
        var taken: [String] = []
        var words = 0
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                taken.append(current)
                words += wordCount(current)
                current = ""
                if words >= targetWords { break }
            }
        }
        if words < targetWords, !current.trimmingCharacters(in: .whitespaces).isEmpty {
            taken.append(current)
        }
        return taken.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift run CoreChecks`
Expected: PASS — `All checks passed ✅`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkimCore/Comprehension/ComprehensionChunking.swift Sources/CoreChecks/main.swift
git commit -m "feat(core): long-read chunk sampling for generation input"
```

---

### Task 6: Scoring + speed guidance

**Files:**
- Create: `Sources/SkimCore/Comprehension/ComprehensionScoring.swift`
- Test: append a `ComprehensionScoring` section to `Sources/CoreChecks/main.swift`

**Interfaces:**
- Consumes: `ComprehensionQuestion`, `ChoiceKey` (Task 1).
- Produces:
  - `struct ComprehensionResult: Equatable, Sendable { let correct: Int; let scored: Int; let percent: Double; let headline: String; let guidance: String }`
  - `enum ComprehensionScoring { static func result(questions: [ComprehensionQuestion], answers: [UUID: ChoiceKey]) -> ComprehensionResult }`
- Behavior: denominator = questions that are **not disputed** and **have an answer**; `correct` counts matches; disputed/unanswered questions are excluded. Copy bands: `correct == scored && scored > 0` → top; `percent <= 1.0/3.0` → bottom; else → middle. `scored == 0` → neutral "Nothing scored yet." with empty guidance.

- [ ] **Step 1: Write the failing test** — append to `Sources/CoreChecks/main.swift`:

```swift
print("ComprehensionScoring")
do {
    let choices = ComprehensionChoices(a: "a", b: "b", c: "c", d: "d")
    func mk(_ correct: ChoiceKey, disputed: Bool = false) -> ComprehensionQuestion {
        ComprehensionQuestion(question: "Q", choices: choices, correctChoice: correct,
                              explanation: "e", supportingQuote: "q", type: .mainPoint, disputed: disputed)
    }
    let q1 = mk(.a), q2 = mk(.b), q3 = mk(.c)

    // 3/3 → top band.
    let all = ComprehensionScoring.result(questions: [q1, q2, q3],
                answers: [q1.id: .a, q2.id: .b, q3.id: .c])
    expectEqual(all.correct, 3, "all correct counted")
    expectEqual(all.scored, 3, "all scored")
    expectEqual(all.headline, "Clean comprehension.", "100% headline")

    // 2/3 → middle band.
    let two = ComprehensionScoring.result(questions: [q1, q2, q3],
                answers: [q1.id: .a, q2.id: .b, q3.id: .a])
    expectEqual(two.correct, 2, "two correct")
    expectEqual(two.headline, "Mostly kept the thread.", "~67% headline")

    // 1/3 → bottom band, softened copy (not "Too fast").
    let one = ComprehensionScoring.result(questions: [q1, q2, q3],
                answers: [q1.id: .a, q2.id: .a, q3.id: .a])
    expectEqual(one.headline, "Thread got shaky.", "≤33% headline is softened")
    expect(one.guidance.contains("50–100 WPM"), "≤33% guidance suggests dropping WPM")

    // A disputed wrong answer is excluded from the denominator: 2 correct of 2 scored → top.
    let disputed = mk(.d, disputed: true)
    let withDispute = ComprehensionScoring.result(questions: [q1, q2, disputed],
                answers: [q1.id: .a, q2.id: .b, disputed.id: .a])   // disputed answered wrong
    expectEqual(withDispute.scored, 2, "disputed question excluded from denominator")
    expectEqual(withDispute.headline, "Clean comprehension.", "disputed wrong answer can't force a low score")

    // Nothing answered yet.
    let none = ComprehensionScoring.result(questions: [q1, q2], answers: [:])
    expectEqual(none.scored, 0, "no answers → nothing scored")
    expectEqual(none.headline, "Nothing scored yet.", "neutral headline when unscored")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build`
Expected: FAIL — `cannot find 'ComprehensionScoring' in scope`.

- [ ] **Step 3: Write minimal implementation** — create `Sources/SkimCore/Comprehension/ComprehensionScoring.swift`:

```swift
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
            guidance = "This one may have been too fast. Try dropping 50–100 WPM on similar text."
        } else {
            headline = "Mostly kept the thread."
            guidance = "Consider slowing slightly for dense reads."
        }
        return ComprehensionResult(correct: correct, scored: scored, percent: percent,
                                   headline: headline, guidance: guidance)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift run CoreChecks`
Expected: PASS — `All checks passed ✅`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkimCore/Comprehension/ComprehensionScoring.swift Sources/CoreChecks/main.swift
git commit -m "feat(core): comprehension scoring + calm speed guidance"
```

---

### Task 7: API-key-store protocol + in-memory double

**Files:**
- Create: `Sources/SkimCore/Comprehension/APIKeyStore.swift`
- Test: append an `APIKeyStore` section to `Sources/CoreChecks/main.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `protocol APIKeyStore: AnyObject { func saveOpenAIKey(_ key: String) throws; func loadOpenAIKey() throws -> String?; func deleteOpenAIKey() throws; func hasOpenAIKey() -> Bool }`
  - `final class InMemoryAPIKeyStore: APIKeyStore` — for tests, SwiftUI previews, and the service tests in Plan 2. (The real `KeychainAPIKeyStore` lands in Plan 2, in `App/`.)
  - `extension APIKeyStore { func maskedKey() -> String? }` — returns e.g. `sk-••••••abcd` (last 4 shown) or `nil` if no key.

- [ ] **Step 1: Write the failing test** — append to `Sources/CoreChecks/main.swift`:

```swift
print("APIKeyStore")
do {
    let store = InMemoryAPIKeyStore()
    expect(!store.hasOpenAIKey(), "starts empty")
    expectEqual(try! store.loadOpenAIKey(), nil, "no key to load")
    expectEqual(store.maskedKey(), nil, "no mask when empty")

    try! store.saveOpenAIKey("sk-test-1234567890abcd")
    expect(store.hasOpenAIKey(), "has key after save")
    expectEqual(try! store.loadOpenAIKey(), "sk-test-1234567890abcd", "loads saved key verbatim")
    expectEqual(store.maskedKey(), "sk-••••••abcd", "masks all but last 4")

    try! store.deleteOpenAIKey()
    expect(!store.hasOpenAIKey(), "key gone after delete")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build`
Expected: FAIL — `cannot find 'InMemoryAPIKeyStore' in scope`.

- [ ] **Step 3: Write minimal implementation** — create `Sources/SkimCore/Comprehension/APIKeyStore.swift`:

```swift
import Foundation

/// Stores the user's OpenAI API key. The shipping implementation
/// (`KeychainAPIKeyStore`, App layer) keeps it in the iOS Keychain — never in
/// UserDefaults, logs, analytics, or crash reports. This protocol lives in the
/// core so planning/service logic can depend on it and be tested with a fake.
public protocol APIKeyStore: AnyObject {
    func saveOpenAIKey(_ key: String) throws
    func loadOpenAIKey() throws -> String?
    func deleteOpenAIKey() throws
    func hasOpenAIKey() -> Bool
}

public extension APIKeyStore {
    /// A display mask that never reveals the secret: `sk-••••••abcd` (last 4).
    /// Returns `nil` when there's no key. Failures to read are treated as no key.
    func maskedKey() -> String? {
        guard let key = (try? loadOpenAIKey()) ?? nil, !key.isEmpty else { return nil }
        let tail = key.suffix(4)
        return "sk-••••••\(tail)"
    }
}

/// A non-persistent key store for tests and SwiftUI previews.
public final class InMemoryAPIKeyStore: APIKeyStore {
    private var key: String?
    public init(key: String? = nil) { self.key = key }
    public func saveOpenAIKey(_ key: String) throws { self.key = key }
    public func loadOpenAIKey() throws -> String? { key }
    public func deleteOpenAIKey() throws { key = nil }
    public func hasOpenAIKey() -> Bool { key?.isEmpty == false }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift run CoreChecks`
Expected: PASS — `All checks passed ✅`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkimCore/Comprehension/APIKeyStore.swift Sources/CoreChecks/main.swift
git commit -m "feat(core): API key store protocol + in-memory double"
```

---

### Task 8: SQLite persistence for checks / questions / answers

**Files:**
- Modify: `Sources/SkimCore/SkimStore.swift` (add migration block ~line 239 after the ideas index; add a `// MARK: Comprehension` method section before `// MARK: SQLite plumbing` at line 466)
- Test: append a `SkimStore comprehension` section to `Sources/CoreChecks/main.swift`

**Interfaces:**
- Consumes: `ComprehensionCheck`, `ComprehensionQuestion`, `ComprehensionChoices`, `ChoiceKey`, `QuestionType`, `ComprehensionGenerationKind` (Task 1); the existing private `run`/`query`/`exec`/`bindText`/`bindInt`/`text`/`int`/`date` helpers and `iso` formatter in `SkimStore`.
- Produces (new `public` methods on `SkimStore`):
  - `func insertCheck(_ check: ComprehensionCheck) throws` — writes the check row and all its question rows in one transaction.
  - `func initialCheck(textHash: String, model: String, promptVersion: Int) throws -> ComprehensionCheck?`
  - `func hasInitialCheck(textHash: String, model: String, promptVersion: Int) throws -> Bool`
  - `func checks(forReadId readId: String) throws -> [ComprehensionCheck]` — all batches, `batchIndex` ascending, each with its questions.
  - `func nextBatchIndex(parentCheckId: UUID) throws -> Int`
  - `func setQuestionDisputed(questionId: UUID, disputed: Bool) throws`
  - `func recordAnswer(questionId: UUID, selectedChoice: ChoiceKey, isCorrect: Bool, answeredAt: Date) throws`
  - `func answers(forCheckId checkId: UUID) throws -> [UUID: ChoiceKey]`
  - `func markCheckCompleted(checkId: UUID, score: Int, completedAt: Date) throws`

- [ ] **Step 1: Write the failing test** — append to `Sources/CoreChecks/main.swift`:

```swift
print("SkimStore comprehension")
do {
    let store = try! SkimStore(path: ":memory:")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let choices = ComprehensionChoices(a: "a", b: "b", c: "c", d: "d")
    let q = ComprehensionQuestion(question: "Main point?", choices: choices, correctChoice: .b,
                explanation: "because", supportingQuote: "a grounded excerpt of eight words here now",
                type: .mainPoint)
    let check = ComprehensionCheck(readId: "read-1", textHash: "hash-1", model: "m1",
                promptVersion: 1, generatedAt: now, kind: .initial, batchIndex: 0, questions: [q])

    expect(!(try! store.hasInitialCheck(textHash: "hash-1", model: "m1", promptVersion: 1)),
           "no check before insert")
    try! store.insertCheck(check)
    expect(try! store.hasInitialCheck(textHash: "hash-1", model: "m1", promptVersion: 1),
           "check present after insert")
    // promptVersion is part of the key: a bump misses the cache.
    expect(!(try! store.hasInitialCheck(textHash: "hash-1", model: "m1", promptVersion: 2)),
           "promptVersion bump invalidates the cached check")

    let loaded = try! store.initialCheck(textHash: "hash-1", model: "m1", promptVersion: 1)
    expectEqual(loaded?.questions.count, 1, "round-trips its question")
    expectEqual(loaded?.questions.first?.correctChoice, .b, "round-trips correctChoice")
    expectEqual(loaded?.questions.first?.type, .mainPoint, "round-trips type")
    expectEqual(loaded?.questions.first?.id, q.id, "preserves question id")

    // Dispute flag persists.
    try! store.setQuestionDisputed(questionId: q.id, disputed: true)
    let disputed = try! store.checks(forReadId: "read-1").first?.questions.first?.disputed
    expectEqual(disputed, true, "dispute flag persists")

    // Answers persist and read back as a map.
    try! store.recordAnswer(questionId: q.id, selectedChoice: .b, isCorrect: true, answeredAt: now)
    expectEqual(try! store.answers(forCheckId: check.id), [q.id: .b], "answer round-trips")

    // Batch index increments for generate-more under a parent.
    expectEqual(try! store.nextBatchIndex(parentCheckId: check.id), 1, "first follow-up batch is index 1")

    // Completion stamps score.
    try! store.markCheckCompleted(checkId: check.id, score: 1, completedAt: now)
    expectEqual(try! store.checks(forReadId: "read-1").first?.score, 1, "score persists on completion")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build`
Expected: FAIL — `value of type 'SkimStore' has no member 'hasInitialCheck'`.

- [ ] **Step 3a: Add the migration** — in `SkimStore.migrate()`, after the `idx_ideas_created` index line (around line 238), insert:

```swift
        try exec("""
        CREATE TABLE IF NOT EXISTS comprehension_checks (
            id TEXT PRIMARY KEY,
            read_id TEXT NOT NULL,
            text_hash TEXT NOT NULL,
            model TEXT NOT NULL,
            prompt_version INTEGER NOT NULL,
            generated_at TEXT NOT NULL,
            kind TEXT NOT NULL,
            parent_check_id TEXT,
            batch_index INTEGER NOT NULL DEFAULT 0,
            completed_at TEXT,
            score INTEGER
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_checks_read ON comprehension_checks(read_id);")
        try exec("""
        CREATE INDEX IF NOT EXISTS idx_checks_initial
        ON comprehension_checks(text_hash, model, prompt_version, kind);
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS comprehension_questions (
            id TEXT PRIMARY KEY,
            check_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            question TEXT NOT NULL,
            choice_a TEXT NOT NULL,
            choice_b TEXT NOT NULL,
            choice_c TEXT NOT NULL,
            choice_d TEXT NOT NULL,
            correct_choice TEXT NOT NULL,
            explanation TEXT NOT NULL,
            supporting_quote TEXT NOT NULL,
            type TEXT NOT NULL,
            source_start_token_index INTEGER,
            source_end_token_index INTEGER,
            disputed INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(check_id) REFERENCES comprehension_checks(id) ON DELETE CASCADE
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_questions_check ON comprehension_questions(check_id, ordinal);")
        try exec("""
        CREATE TABLE IF NOT EXISTS comprehension_answers (
            question_id TEXT PRIMARY KEY,
            selected_choice TEXT NOT NULL,
            is_correct INTEGER NOT NULL,
            answered_at TEXT NOT NULL,
            FOREIGN KEY(question_id) REFERENCES comprehension_questions(id) ON DELETE CASCADE
        );
        """)
```

- [ ] **Step 3b: Add the CRUD methods** — insert a new section just before `// MARK: SQLite plumbing` (line 466):

```swift
    // MARK: Comprehension

    /// Write a check and all its questions atomically. Used for both the initial
    /// batch and each user-requested "generate more" follow-up.
    public func insertCheck(_ check: ComprehensionCheck) throws {
        try exec("BEGIN;")
        do {
            try run("""
            INSERT INTO comprehension_checks
              (id, read_id, text_hash, model, prompt_version, generated_at, kind,
               parent_check_id, batch_index, completed_at, score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """) { stmt in
                bindText(stmt, 1, check.id.uuidString)
                bindText(stmt, 2, check.readId)
                bindText(stmt, 3, check.textHash)
                bindText(stmt, 4, check.model)
                bindInt(stmt, 5, check.promptVersion)
                bindText(stmt, 6, iso.string(from: check.generatedAt))
                bindText(stmt, 7, check.kind.rawValue)
                bindText(stmt, 8, check.parentCheckId?.uuidString)
                bindInt(stmt, 9, check.batchIndex)
                bindText(stmt, 10, check.completedAt.map { iso.string(from: $0) })
                bindInt(stmt, 11, check.score)
            }
            for (ordinal, q) in check.questions.enumerated() {
                try run("""
                INSERT INTO comprehension_questions
                  (id, check_id, ordinal, question, choice_a, choice_b, choice_c, choice_d,
                   correct_choice, explanation, supporting_quote, type,
                   source_start_token_index, source_end_token_index, disputed)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """) { stmt in
                    bindText(stmt, 1, q.id.uuidString)
                    bindText(stmt, 2, check.id.uuidString)
                    bindInt(stmt, 3, ordinal)
                    bindText(stmt, 4, q.question)
                    bindText(stmt, 5, q.choices.a)
                    bindText(stmt, 6, q.choices.b)
                    bindText(stmt, 7, q.choices.c)
                    bindText(stmt, 8, q.choices.d)
                    bindText(stmt, 9, q.correctChoice.rawValue)
                    bindText(stmt, 10, q.explanation)
                    bindText(stmt, 11, q.supportingQuote)
                    bindText(stmt, 12, q.type.rawValue)
                    bindInt(stmt, 13, q.sourceStartTokenIndex)
                    bindInt(stmt, 14, q.sourceEndTokenIndex)
                    bindInt(stmt, 15, q.disputed ? 1 : 0)
                }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// The cached initial check for a text under the current prompt version, if any.
    public func initialCheck(textHash: String, model: String, promptVersion: Int) throws -> ComprehensionCheck? {
        var id: String?
        try query("""
        SELECT id FROM comprehension_checks
        WHERE text_hash = ? AND model = ? AND prompt_version = ? AND kind = 'initial'
        ORDER BY generated_at DESC LIMIT 1;
        """, bind: { stmt in
            bindText(stmt, 1, textHash); bindText(stmt, 2, model); bindInt(stmt, 3, promptVersion)
        }, each: { stmt in id = Self.columnText(stmt, 0) })
        guard let id, let uuid = UUID(uuidString: id) else { return nil }
        return try loadCheck(id: uuid)
    }

    public func hasInitialCheck(textHash: String, model: String, promptVersion: Int) throws -> Bool {
        try initialCheck(textHash: textHash, model: model, promptVersion: promptVersion) != nil
    }

    /// All batches for a read (initial + follow-ups), oldest batch first.
    public func checks(forReadId readId: String) throws -> [ComprehensionCheck] {
        var ids: [UUID] = []
        try query("""
        SELECT id FROM comprehension_checks WHERE read_id = ? ORDER BY batch_index ASC, generated_at ASC;
        """, bind: { bindText($0, 1, readId) }, each: { stmt in
            if let s = Self.columnText(stmt, 0), let u = UUID(uuidString: s) { ids.append(u) }
        })
        return try ids.compactMap { try loadCheck(id: $0) }
    }

    public func nextBatchIndex(parentCheckId: UUID) throws -> Int {
        var maxIndex: Int = 0
        try query("""
        SELECT COALESCE(MAX(batch_index), 0) FROM comprehension_checks WHERE parent_check_id = ?;
        """, bind: { bindText($0, 1, parentCheckId.uuidString) },
             each: { maxIndex = Int(sqlite3_column_int64($0, 0)) })
        return maxIndex + 1
    }

    public func setQuestionDisputed(questionId: UUID, disputed: Bool) throws {
        try run("UPDATE comprehension_questions SET disputed = ? WHERE id = ?;") { stmt in
            bindInt(stmt, 1, disputed ? 1 : 0)
            bindText(stmt, 2, questionId.uuidString)
        }
    }

    public func recordAnswer(questionId: UUID, selectedChoice: ChoiceKey, isCorrect: Bool, answeredAt: Date) throws {
        try run("""
        INSERT INTO comprehension_answers (question_id, selected_choice, is_correct, answered_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(question_id) DO UPDATE SET
          selected_choice = excluded.selected_choice,
          is_correct = excluded.is_correct,
          answered_at = excluded.answered_at;
        """) { stmt in
            bindText(stmt, 1, questionId.uuidString)
            bindText(stmt, 2, selectedChoice.rawValue)
            bindInt(stmt, 3, isCorrect ? 1 : 0)
            bindText(stmt, 4, iso.string(from: answeredAt))
        }
    }

    /// The user's answers for one check, as questionId → chosen key.
    public func answers(forCheckId checkId: UUID) throws -> [UUID: ChoiceKey] {
        var out: [UUID: ChoiceKey] = [:]
        try query("""
        SELECT a.question_id, a.selected_choice
        FROM comprehension_answers a
        JOIN comprehension_questions q ON q.id = a.question_id
        WHERE q.check_id = ?;
        """, bind: { bindText($0, 1, checkId.uuidString) }, each: { stmt in
            if let qs = Self.columnText(stmt, 0), let qid = UUID(uuidString: qs),
               let cs = Self.columnText(stmt, 1), let key = ChoiceKey(rawValue: cs) {
                out[qid] = key
            }
        })
        return out
    }

    public func markCheckCompleted(checkId: UUID, score: Int, completedAt: Date) throws {
        try run("UPDATE comprehension_checks SET score = ?, completed_at = ? WHERE id = ?;") { stmt in
            bindInt(stmt, 1, score)
            bindText(stmt, 2, iso.string(from: completedAt))
            bindText(stmt, 3, checkId.uuidString)
        }
    }

    private func loadCheck(id: UUID) throws -> ComprehensionCheck? {
        var check: ComprehensionCheck?
        try query("""
        SELECT id, read_id, text_hash, model, prompt_version, generated_at, kind,
               parent_check_id, batch_index, completed_at, score
        FROM comprehension_checks WHERE id = ? LIMIT 1;
        """, bind: { bindText($0, 1, id.uuidString) }, each: { stmt in
            check = ComprehensionCheck(
                id: UUID(uuidString: Self.columnText(stmt, 0) ?? "") ?? id,
                readId: Self.columnText(stmt, 1) ?? "",
                textHash: Self.columnText(stmt, 2) ?? "",
                model: Self.columnText(stmt, 3) ?? "",
                promptVersion: Int(sqlite3_column_int64(stmt, 4)),
                generatedAt: self.iso.date(from: Self.columnText(stmt, 5) ?? "") ?? Date(timeIntervalSince1970: 0),
                kind: ComprehensionGenerationKind(rawValue: Self.columnText(stmt, 6) ?? "initial") ?? .initial,
                parentCheckId: Self.columnText(stmt, 7).flatMap { UUID(uuidString: $0) },
                batchIndex: Int(sqlite3_column_int64(stmt, 8)),
                questions: [],
                completedAt: Self.columnText(stmt, 9).flatMap { self.iso.date(from: $0) },
                score: self.int(stmt, 10)
            )
        })
        guard var loaded = check else { return nil }
        loaded.questions = try loadQuestions(checkId: id)
        return loaded
    }

    private func loadQuestions(checkId: UUID) throws -> [ComprehensionQuestion] {
        var out: [ComprehensionQuestion] = []
        try query("""
        SELECT id, question, choice_a, choice_b, choice_c, choice_d, correct_choice,
               explanation, supporting_quote, type, source_start_token_index,
               source_end_token_index, disputed
        FROM comprehension_questions WHERE check_id = ? ORDER BY ordinal ASC;
        """, bind: { bindText($0, 1, checkId.uuidString) }, each: { stmt in
            out.append(ComprehensionQuestion(
                id: UUID(uuidString: Self.columnText(stmt, 0) ?? "") ?? UUID(),
                question: Self.columnText(stmt, 1) ?? "",
                choices: ComprehensionChoices(
                    a: Self.columnText(stmt, 2) ?? "", b: Self.columnText(stmt, 3) ?? "",
                    c: Self.columnText(stmt, 4) ?? "", d: Self.columnText(stmt, 5) ?? ""),
                correctChoice: ChoiceKey(rawValue: Self.columnText(stmt, 6) ?? "a") ?? .a,
                explanation: Self.columnText(stmt, 7) ?? "",
                supportingQuote: Self.columnText(stmt, 8) ?? "",
                type: QuestionType(rawValue: Self.columnText(stmt, 9) ?? "main_point") ?? .mainPoint,
                sourceStartTokenIndex: self.int(stmt, 10),
                sourceEndTokenIndex: self.int(stmt, 11),
                disputed: Int(sqlite3_column_int64(stmt, 12)) == 1
            ))
        })
        return out
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift run CoreChecks`
Expected: PASS — `All checks passed ✅`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkimCore/SkimStore.swift Sources/CoreChecks/main.swift
git commit -m "feat(core): SQLite persistence for comprehension checks/questions/answers"
```

---

## Self-Review

**Spec coverage (Plan 1's scope — the SkimCore + storage rows of the design):**
- Models (incl. `promptVersion`, `parentCheckId`, `batchIndex`, `disputed`, draft DTOs) → Task 1. ✓
- Threshold table + type allocation + eligibility predicate + `promptVersion` cache keys → Task 2. ✓
- Quote normalization (curly quotes/dashes/NBSP/whitespace/punctuation, idempotent) → Task 3. ✓
- Validation (count, empties, dup choices, dup questions, 8–40-word grounded normalized-substring quote) → Task 4. ✓
- Long-read chunk sampling (≤4000 whole, >4000 paragraph-aligned 5-way, no mid-sentence cut) → Task 5. ✓
- Scoring + softened ≤33% copy + disputed exclusion → Task 6. ✓
- `APIKeyStore` protocol + mask + in-memory double → Task 7. ✓
- Normalized 3-table SQLite persistence + `promptVersion`-aware cache lookup + dispute/answer/score CRUD → Task 8. ✓
- **Deferred to Plan 2 (correctly not here):** Keychain implementation, OpenAI provider + structured outputs + single-retry, `ComprehensionService` orchestration + pre-gen trigger + task lifecycle, Settings/consent/question/result SwiftUI, Test Key, privacy manifest, end-screen wiring.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every test shows real assertions. ✓

**Type consistency:** `ComprehensionCheckDraft.questions: [ComprehensionQuestionDraft]` is consumed unchanged by Task 4; `ComprehensionQuestion(draft:)` (Task 1) is the bridge the Plan-2 service will use; `QuestionPlan` constants referenced in Task 2 tests match the enum; `SkimStore` methods in Task 8 match the `ComprehensionCheck`/`ComprehensionQuestion` shapes from Task 1 and the cache-key inputs from Task 2 (`textHash + model + promptVersion`). ✓

---

## Plan 2 preview (OpenAI & UI — separate plan, Xcode-verified)

Not part of this plan; listed so the boundary is clear. Tasks 9–17:
9. `KeychainAPIKeyStore` (App) implementing `APIKeyStore` over `SecItem`.
10. OpenAI DTOs + `ComprehensionQuestionProvider` protocol + `OpenAIComprehensionProvider` (Structured Outputs, one schema-constrained retry, configurable model).
11. `ComprehensionService` (`@MainActor`): eligibility via `QuestionPlan`, idempotent in-flight map keyed by `readId`, persistence, status derivation, generate-more with caps.
12. Pre-gen trigger wired into `ReaderViewModel.recordLoadedRead()`; lifecycle = attach-by-`readId`, cancel only on clear/delete/replace.
13. Settings "AI Features" section + key add/test/delete (Test Key hits the configured model) + `aiComprehensionEnabled`.
14. Consent sheet (first manual tap only) + `aiComprehensionConsentAccepted`.
15. End-screen CTA + status routing (ready/generating/failed/no-key/no-consent).
16. Question UI (one-at-a-time, feedback, grounded quote, "this seems off") + result screen + Generate more.
17. Privacy manifest / Info.plist "data sent off device" + `xcodebuild` integration pass + device deploy via `scripts/deploy-device.sh`.
