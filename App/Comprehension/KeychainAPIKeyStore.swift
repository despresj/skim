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
