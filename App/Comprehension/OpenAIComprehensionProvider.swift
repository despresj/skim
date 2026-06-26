import Foundation
import os

/// Talks to OpenAI Chat Completions with Structured Outputs (strict json_schema),
/// so the response is guaranteed-shaped JSON we decode straight into a
/// `ComprehensionCheckDraft`. On a decode/transport hiccup it re-asks once with a
/// stricter instruction — never a free-form JSON repair. Sendable and stateless
/// apart from a URLSession, so it runs off the main actor.
///
/// Transport, API-reject, and unreadable-body are kept as distinct errors and
/// logged precisely (status + redacted body / decode context) so a failure is
/// observable. Authorization headers and the request body are never logged.
final class OpenAIComprehensionProvider: ComprehensionQuestionProvider {
    static let defaultModel = "gpt-5.5"
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private let session: URLSession
    private let log = Logger(subsystem: "com.despresj.skim", category: "comprehension")

    init(session: URLSession = .shared) { self.session = session }

    func generate(_ request: ComprehensionRequest) async throws -> ComprehensionCheckDraft {
        do {
            return try await send(request, stricter: false)
        } catch let e as ComprehensionError where e == .apiError || e == .decodeError {
            // One schema-constrained regeneration retry (clean re-ask, not a repair).
            log.notice("comprehension: retrying once after \(String(describing: e), privacy: .public)")
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
        guard let http = response as? HTTPURLResponse else {
            log.error("comprehension: response was not HTTP")
            throw ComprehensionError.network
        }
        let body = String(data: data, encoding: .utf8) ?? "<\(data.count) non-utf8 bytes>"
        switch http.statusCode {
        case 200: break
        case 401, 403:
            log.error("comprehension: auth rejected HTTP \(http.statusCode, privacy: .public) body=\(self.redact(body), privacy: .public)")
            throw ComprehensionError.invalidKey
        case 429:
            log.error("comprehension: rate limited HTTP 429 body=\(self.redact(body), privacy: .public)")
            throw ComprehensionError.rateLimit
        default:
            // The big one: a non-2xx we don't special-case (400 bad model/schema, 5xx…).
            log.error("comprehension: API error HTTP \(http.statusCode, privacy: .public) model=\(request.model, privacy: .public) body=\(self.redact(body), privacy: .public)")
            throw ComprehensionError.apiError
        }

        // 200, but the envelope / structured content may still not decode.
        guard let completion = try? JSONDecoder().decode(ChatCompletion.self, from: data) else {
            log.error("comprehension: decode FAILED on chat envelope; snippet=\(self.redact(body, max: 300), privacy: .public)")
            throw ComprehensionError.decodeError
        }
        guard let content = completion.choices.first?.message.content else {
            log.error("comprehension: decode FAILED — no message content (likely a model refusal)")
            throw ComprehensionError.decodeError
        }
        guard let contentData = content.data(using: .utf8),
              let draft = try? JSONDecoder().decode(ComprehensionCheckDraft.self, from: contentData)
        else {
            log.error("comprehension: decode FAILED on structured content; snippet=\(self.redact(content, max: 300), privacy: .public)")
            throw ComprehensionError.decodeError
        }
        return draft
    }

    /// Bound a server/response string for logging and strip anything shaped like an
    /// OpenAI key. We only ever pass *response* bodies here — never the request, the
    /// Authorization header, or the source text.
    private func redact(_ s: String, max: Int = 600) -> String {
        var t = s
        if let rx = try? NSRegularExpression(pattern: "sk-[A-Za-z0-9_-]{8,}") {
            t = rx.stringByReplacingMatches(
                in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "sk-***")
        }
        return t.count > max ? String(t.prefix(max)) + "…[truncated]" : t
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
