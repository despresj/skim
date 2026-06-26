import Foundation

/// Failures a comprehension generation can hit, each mapped to the exact calm
/// copy the UI shows. The three pipeline failures are split apart deliberately —
/// `apiError`, `decodeError`, and `validationFailed` used to be one opaque
/// `badResponse`, which hid whether OpenAI rejected us, returned an unreadable
/// body, or produced output that failed grounding. Each now logs its precise
/// internal reason locally (see `ComprehensionService`/`OpenAIComprehensionProvider`)
/// while keeping a user-safe message here.
enum ComprehensionError: Error, Equatable {
    case missingKey
    case invalidKey
    case rateLimit
    /// Couldn't reach OpenAI (transport) — DNS, offline, timeout.
    case network
    /// Reached OpenAI, but it returned a non-2xx we don't special-case (400/5xx…).
    case apiError
    /// 200, but the body wasn't the JSON/schema shape we decode.
    case decodeError
    /// Decoded fine, but failed SkimCore's structural/grounding validation.
    case validationFailed
    /// App-internal failure (no store, DB write failed, cap reached) — not the model's fault.
    case internalError
    case tooShort
    case cancelled

    var userMessage: String {
        switch self {
        case .missingKey:       return "Add an OpenAI API key to use comprehension checks."
        case .invalidKey:       return "That API key did not work. Check it or replace it in Settings."
        case .rateLimit:        return "OpenAI rejected the request, likely due to rate limits or quota on your API key."
        case .network, .apiError: return "Couldn't reach OpenAI or OpenAI rejected the request."
        case .decodeError:      return "OpenAI returned a response Skim couldn't read."
        case .validationFailed: return "Skim couldn't build a clean grounded check for this read."
        case .internalError:    return "Something went wrong building this check."
        case .tooShort:         return "This read is too short for a useful check."
        case .cancelled:        return "Cancelled."
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
