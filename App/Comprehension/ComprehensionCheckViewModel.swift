import Foundation
import Observation

/// Drives one comprehension-check session from the end screen: gate on key/consent,
/// generate (or open the pre-generated check), step through questions one at a time
/// with immediate feedback, score, and optionally generate more. All on the main actor.
@MainActor @Observable final class ComprehensionCheckViewModel {
    enum Phase: Equatable {
        case idle, missingKey, needsConsent, generating, answering, complete
        case failed(ComprehensionError)
    }

    private(set) var phase: Phase = .idle
    private(set) var check: ComprehensionCheck?
    private(set) var currentIndex = 0
    private(set) var selected: [UUID: ChoiceKey] = [:]
    private(set) var revealed = false
    private(set) var result: ComprehensionResult?

    private let service: ComprehensionService
    private let settings: AISettings
    private let readId: String
    private let text: String
    private let title: String?
    private let wordCount: Int

    init(service: ComprehensionService, settings: AISettings, readId: String,
         text: String, title: String?, wordCount: Int) {
        self.service = service; self.settings = settings; self.readId = readId
        self.text = text; self.title = title; self.wordCount = wordCount
    }

    var currentQuestion: ComprehensionQuestion? {
        guard let check, check.questions.indices.contains(currentIndex) else { return nil }
        return check.questions[currentIndex]
    }
    var isLastQuestion: Bool {
        guard let check else { return true }
        return currentIndex >= check.questions.count - 1
    }
    var canGenerateMore: Bool {
        (check?.questions.count ?? 0) < QuestionPlan.hardCap
    }

    func start() async {
        guard service.hasKey else { phase = .missingKey; return }
        guard settings.consentAccepted else { phase = .needsConsent; return }
        await generate()
    }

    func acceptConsent() async { settings.consentAccepted = true; await generate() }
    func cancelConsent() { phase = .idle }

    private func generate() async {
        phase = .generating
        switch await service.loadOrGenerate(readId: readId, text: text, title: title, wordCount: wordCount) {
        case .success(let c): check = c; currentIndex = 0; revealed = false; phase = .answering
        case .failure(let e): phase = .failed(e)
        }
    }

    func select(_ choice: ChoiceKey) {
        guard phase == .answering, let q = currentQuestion, selected[q.id] == nil else { return }
        selected[q.id] = choice
        revealed = true
        service.recordAnswer(question: q, selected: choice)
    }

    func next() {
        guard let check else { return }
        if currentIndex < check.questions.count - 1 {
            currentIndex += 1; revealed = selected[check.questions[currentIndex].id] != nil
        } else {
            finish()
        }
    }

    func flagCurrentDisputed() {
        guard var check, let q = currentQuestion else { return }
        service.setDisputed(question: q, disputed: true)
        check.questions[currentIndex].disputed = true
        self.check = check
    }

    private func finish() {
        guard let check else { return }
        let r = ComprehensionScoring.result(questions: check.questions, answers: selected)
        result = r
        service.complete(check: check, correct: r.correct)
        phase = .complete
    }

    func generateMore() async {
        guard let parent = check else { return }
        phase = .generating
        switch await service.generateMore(parent: parent, text: text, title: title) {
        case .success(let more):
            var merged = parent
            merged.questions.append(contentsOf: more.questions)
            check = merged
            currentIndex = parent.questions.count   // jump to first new question
            revealed = false
            phase = .answering
        case .failure(let e): phase = .failed(e)
        }
    }

    func retry() async { await generate() }
}
