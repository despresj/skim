import Foundation
import Observation

/// Orchestrates comprehension checks end-to-end on the main actor: decides
/// eligibility, reads the key, hands generation to the provider off-main,
/// validates with SkimCore, persists to SkimStore, and tracks per-read status.
/// Reading is the main event — pre-generation is quiet and never blocks it.
@MainActor @Observable final class ComprehensionService {
    private let store: SkimStore?
    private let keyStore: APIKeyStore
    private let provider: ComprehensionQuestionProvider
    private let settings: AISettings

    /// In-flight pre-gen jobs keyed by readId, so we never double-generate and can
    /// cancel a job whose read was replaced before it persisted.
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// The read currently on screen — results for any other readId are discarded.
    private var activeReadId: String?
    /// Bumps when stored checks change, so SwiftUI re-derives status.
    private(set) var revision = 0

    init(store: SkimStore?, keyStore: APIKeyStore,
         provider: ComprehensionQuestionProvider, settings: AISettings) {
        self.store = store
        self.keyStore = keyStore
        self.provider = provider
        self.settings = settings
    }

    var hasKey: Bool { keyStore.hasOpenAIKey() }
    func maskedKey() -> String? { keyStore.maskedKey() }
    func saveKey(_ key: String) throws { try keyStore.saveOpenAIKey(key) }
    func deleteKey() throws { try keyStore.deleteOpenAIKey() }

    /// Read-only accessor the Settings UI uses to inspect current preferences.
    var settingsForUI: AISettings { settings }

    func testKey() async -> Result<Void, ComprehensionError> {
        guard let key = (try? keyStore.loadOpenAIKey()) ?? nil, !key.isEmpty else { return .failure(.missingKey) }
        do { try await provider.validateKey(apiKey: key, model: settings.model); return .success(()) }
        catch let e as ComprehensionError { return .failure(e) }
        catch { return .failure(.network) }
    }

    // MARK: Pre-generation (paste/import)

    /// Called from `recordLoadedRead`. Switches the active read (cancelling a
    /// stale in-flight job for the prior read) and silently pre-generates if eligible.
    func handleReadLoaded(readId: String?, text: String, title: String?, wordCount: Int) {
        if let prior = activeReadId, prior != readId, let task = inFlight[prior] {
            task.cancel(); inFlight[prior] = nil
        }
        activeReadId = readId
        guard let readId, let store else { return }
        let textHash = TextHash.of(text)
        let alreadyHas = (try? store.hasInitialCheck(textHash: textHash, model: settings.model,
                                                     promptVersion: QuestionPlan.currentPromptVersion)) ?? false
        guard QuestionPlan.shouldPreGenerate(
            wordCount: wordCount, aiEnabled: settings.enabled,
            consentAccepted: settings.consentAccepted, hasKey: hasKey, hasInitialCheck: alreadyHas)
        else { return }
        guard inFlight[readId] == nil else { return }

        inFlight[readId] = Task { [weak self] in
            guard let self else { return }
            _ = await self.generateInitial(readId: readId, text: text, title: title, wordCount: wordCount)
            self.inFlight[readId] = nil
        }
    }

    func cancelIfActive(readId: String?) {
        guard let readId, let task = inFlight[readId] else { return }
        task.cancel(); inFlight[readId] = nil
    }

    // MARK: Status

    func status(forReadId readId: String?) -> ComprehensionStatus {
        _ = revision   // observe
        guard settings.enabled else { return .unavailable }
        guard let readId, let store, let batches = try? store.checks(forReadId: readId), !batches.isEmpty else {
            return inFlight[readId ?? ""] != nil ? .generating : .notStarted
        }
        if batches.contains(where: { $0.completedAt != nil }) { return .answered }
        return .ready
    }

    // MARK: Generation

    /// Manual end-screen path: reuse the cached initial check or generate one.
    func loadOrGenerate(readId: String, text: String, title: String?, wordCount: Int)
        async -> Result<ComprehensionCheck, ComprehensionError> {
        if let store, let cached = try? store.initialCheck(
            textHash: TextHash.of(text), model: settings.model, promptVersion: QuestionPlan.currentPromptVersion) {
            return .success(cached)
        }
        // If a pre-gen job is mid-flight for this read, await it, then re-read.
        if let job = inFlight[readId] { await job.value
            if let store, let cached = try? store.initialCheck(
                textHash: TextHash.of(text), model: settings.model, promptVersion: QuestionPlan.currentPromptVersion) {
                return .success(cached)
            }
        }
        return await generateInitial(readId: readId, text: text, title: title, wordCount: wordCount)
    }

