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
