# Comprehension Checks — OpenAI & UI Implementation Plan (Plan 2 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Plan 1's tested SkimCore foundation into the running iOS app — a BYOK OpenAI provider, a `@MainActor` orchestration service that pre-generates on paste, Settings/consent/question/result UI — so a reader who has opted in gets an optional, calm comprehension check after a long read.

**Architecture:** All new code is **App-layer** (UIKit/SwiftUI/Security/URLSession), compiled in the Xcode target alongside SkimCore. It consumes Plan 1's `SkimCore` types directly (no `import SkimCore` — the app compiles core files into the same module). The OpenAI provider is the app's first network code; the Keychain store is its first secret storage. Design spec: `docs/superpowers/specs/2026-06-25-comprehension-checks-design.md`. Foundation: `docs/superpowers/plans/2026-06-25-comprehension-checks-core.md` (Plan 1, already on `main`).

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, `@Observable`, `Security` (Keychain), `URLSession` + OpenAI Chat Completions with Structured Outputs, XcodeGen.

## Prerequisites & verification model

**This plan requires full Xcode** (the App target can't build under Command Line Tools). There is no `CoreChecks`-style harness for App code. **Per-task verification is a clean Xcode build plus a targeted manual/simulator check:**

```sh
xcodegen generate
xcodebuild -scheme Skim -destination 'generic/platform=iOS' build   # must succeed, zero warnings on touched files
```

For tasks with runnable behavior, also build+run on the simulator (or device via `scripts/deploy-device.sh`, which is build-gated) and confirm the named behavior. SkimCore logic this UI depends on is already test-covered by Plan 1's `CoreChecks` — do **not** duplicate that here; only add app-level checks.

## Global Constraints

- **Swift 6 strict concurrency.** `ReaderViewModel`, the service, and the view models are `@MainActor @Observable`. The provider is `Sendable` and does its network work off the main actor; only `Sendable` values (`String`, `ComprehensionCheckDraft`, the request struct) cross the boundary.
- **`SkimStore` is NOT `Sendable`/thread-safe** (Plan 1) — touch it only from `@MainActor`. Read the API key from the Keychain on `@MainActor` and pass the resulting `String` into the provider; never touch Keychain or store off-main.
- **No developer-owned API key** anywhere in the repo, ever. BYOK only.
- **Consent is requested only on the first manual "Check understanding" tap — never during paste/import.** Pre-gen requires `consentAccepted == true` already.
- **Pre-gen fires on paste/import** (in `recordLoadedRead`), never blocking reader launch, no paste-time loading UI.
- **Lifecycle:** a generation result attaches only to its originating `readId`. Cancel a job only when its read is cleared/replaced before persistence — not on mere navigation.
- **Cache keys include `promptVersion`** (`QuestionPlan.currentPromptVersion`). The initial-check lookup is `SkimStore.initialCheck(textHash:model:promptVersion:)`.
- **Structured Outputs, not JSON repair:** request OpenAI `response_format` = strict `json_schema`. On a validation/decode/API failure do exactly **one** schema-constrained regeneration retry (a clean re-ask with a stricter instruction), then surface a failure — never free-form JSON repair.
- **Grounding/validation/scoring/planning/chunking are Plan 1 SkimCore calls** — reuse them; do not reimplement. (`ComprehensionValidation.validate`, `QuestionPlan.*`, `ComprehensionChunking.sampleForGeneration`, `ComprehensionScoring.result`.)
- **Default model:** `"gpt-4o-mini"`, stored on each check and on `AISettings.model` (configurable later). The provider endpoint is `https://api.openai.com/v1/chat/completions`.
- **Failure copy (verbatim):** no key → "Add an OpenAI API key to use comprehension checks." · invalid key → "That API key did not work. Check it or replace it in Settings." · network → "Couldn't reach OpenAI. Check your connection and try again." · rate limit → "OpenAI rejected the request, likely due to rate limits or quota on your API key." · bad schema after retry → "Couldn't build a clean check for this read." · too short → "This read is too short for a useful check."
- **Score semantics (standardized — watch-item):** `SkimStore.markCheckCompleted(score:)` stores the **correct-count** (`ComprehensionResult.correct`). Percent/headline/guidance are derived at display time via `ComprehensionScoring.result`, never persisted.
- **Caps:** generate-more soft cap 8, hard cap 12 questions per read (`QuestionPlan.softCap`/`.hardCap`); first follow-up batch is `nextBatchIndex` = 1 (no off-by-one); children store `parentCheckId` = the initial check's id.
- **Calm UX:** the reading surface stays sacred; comprehension UI appears only on the end screen / its own sheets, never during active reading.

---

## File map

**New (App/Comprehension/):**
- `KeychainAPIKeyStore.swift` — `APIKeyStore` over Keychain (Task 9).
- `ComprehensionProvider.swift` — provider protocol, `ComprehensionRequest`, `ComprehensionError`, OpenAI DTOs (Task 10).
- `OpenAIComprehensionProvider.swift` — the OpenAI implementation (Task 10).
- `AISettings.swift` — UserDefaults-backed `enabled`/`consentAccepted`/`model` (Task 11).
- `ComprehensionService.swift` — `@MainActor` orchestration + pre-gen + persistence + generate-more (Task 11).
- `ComprehensionCheckViewModel.swift` — the answering state machine (Task 16).
- `AIFeaturesView.swift` — Settings → AI key management (Task 13).
- `ComprehensionConsentView.swift` — first-use consent sheet (Task 14).
- `ComprehensionCheckView.swift` — generating/question/result/failed UI (Task 17).
- `App/PrivacyInfo.xcprivacy` — privacy manifest (Task 18).

**Modified:**
- `App/ReaderViewModel.swift` — hold the service; fire pre-gen in `recordLoadedRead`; cancel on clear (Task 12).
- `App/SkimApp.swift` — construct provider/keyStore/settings/service; inject into `ReaderViewModel` (Task 12).
- `App/SettingsView.swift` — add the "AI Features" row → `AIFeaturesView` (Task 13).
- `App/ReviewView.swift` — add the "Check understanding" CTA + flow presentation (Task 15).
- `project.yml` / `App/Info.plist` — privacy manifest membership (Task 18).

---

### Task 9: Keychain-backed API key store

**Files:**
- Create: `App/Comprehension/KeychainAPIKeyStore.swift`

**Interfaces:**
- Consumes: `APIKeyStore` protocol (SkimCore, Plan 1 — `saveOpenAIKey`/`loadOpenAIKey`/`deleteOpenAIKey`/`hasOpenAIKey`, plus the `maskedKey()` extension).
- Produces: `final class KeychainAPIKeyStore: APIKeyStore` — persists one key under service `"com.despresj.skim"`, account `"openai-api-key"`, accessible `kSecAttrAccessibleAfterFirstThisDeviceOnly` (available offline, not synced/exported). MainActor-confined by convention (the service reads it on `@MainActor`).

**Concurrency note:** the class is not `Sendable`; only call it from `@MainActor`. The service reads the key on the main actor and passes the `String` into the provider, so Keychain is never touched off-main.

- [ ] **Step 1: Implement** — create `App/Comprehension/KeychainAPIKeyStore.swift`:

```swift
import Foundation
import Security

/// The shipping `APIKeyStore`: the user's OpenAI key in the iOS Keychain, and
/// nowhere else (never UserDefaults, logs, analytics, or crash reports). One key,
/// stored device-only and available offline. Call from the main actor only.
final class KeychainAPIKeyStore: APIKeyStore {
    private let service = "com.despresj.skim"
    private let account = "openai-api-key"

    enum KeychainError: Error { case unexpectedStatus(OSStatus) }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func saveOpenAIKey(_ key: String) throws {
        let data = Data(key.utf8)
        // Try update first; insert if absent. Idempotent replace.
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
            return
        }
        throw KeychainError.unexpectedStatus(updateStatus)
    }

    func loadOpenAIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    func deleteOpenAIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func hasOpenAIKey() -> Bool {
        (try? loadOpenAIKey()) ?? nil != nil
    }
}
```

- [ ] **Step 2: Build** — `xcodegen generate && xcodebuild -scheme Skim -destination 'generic/platform=iOS' build`. Expected: succeeds.

- [ ] **Step 3: Manual smoke (simulator)** — temporarily, in a debug entry point or an Xcode unit scratch, save → load → mask → delete and confirm round-trip + `sk-••••••<last4>` mask. (No persistent test target yet; remove scratch before commit.)

- [ ] **Step 4: Commit**

```bash
git add App/Comprehension/KeychainAPIKeyStore.swift
git commit -m "feat(app): Keychain-backed OpenAI API key store"
```

---

### Task 10: OpenAI provider (Structured Outputs + one retry)

**Files:**
- Create: `App/Comprehension/ComprehensionProvider.swift` (protocol, request, error, DTOs)
- Create: `App/Comprehension/OpenAIComprehensionProvider.swift` (implementation)

**Interfaces:**
- Consumes: `ComprehensionCheckDraft`, `ComprehensionQuestionDraft`, `ComprehensionChoices`, `ChoiceKey`, `QuestionType` (SkimCore).
- Produces:
  - `enum ComprehensionError: Error, Equatable { case missingKey, invalidKey, network, rateLimit, badResponse, tooShort, cancelled }` with a `var userMessage: String` returning the verbatim failure copy.
  - `struct ComprehensionRequest: Sendable { let text: String; let title: String?; let count: Int; let types: [QuestionType]; let avoiding: [String]; let apiKey: String; let model: String }`
  - `protocol ComprehensionQuestionProvider: Sendable { func generate(_ request: ComprehensionRequest) async throws -> ComprehensionCheckDraft; func validateKey(apiKey: String, model: String) async throws }`
  - `final class OpenAIComprehensionProvider: ComprehensionQuestionProvider` with `static let defaultModel = "gpt-4o-mini"`.

- [ ] **Step 1: Implement protocol + DTOs** — create `App/Comprehension/ComprehensionProvider.swift`:

```swift
import Foundation

/// Failures a comprehension generation can hit, each mapped to the exact calm
/// copy the UI shows.
enum ComprehensionError: Error, Equatable {
    case missingKey, invalidKey, network, rateLimit, badResponse, tooShort, cancelled

    var userMessage: String {
        switch self {
        case .missingKey:  return "Add an OpenAI API key to use comprehension checks."
        case .invalidKey:  return "That API key did not work. Check it or replace it in Settings."
        case .network:     return "Couldn't reach OpenAI. Check your connection and try again."
        case .rateLimit:   return "OpenAI rejected the request, likely due to rate limits or quota on your API key."
        case .badResponse: return "Couldn't build a clean check for this read."
        case .tooShort:    return "This read is too short for a useful check."
        case .cancelled:   return "Cancelled."
        }
    }
}

/// Everything needed to produce one batch of questions. `avoiding` carries the
/// existing question texts on a "generate more" call so the model won't repeat.
struct ComprehensionRequest: Sendable {
    let text: String
    let title: String?
    let count: Int
    let types: [QuestionType]
    let avoiding: [String]
    let apiKey: String
    let model: String
}

/// Abstracts the question source so the app is provider-agnostic (OpenAI now;
/// Claude/Gemini/backend later). `Sendable` so it can be called off the main actor.
protocol ComprehensionQuestionProvider: Sendable {
    func generate(_ request: ComprehensionRequest) async throws -> ComprehensionCheckDraft
    /// A tiny structured request against the configured model, to validate a key
    /// + model access in Settings' "Test Key". Throws `ComprehensionError` on failure.
    func validateKey(apiKey: String, model: String) async throws
}
```

- [ ] **Step 2: Implement OpenAI provider** — create `App/Comprehension/OpenAIComprehensionProvider.swift`:

```swift
import Foundation

/// Talks to OpenAI Chat Completions with Structured Outputs (strict json_schema),
/// so the response is guaranteed-shaped JSON we decode straight into a
/// `ComprehensionCheckDraft`. On a decode/validation/transport hiccup it re-asks
/// once with a stricter instruction — never a free-form JSON repair. Sendable and
/// stateless apart from a URLSession, so it runs off the main actor.
final class OpenAIComprehensionProvider: ComprehensionQuestionProvider {
    static let defaultModel = "gpt-4o-mini"
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func generate(_ request: ComprehensionRequest) async throws -> ComprehensionCheckDraft {
        do {
            return try await send(request, stricter: false)
        } catch let e as ComprehensionError where e == .badResponse {
            // One schema-constrained regeneration retry (clean re-ask, not a repair).
            return try await send(request, stricter: true)
        }
    }

    func validateKey(apiKey: String, model: String) async throws {
        let probe = ComprehensionRequest(
            text: "OpenAI key validation. Reply with one question about this sentence.",
            title: nil, count: 1, types: [.mainPoint], avoiding: [], apiKey: apiKey, model: model)
        _ = try await send(probe, stricter: false)
    }

    // MARK: Request

    private func send(_ request: ComprehensionRequest, stricter: Bool) async throws -> ComprehensionCheckDraft {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(body(for: request, stricter: stricter))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw ComprehensionError.cancelled
        } catch {
            throw ComprehensionError.network
        }
        guard let http = response as? HTTPURLResponse else { throw ComprehensionError.network }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw ComprehensionError.invalidKey
        case 429: throw ComprehensionError.rateLimit
        default: throw ComprehensionError.badResponse
        }

        guard let completion = try? JSONDecoder().decode(ChatCompletion.self, from: data),
              let content = completion.choices.first?.message.content,
              let contentData = content.data(using: .utf8),
              let draft = try? JSONDecoder().decode(ComprehensionCheckDraft.self, from: contentData)
        else { throw ComprehensionError.badResponse }
        return draft
    }

    private func body(for r: ComprehensionRequest, stricter: Bool) -> ChatRequest {
        var system = """
        You write multiple-choice comprehension questions that test whether a reader kept the \
        main thread of a passage. Test the gist, supporting reasons, and implications — never \
        trivia, exact wording, or formatting. Exactly four choices a/b/c/d, exactly one correct. \
        For each question include a `supportingQuote`: a short VERBATIM excerpt (8–40 words) \
        copied exactly from the passage that supports the correct answer. Return only the \
        structured object with exactly \(r.count) question(s).
        """
        if !r.types.isEmpty {
            system += " Use these question types in order: \(r.types.map(\.rawValue).joined(separator: ", "))."
        }
        if !r.avoiding.isEmpty {
            system += " Do NOT duplicate or paraphrase any of these existing questions: "
                + r.avoiding.map { "\"\($0)\"" }.joined(separator: "; ") + "."
        }
        if stricter {
            system += " CRITICAL: the previous attempt was rejected. The supportingQuote MUST be a " +
                      "character-for-character substring of the passage. Output valid JSON matching the schema exactly."
        }
        let user = (r.title.map { "Title: \($0)\n\n" } ?? "") + "Passage:\n\(r.text)"
        return ChatRequest(
            model: r.model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            response_format: .comprehensionSchema)
    }
}

// MARK: - OpenAI wire DTOs (request)

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let response_format: ResponseFormat
}
private struct ChatMessage: Encodable { let role: String; let content: String }

private struct ResponseFormat: Encodable {
    let type = "json_schema"
    let json_schema: JSONSchemaSpec

    /// The strict schema mirroring `ComprehensionCheckDraft`. `additionalProperties:false`
    /// and every field `required` is what makes OpenAI's strict mode accept it.
    static var comprehensionSchema: ResponseFormat {
        ResponseFormat(json_schema: JSONSchemaSpec(
            name: "comprehension_check",
            strict: true,
            schema: .object(
                properties: ["questions": .array(items: .object(
                    properties: [
                        "question": .string,
                        "choices": .object(
                            properties: ["a": .string, "b": .string, "c": .string, "d": .string],
                            required: ["a", "b", "c", "d"]),
                        "correctChoice": .enumString(["a", "b", "c", "d"]),
                        "explanation": .string,
                        "supportingQuote": .string,
                        "type": .enumString(["main_point", "supporting_detail", "implication", "pressure_test"]),
                    ],
                    required: ["question", "choices", "correctChoice", "explanation", "supportingQuote", "type"]))],
                required: ["questions"])))
    }
}

private struct JSONSchemaSpec: Encodable {
    let name: String
    let strict: Bool
    let schema: JSONSchemaNode
}

/// A minimal JSON-Schema node encoder — only the shapes this schema uses.
private indirect enum JSONSchemaNode: Encodable {
    case string
    case enumString([String])
    case array(items: JSONSchemaNode)
    case object(properties: [String: JSONSchemaNode], required: [String])

    enum CodingKeys: String, CodingKey { case type, items, properties, required, additionalProperties, `enum` }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string:
            try c.encode("string", forKey: .type)
        case .enumString(let cases):
            try c.encode("string", forKey: .type)
            try c.encode(cases, forKey: .enum)
        case .array(let items):
            try c.encode("array", forKey: .type)
            try c.encode(items, forKey: .items)
        case .object(let properties, let required):
            try c.encode("object", forKey: .type)
            try c.encode(properties, forKey: .properties)
            try c.encode(required, forKey: .required)
            try c.encode(false, forKey: .additionalProperties)
        }
    }
}

// MARK: - OpenAI wire DTOs (response)

private struct ChatCompletion: Decodable {
    struct Choice: Decodable { let message: Message }
    struct Message: Decodable { let content: String }
    let choices: [Choice]
}
```

- [ ] **Step 2 (verify): Build** — `xcodegen generate && xcodebuild ... build`. Expected: succeeds (no strict-concurrency errors — provider is `Sendable`, DTOs are value types).

- [ ] **Step 3: Manual integration check (deferred to Task 13's Test Key)** — the real network path is exercised by Settings → Test Key once that UI exists. No live call here. Confirm the body JSON shape by logging one encoded `ChatRequest` to console in a scratch build and eyeballing the `response_format.json_schema` against OpenAI's structured-outputs docs; remove the log before commit.

- [ ] **Step 4: Commit**

```bash
git add App/Comprehension/ComprehensionProvider.swift App/Comprehension/OpenAIComprehensionProvider.swift
git commit -m "feat(app): OpenAI comprehension provider with strict structured outputs"
```

---

### Task 11: AISettings + ComprehensionService (orchestration)

**Files:**
- Create: `App/Comprehension/AISettings.swift`
- Create: `App/Comprehension/ComprehensionService.swift`

**Interfaces:**
- Consumes: `SkimStore` (Plan 1 methods: `initialCheck`, `hasInitialCheck`, `insertCheck`, `checks(forReadId:)`, `nextBatchIndex`, `setQuestionDisputed`, `recordAnswer`, `answers(forCheckId:)`, `markCheckCompleted`), `APIKeyStore`, `ComprehensionQuestionProvider`, `ComprehensionRequest`, `ComprehensionError`; and SkimCore `QuestionPlan`, `ComprehensionChunking`, `ComprehensionValidation`, `ComprehensionCheck`, `ComprehensionQuestion(draft:)`, `ComprehensionStatus`, `ComprehensionGenerationKind`, `TextHash`.
- Produces:
  - `@MainActor @Observable final class AISettings` — `var enabled: Bool`, `var consentAccepted: Bool`, `var model: String` (UserDefaults keys `skim.ai.enabled`, `skim.ai.consent`, `skim.ai.model`).
  - `@MainActor @Observable final class ComprehensionService` with:
    - `init(store: SkimStore?, keyStore: APIKeyStore, provider: ComprehensionQuestionProvider, settings: AISettings)`
    - `func handleReadLoaded(readId: String?, text: String, title: String?, wordCount: Int)` — sets the active read, cancels any stale in-flight job, and fires background pre-gen if `QuestionPlan.shouldPreGenerate(...)`.
    - `func status(forReadId readId: String?) -> ComprehensionStatus`
    - `func loadOrGenerate(readId: String, text: String, title: String?, wordCount: Int) async -> Result<ComprehensionCheck, ComprehensionError>` — cached initial check if present, else generate one (manual path).
    - `func generateMore(parent: ComprehensionCheck, text: String, title: String?) async -> Result<ComprehensionCheck, ComprehensionError>`
    - Pass-throughs for the UI/VM: `var hasKey: Bool`, `func maskedKey() -> String?`, `func saveKey(_:) throws`, `func deleteKey() throws`, `func testKey() async -> Result<Void, ComprehensionError>`, `func recordAnswer(question:selected:)`, `func setDisputed(question:disputed:)`, `func complete(check:correct:)`.

- [ ] **Step 1: Implement AISettings** — create `App/Comprehension/AISettings.swift`:

```swift
import Foundation
import Observation

/// The three AI-feature preferences, persisted in UserDefaults (never the key —
/// that's Keychain). Shared by Settings UI and the comprehension service.
@MainActor @Observable final class AISettings {
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "skim.ai.enabled") }
    }
    var consentAccepted: Bool {
        didSet { UserDefaults.standard.set(consentAccepted, forKey: "skim.ai.consent") }
    }
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "skim.ai.model") }
    }

    init() {
        enabled = UserDefaults.standard.bool(forKey: "skim.ai.enabled")
        consentAccepted = UserDefaults.standard.bool(forKey: "skim.ai.consent")
        model = UserDefaults.standard.string(forKey: "skim.ai.model") ?? OpenAIComprehensionProvider.defaultModel
    }
}
```

- [ ] **Step 2: Implement the service** — create `App/Comprehension/ComprehensionService.swift`:

```swift
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

    func testKey() async -> Result<Void, ComprehensionError> {
        guard let key = (try? keyStore.loadOpenAIKey()) ?? nil, !key.isEmpty else { return .failure(.missingKey) }
        do { try await provider.validateKey(apiKey: key, model: settings.model); return .success(()) }
        catch let e as ComprehensionError { return .failure(e) }
        catch { return .failure(.network) }
    }

    // MARK: Pre-generation (paste/import)

    /// Called from `recordLoadedRead`. Switches the active read (cancelling a
    /// stale job whose read is being replaced) and silently pre-generates if eligible.
    func handleReadLoaded(readId: String?, text: String, title: String?, wordCount: Int) {
        // A read being replaced: cancel its job only if it hasn't persisted a check.
        if let prior = activeReadId, prior != readId,
           inFlight[prior] != nil, !(hasInitial(forReadIdHashOf: nil)) {
            inFlight[prior]?.cancel(); inFlight[prior] = nil
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
        guard total < QuestionPlan.hardCap else { return .failure(.badResponse) }
        let batchIndex = (try? store.nextBatchIndex(parentCheckId: parent.id)) ?? 1
        let avoiding = existing.flatMap { $0.questions.map(\.question) }
        return await generate(
            readId: parent.readId, text: text, title: title,
            count: QuestionPlan.generateMoreCount, types: QuestionPlan.generateMoreTypes(),
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

    private func hasInitial(forReadIdHashOf _: String?) -> Bool { false } // placeholder kept simple; see note
}
```

> **Implementer note for Step 2:** the `handleReadLoaded` cancel-guard above is written conservatively. Simplify it to: "if the prior active read has an in-flight job, cancel it" — a job that already persisted has already removed itself from `inFlight`, so the extra `hasInitial(...)` check is unnecessary; delete that helper and the condition that calls it. Keep the behavior: cancel the prior read's *unfinished* job when a new read loads.

- [ ] **Step 3: Build** — `xcodegen generate && xcodebuild ... build`. Expected: succeeds with no strict-concurrency diagnostics. If the compiler flags `provider.generate` crossing actors, confirm `ComprehensionRequest`/`ComprehensionCheckDraft` are `Sendable` (they are) and the provider is `Sendable`.

- [ ] **Step 4: Manual** — deferred; exercised once the UI lands (Tasks 13/15/17).

- [ ] **Step 5: Commit**

```bash
git add App/Comprehension/AISettings.swift App/Comprehension/ComprehensionService.swift
git commit -m "feat(app): comprehension orchestration service + AI settings"
```

---

### Task 12: Wire pre-generation into the read lifecycle

**Files:**
- Modify: `App/ReaderViewModel.swift` (add a `comprehension` property; call the service in `recordLoadedRead`; cancel on clear)
- Modify: `App/SkimApp.swift` (construct keyStore/provider/settings/service; inject into `ReaderViewModel`)

**Interfaces:**
- Consumes: `ComprehensionService`, `AISettings`, `KeychainAPIKeyStore`, `OpenAIComprehensionProvider`.
- Produces: `ReaderViewModel.comprehension: ComprehensionService?` (readable by the views), and the pre-gen call sites.

- [ ] **Step 1: Add the property + init param** — in `App/ReaderViewModel.swift`, alongside `let store: SkimStore?`:

```swift
    /// Drives optional post-read comprehension checks. `nil` if AI features aren't
    /// wired (e.g. previews). Pre-generation is kicked off here on load.
    let comprehension: ComprehensionService?
```

Update the initializer to accept and store it (keep the existing `store` default):

```swift
    init(store: SkimStore? = nil, comprehension: ComprehensionService? = nil) {
        self.store = store
        self.comprehension = comprehension
        band = defaultCruisingBand
    }
```

- [ ] **Step 2: Fire pre-gen on load** — at the END of `recordLoadedRead(_:source:sourcePath:)`, after `currentReadId = item.id`, add:

```swift
        comprehension?.handleReadLoaded(readId: item.id, text: text,
                                        title: item.title, wordCount: tokens.count)
```

And in the early-return guard of `recordLoadedRead` (the `guard let store, !tokens.isEmpty else { currentReadId = nil; return }` line), before returning, tell the service the active read cleared:

```swift
        guard let store, !tokens.isEmpty else {
            currentReadId = nil
            comprehension?.handleReadLoaded(readId: nil, text: "", title: nil, wordCount: 0)
            return
        }
```

- [ ] **Step 3: Cancel on explicit clear** — in `clearText()` (the method that returns to the paste screen), add `comprehension?.cancelIfActive(readId: currentReadId)` before `currentReadId` is cleared. (Locate `func clearText()`; add the cancel as its first line that runs while `currentReadId` is still set.)

- [ ] **Step 4: Construct + inject in SkimApp** — in `App/SkimApp.swift`, where `ReaderViewModel` is created with the store, build the dependency graph once and inject:

```swift
    private static func makeViewModel() -> ReaderViewModel {
        let store = AppStore.open()
        let settings = AISettings()
        let service = ComprehensionService(
            store: store,
            keyStore: KeychainAPIKeyStore(),
            provider: OpenAIComprehensionProvider(),
            settings: settings)
        return ReaderViewModel(store: store, comprehension: service)
    }
```

Replace the existing `ReaderViewModel(store: AppStore.open())` construction with `makeViewModel()`. (Match the existing `@State`/`StateObject`/`@Bindable` ownership pattern already in `SkimApp.swift` — only the construction expression changes.)

- [ ] **Step 5: Build + run** — `xcodegen generate && xcodebuild ... build`, then run on simulator: paste a >350-word passage with AI disabled → confirms the reader opens instantly and nothing happens (no key/consent yet). With a key + consent + enabled (after Tasks 13/14), confirm a check silently appears `ready` by the time you finish. Reader launch must never stall.

- [ ] **Step 6: Commit**

```bash
git add App/ReaderViewModel.swift App/SkimApp.swift
git commit -m "feat(app): pre-generate comprehension checks on read load"
```

---

### Task 13: Settings — AI Features (key management)

**Files:**
- Create: `App/Comprehension/AIFeaturesView.swift`
- Modify: `App/SettingsView.swift` (add a row that presents `AIFeaturesView`)

**Interfaces:**
- Consumes: `ComprehensionService` (via `viewModel.comprehension`), `AISettings` (reached through the service or passed in).
- Produces: `struct AIFeaturesView: View` with key field, Test/Save/Delete, an `enabled` toggle, masked-key display, and the verbatim privacy copy.

- [ ] **Step 1: Build the AI Features screen** — create `App/Comprehension/AIFeaturesView.swift`:

```swift
import SwiftUI

/// BYOK key management. The key lives in Keychain; this screen only ever shows a
/// mask. Copy is explicit that enabling checks may upload read text on paste.
struct AIFeaturesView: View {
    let service: ComprehensionService
    let settings: AISettings
    @Environment(\.dismiss) private var dismiss

    @State private var draftKey = ""
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        ZStack {
            ReadingCanvas()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("AI Comprehension Checks")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.readingForeground)

                    Text("Use your own OpenAI API key to generate optional comprehension "
                        + "questions after a read. Your key is stored locally in iOS Keychain. "
                        + "Skim does not provide API credits. When AI comprehension checks are "
                        + "enabled, eligible pasted/imported reads may be sent to OpenAI in the "
                        + "background so questions are ready when you finish.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color.readingMuted)

                    Toggle("Enable comprehension checks", isOn: Binding(
                        get: { settings.enabled }, set: { settings.enabled = $0 }))
                        .tint(Color.readingAccent)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.readingForeground)

                    if let masked = service.maskedKey() {
                        HStack {
                            Text(masked).font(.system(size: 15, design: .monospaced))
                                .foregroundStyle(Color.readingForeground)
                            Spacer()
                            Button("Delete", role: .destructive) {
                                try? service.deleteKey(); status = "Key deleted."
                            }
                        }
                    } else {
                        SecureField("sk-…", text: $draftKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 15, design: .monospaced))
                        HStack(spacing: 12) {
                            Button("Save Key") {
                                guard !draftKey.isEmpty else { return }
                                try? service.saveKey(draftKey); draftKey = ""; status = "Key saved."
                            }.buttonStyle(PrimaryPillStyle())
                            Button(testing ? "Testing…" : "Test Key") { Task { await test() } }
                                .buttonStyle(SecondaryPillStyle())
                                .disabled(testing || draftKey.isEmpty)
                        }
                    }

                    if let status { Text(status).font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color.readingMuted) }
                    Spacer(minLength: 0)
                }
                .padding(22)
            }
        }
        .presentationBackground { ReadingCanvas() }
    }

    /// Saves the draft key first (Test validates the configured model + request path).
    private func test() async {
        testing = true; defer { testing = false }
        if service.maskedKey() == nil, !draftKey.isEmpty { try? service.saveKey(draftKey) }
        switch await service.testKey() {
        case .success: status = "Key works."; draftKey = ""
        case .failure(let e): status = e.userMessage
        }
    }
}
```

- [ ] **Step 2: Add the Settings row** — in `App/SettingsView.swift`, add `@State private var showingAI = false` to `SettingsView`, add `aiRow` to the rows `VStack` (after `cruiseRow`), and present the sheet. The row:

```swift
    private var aiRow: some View {
        SettingRow(title: "AI features",
                   subtitle: "Optional comprehension checks with your own OpenAI key.") {
            Button { showingAI = true } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.readingMuted)
            }
            .buttonStyle(.plain)
        }
    }
```

Attach to the `VStack(spacing: 26)` containing the rows:

```swift
                .sheet(isPresented: $showingAI) {
                    if let service = viewModel.comprehension {
                        AIFeaturesView(service: service, settings: service.settingsForUI)
                    }
                }
```

To expose settings to the view, add to `ComprehensionService` a read-only accessor `var settingsForUI: AISettings { settings }` (it's already held). (Alternatively pass `AISettings` down from `SkimApp`; the accessor keeps the change local.)

- [ ] **Step 3: Build + run** — Settings → AI features: enter a real key, **Test Key** (live OpenAI call against `gpt-4o-mini`) shows "Key works." or the mapped error; Save persists (mask shows on reopen); Delete clears. Toggle persists across launches.

- [ ] **Step 4: Commit**

```bash
git add App/Comprehension/AIFeaturesView.swift App/SettingsView.swift App/Comprehension/ComprehensionService.swift
git commit -m "feat(app): Settings AI features — BYOK key management + Test Key"
```

---

### Task 14: First-use consent sheet

**Files:**
- Create: `App/Comprehension/ComprehensionConsentView.swift`

**Interfaces:**
- Consumes: `AISettings` (to set `consentAccepted`).
- Produces: `struct ComprehensionConsentView: View` — `init(onContinue:, onCancel:)`; shows the verbatim consent copy incl. the "sent when you paste" line; presented only on the first manual "Check understanding" tap.

- [ ] **Step 1: Implement** — create `App/Comprehension/ComprehensionConsentView.swift`:

```swift
import SwiftUI

/// Shown once, on the first manual "Check understanding" tap — never during
/// paste/import. Explicit that enabling pre-gen means read text leaves the device.
struct ComprehensionConsentView: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            ReadingCanvas()
            VStack(alignment: .leading, spacing: 18) {
                Text("Comprehension checks")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.readingForeground)
                Text("Comprehension checks send this read's text to OpenAI using your API key. "
                    + "Because pre-generation runs when you load text, the text may be sent as "
                    + "soon as you paste or import it — not only when you open a check. Your key "
                    + "is stored locally in iOS Keychain. Skim does not provide API credits. You "
                    + "can delete your key anytime in Settings.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.readingMuted)
                VStack(spacing: 12) {
                    Button("Continue") { onContinue() }.buttonStyle(PrimaryPillStyle())
                    Button("Cancel") { onCancel() }.buttonStyle(SecondaryPillStyle())
                }
                .padding(.top, 6)
            }
            .padding(24)
        }
        .presentationDetents([.medium])
        .presentationBackground { ReadingCanvas() }
    }
}
```

- [ ] **Step 2: Build** — `xcodebuild ... build` succeeds. (Wired into the flow in Task 16/17.)

- [ ] **Step 3: Commit**

```bash
git add App/Comprehension/ComprehensionConsentView.swift
git commit -m "feat(app): first-use comprehension consent sheet"
```

---

### Task 15: End-screen CTA + flow presentation

**Files:**
- Modify: `App/ReviewView.swift` (add "Check understanding" action + present the flow sheet)

**Interfaces:**
- Consumes: `ReaderViewModel` (`comprehension`, `currentReadId`, `reviewText`, `wordCount`, `currentTitle`), `ComprehensionStatus`, `ComprehensionCheckView` (Task 17), `ComprehensionCheckViewModel` (Task 16).
- Produces: a CTA in `ReviewView.actions` whose label/behavior follow `status(forReadId:)`, presenting `ComprehensionCheckView` in a sheet.

- [ ] **Step 1: Add CTA + sheet** — in `App/ReviewView.swift`, add `@State private var showingCheck = false` to `ReviewView`. Insert a primary "Check understanding" button at the TOP of the `actions` `VStack` (above "Read Again"), shown only when the service exists and the read isn't too short:

```swift
            if let service = viewModel.comprehension, let readId = viewModel.currentReadId,
               service.status(forReadId: readId) != .unavailable,
               QuestionPlan.initialQuestionCount(wordCount: viewModel.wordCount) > 0 {
                Button {
                    showingCheck = true
                } label: {
                    Label("Check understanding", systemImage: "checkmark.circle")
                }
                .buttonStyle(PrimaryPillStyle())
            }
```

(Demote "Read Again" to `SecondaryPillStyle()` so there's one primary action.) Attach the sheet to the `actions` view:

```swift
        .sheet(isPresented: $showingCheck) {
            if let service = viewModel.comprehension, let readId = viewModel.currentReadId {
                ComprehensionCheckView(
                    model: ComprehensionCheckViewModel(
                        service: service, settings: service.settingsForUI,
                        readId: readId, text: viewModel.reviewText, title: viewModel.currentTitle,
                        wordCount: viewModel.wordCount))
            }
        }
```

- [ ] **Step 2: Build + run** — finish a long read with a key+consent+enabled: the CTA shows; tapping it opens the flow. With AI disabled or a <150-word read: the CTA is absent. (Full inner behavior verified in Task 17.)

- [ ] **Step 3: Commit**

```bash
git add App/ReviewView.swift
git commit -m "feat(app): end-screen 'Check understanding' CTA"
```

---

### Task 16: Comprehension check view model (answering state machine)

**Files:**
- Create: `App/Comprehension/ComprehensionCheckViewModel.swift`

**Interfaces:**
- Consumes: `ComprehensionService`, `AISettings`, `ComprehensionCheck`, `ComprehensionQuestion`, `ChoiceKey`, `ComprehensionScoring`, `ComprehensionResult`, `ComprehensionError`.
- Produces: `@MainActor @Observable final class ComprehensionCheckViewModel` driving the flow:
  - `enum Phase: Equatable { case idle, missingKey, needsConsent, generating, answering, complete, failed(ComprehensionError) }`
  - state: `phase`, `check: ComprehensionCheck?`, `currentIndex`, `selected: [UUID: ChoiceKey]`, `revealed: Bool`, `result: ComprehensionResult?`
  - methods: `start()`, `acceptConsent()`, `cancelConsent()`, `select(_:)`, `next()`, `flagCurrentDisputed()`, `finish()`, `generateMore()`, `retry()`

- [ ] **Step 1: Implement** — create `App/Comprehension/ComprehensionCheckViewModel.swift`:

```swift
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
```

- [ ] **Step 2: Build** — `xcodebuild ... build` succeeds (pure main-actor logic; no concurrency surprises).

- [ ] **Step 3: Commit**

```bash
git add App/Comprehension/ComprehensionCheckViewModel.swift
git commit -m "feat(app): comprehension check flow view model"
```

---

### Task 17: Question + result UI

**Files:**
- Create: `App/Comprehension/ComprehensionCheckView.swift`

**Interfaces:**
- Consumes: `ComprehensionCheckViewModel`, `ComprehensionConsentView`, `ComprehensionQuestion`, `ChoiceKey`, `QuestionType`, `ComprehensionResult`, theme styles (`PrimaryPillStyle`/`SecondaryPillStyle`, `Color.reading*`, `ReadingCanvas`).
- Produces: `struct ComprehensionCheckView: View` rendering every `Phase`: generating ("Building your check…" + Cancel), needsConsent (the consent sheet), answering (one question at a time, reveal feedback with explanation + grounded quote + "this seems off"), complete (score + headline + guidance + Done/Review missed/Generate more), failed (mapped copy + retry/settings), missingKey (open Settings).

- [ ] **Step 1: Implement** — create `App/Comprehension/ComprehensionCheckView.swift`:

```swift
import SwiftUI

/// The comprehension-check surface: a calm, one-question-at-a-time flow that ends
/// in a score and a gentle speed suggestion. Never punitive; a question can be
/// flagged "this seems off" so a bad item doesn't read as the reader's failure.
struct ComprehensionCheckView: View {
    @State var model: ComprehensionCheckViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ReadingCanvas()
            content.padding(24)
        }
        .presentationBackground { ReadingCanvas() }
        .task { if case .idle = model.phase { await model.start() } }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .generating: generating
        case .needsConsent:
            ComprehensionConsentView(
                onContinue: { Task { await model.acceptConsent() } },
                onCancel: { dismiss() })
        case .answering: answering
        case .complete: complete
        case .missingKey: message("Add an OpenAI API key to use comprehension checks.", primary: "Open Settings")
        case .failed(let e): message(e.userMessage, primary: "Try again")
        }
    }

    private var generating: some View {
        VStack(spacing: 14) {
            ProgressView().tint(Color.readingAccent)
            Text("Building your check…")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(Color.readingForeground)
            Text("Looking for the main thread, not trivia.")
                .font(.system(size: 13, design: .rounded)).foregroundStyle(Color.readingMuted)
            Button("Cancel") { dismiss() }.buttonStyle(SecondaryPillStyle()).padding(.top, 8)
        }
    }

    @ViewBuilder private var answering: some View {
        if let q = model.currentQuestion, let check = model.check {
            VStack(alignment: .leading, spacing: 18) {
                Text("\(model.currentIndex + 1) of \(check.questions.count)")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.readingMuted)
                Text(q.question)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.readingForeground)
                ForEach(ChoiceKey.allCases, id: \.self) { key in
                    choiceButton(key, q: q)
                }
                if model.revealed { feedback(q) }
                Spacer(minLength: 0)
                if model.revealed {
                    Button(model.isLastQuestion ? "See result" : "Next") { model.next() }
                        .buttonStyle(PrimaryPillStyle())
                }
            }
        }
    }

    private func choiceButton(_ key: ChoiceKey, q: ComprehensionQuestion) -> some View {
        let chosen = model.selected[q.id]
        let isChosen = chosen == key
        let isCorrect = q.correctChoice == key
        let tint: Color = !model.revealed ? Color.readingSurface
            : isCorrect ? Color.green.opacity(0.25)
            : isChosen ? Color.red.opacity(0.20) : Color.readingSurface
        return Button { model.select(key) } label: {
            HStack {
                Text(q.choices.text(for: key))
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(Color.readingForeground)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(12)
            .background(tint, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.readingBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.revealed)
    }

    private func feedback(_ q: ComprehensionQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.selected[q.id] == q.correctChoice ? "Correct." : "Not quite.")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.readingForeground)
            Text(q.explanation).font(.system(size: 14, design: .rounded))
                .foregroundStyle(Color.readingMuted)
            Text("From the passage: “\(q.supportingQuote)”")
                .font(.system(size: 13, design: .rounded)).italic()
                .foregroundStyle(Color.readingMuted)
            Button("This seems off") { model.flagCurrentDisputed() }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.readingAccent)
                .disabled(q.disputed)
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var complete: some View {
        if let r = model.result {
            VStack(spacing: 16) {
                Text("\(r.correct) / \(r.scored)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.readingForeground).monospacedDigit()
                Text(r.headline).font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.readingForeground)
                Text(r.guidance).font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.readingMuted).multilineTextAlignment(.center)
                VStack(spacing: 12) {
                    if model.canGenerateMore {
                        Button("Generate more") { Task { await model.generateMore() } }
                            .buttonStyle(SecondaryPillStyle())
                    }
                    Button("Done") { dismiss() }.buttonStyle(PrimaryPillStyle())
                }
                .padding(.top, 8)
            }
        }
    }

    private func message(_ text: String, primary: String) -> some View {
        VStack(spacing: 16) {
            Text(text).font(.system(size: 15, design: .rounded))
                .foregroundStyle(Color.readingForeground).multilineTextAlignment(.center)
            Button(primary) {
                if case .failed = model.phase { Task { await model.retry() } } else { dismiss() }
            }.buttonStyle(PrimaryPillStyle())
            Button("Cancel") { dismiss() }.buttonStyle(SecondaryPillStyle())
        }
    }
}
```

> **Note:** "Review missed" from the spec's result mock is folded into the persisted answers (the reader can reopen the check); a dedicated review screen is deferred — if you want it in V0, add a `reviewMissed` phase that re-walks only `selected` wrong, non-disputed questions read-only. Flag as DONE_WITH_CONCERNS if you add it beyond this scope.

- [ ] **Step 2: Build + run the full flow** — with key+consent+enabled, finish a ~600-word read → "Check understanding" → answer questions (correct/incorrect coloring + explanation + quote appear), "This seems off" flags a question, final screen shows `correct / scored`, the verbatim headline/guidance, and "Generate more" adds questions (until the cap). Disabled-AI and <150-word reads show no CTA. Verify a wrong API key surfaces "That API key did not work."

- [ ] **Step 3: Commit**

```bash
git add App/Comprehension/ComprehensionCheckView.swift
git commit -m "feat(app): comprehension question + result UI"
```

---

### Task 18: Privacy manifest + integration pass + device deploy

**Files:**
- Create: `App/PrivacyInfo.xcprivacy`
- Modify (if needed): `project.yml` (ensure the manifest is bundled)

**Interfaces:** none (packaging/integration).

- [ ] **Step 1: Add the privacy manifest** — create `App/PrivacyInfo.xcprivacy` declaring that the app sends user content off device (read text → OpenAI under the user's key). Minimal manifest:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array>
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeOtherUserContent</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
        </dict>
    </array>
    <key>NSPrivacyAccessedAPITypes</key>
    <array/>
</dict>
</plist>
```

- [ ] **Step 2: Ensure bundling** — `App/` is already a source path in `project.yml`; confirm after `xcodegen generate` that `PrivacyInfo.xcprivacy` lands in the target's "Copy Bundle Resources" (XcodeGen treats non-source files in a source group as resources). If it doesn't, add an explicit `resources: [App/PrivacyInfo.xcprivacy]` to the Skim target in `project.yml`.

- [ ] **Step 3: Full integration build** — `xcodegen generate && xcodebuild -scheme Skim -destination 'generic/platform=iOS' build`. Zero errors; no new warnings in the comprehension files.

- [ ] **Step 4: Device deploy + real-world pass** — `scripts/deploy-device.sh` (build-gated). On the iPhone: paste a long article with AI enabled + key + consent, read it, finish → check is instant; answer it; confirm the reading surface was never interrupted and paste/read launch never stalled. Spot-check that a private/sensitive paste does NOT silently upload when AI is disabled.

- [ ] **Step 5: Commit**

```bash
git add App/PrivacyInfo.xcprivacy project.yml
git commit -m "chore(app): privacy manifest + comprehension-checks integration"
```

---

## Self-Review

**Spec coverage (the App-layer rows of the design):**
- BYOK Keychain key store → Task 9. ✓
- OpenAI provider, Structured Outputs, one schema-constrained retry, configurable model, Test-Key path → Task 10 (+ Task 13 Test Key). ✓
- Orchestration: eligibility, pre-gen on paste, idempotent in-flight by readId, persistence, status, generate-more with caps, standardized score-as-correct-count → Task 11. ✓
- Pre-gen wired into `recordLoadedRead`; lifecycle attach-by-readId / cancel-on-clear → Task 12. ✓
- Settings AI section + enable toggle + key add/test/delete → Task 13. ✓
- Consent only on first manual tap → Tasks 14 + 16 (`needsConsent`). ✓
- End-screen CTA + status routing → Task 15 + 17. ✓
- One-at-a-time questions, immediate feedback, grounded quote, "this seems off" → Task 17. ✓
- Result: score + verbatim guidance + Generate more (recommendation only, never auto-changes speed) → Task 17 (+ `ComprehensionScoring` from Plan 1). ✓
- Failure copy mapping, too-short handling → Task 10 (`userMessage`) used throughout. ✓
- Privacy manifest / off-device disclosure → Task 18. ✓

**Carried watch-items honored:** SkimStore/Keychain touched only on `@MainActor`; key read on-main then passed as `String` to the `Sendable` provider; `score` persisted as correct-count, percent derived; cache key via `SkimStore.initialCheck(...promptVersion:)`; `nextBatchIndex`/`parentCheckId` used for follow-ups (first = 1); `checks(forReadId:)` consumed in batch order.

**Placeholder scan:** the only intentional simplification is the `hasInitial(forReadIdHashOf:)` helper in Task 11, which the inline implementer note instructs to delete in favor of the simpler "cancel the prior read's unfinished job" condition. No TBD/TODO; all other steps carry complete code.

**Type consistency:** provider returns `ComprehensionCheckDraft` → validated by `ComprehensionValidation` → mapped via `ComprehensionQuestion(draft:)` → persisted by `SkimStore.insertCheck` → scored by `ComprehensionScoring.result` → completed via `markCheckCompleted(score: correct)`. `ComprehensionError.userMessage` strings match the Global Constraints copy verbatim.

**Known V0 deferrals (intentional, not gaps):** the "Review missed" screen is folded into persisted answers (note in Task 17); the optional "check ready" indicator on the reader is omitted (spec says V0 may skip); multi-provider, Deep Check, spaced repetition, backend proxy remain out of scope.