    func generateMore(parent: ComprehensionCheck, text: String, title: String?)
        async -> Result<ComprehensionCheck, ComprehensionError> {
        guard let store else { return .failure(.badResponse) }
        let existing = (try? store.checks(forReadId: parent.readId)) ?? []
        let total = existing.reduce(0) { $0 + $1.questions.count }
        let remaining = QuestionPlan.hardCap - total
        guard remaining > 0 else { return .failure(.badResponse) }
        let count = min(QuestionPlan.generateMoreCount, remaining)
        let batchIndex = (try? store.nextBatchIndex(parentCheckId: parent.id)) ?? 1
        let avoiding = existing.flatMap { $0.questions.map(\.question) }
        return await generate(
            readId: parent.readId, text: text, title: title,
            count: count, types: QuestionPlan.generateMoreTypes(),
            avoiding: avoiding, kind: .generateMore, parentId: parent.id, batchIndex: batchIndex)
    }

    private func generateInitial(readId: String, text: String, title: String?, wordCount: Int)
        async -> Result<ComprehensionCheck, ComprehensionError> {
        let count = QuestionPlan.initialQuestionCount(wordCount: wordCount)
        guard count > 0 else { return .failure(.tooShort) }
        return await generate(
            readId: readId, text: text, title: title, count: count,
            types: QuestionPlan.types(forCount: count), avoiding: [],
            kind: .initial, parentId: nil, batchIndex: 0)
    }

    /// The central pipeline: chunk → read key → provider (off-main) → validate →
    /// mint persisted questions → persist. Results attach only to `readId`.
    private func generate(readId: String, text: String, title: String?, count: Int,
                          types: [QuestionType], avoiding: [String],
                          kind: ComprehensionGenerationKind, parentId: UUID?, batchIndex: Int)
        async -> Result<ComprehensionCheck, ComprehensionError> {
        guard let key = (try? keyStore.loadOpenAIKey()) ?? nil, !key.isEmpty else { return .failure(.missingKey) }
        let payload = ComprehensionChunking.sampleForGeneration(text)
        let request = ComprehensionRequest(
            text: payload, title: title, count: count, types: types,
            avoiding: avoiding, apiKey: key, model: settings.model)

        let draft: ComprehensionCheckDraft
        do { draft = try await provider.generate(request) }
        catch let e as ComprehensionError { return .failure(e) }
        catch { return .failure(.network) }

        // Validate against the FULL source (grounding must hold against real text).
        let problems = ComprehensionValidation.validate(draft, requestedCount: count, sourceText: text)
        guard problems.isEmpty else { return .failure(.badResponse) }

        let check = ComprehensionCheck(
            readId: readId, textHash: TextHash.of(text), model: settings.model,
            promptVersion: QuestionPlan.currentPromptVersion, generatedAt: Date(),
            kind: kind, parentCheckId: parentId, batchIndex: batchIndex,
            questions: draft.questions.map { ComprehensionQuestion(draft: $0) })
        do { try store?.insertCheck(check) } catch { return .failure(.badResponse) }
        revision &+= 1
        return .success(check)
    }

    // MARK: Answers / dispute / completion

    func recordAnswer(question: ComprehensionQuestion, selected: ChoiceKey) {
        try? store?.recordAnswer(questionId: question.id, selectedChoice: selected,
                                 isCorrect: selected == question.correctChoice, answeredAt: Date())
        revision &+= 1
    }
    func setDisputed(question: ComprehensionQuestion, disputed: Bool) {
        try? store?.setQuestionDisputed(questionId: question.id, disputed: disputed); revision &+= 1
    }
    func complete(check: ComprehensionCheck, correct: Int) {
        try? store?.markCheckCompleted(checkId: check.id, score: correct, completedAt: Date()); revision &+= 1
    }
}
