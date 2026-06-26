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
