import Foundation
import Security

struct AppSettings: Codable, Equatable {
    var llmRefinementEnabled: Bool = false
    // API key is stored in macOS Keychain, not in the JSON file
    var apiKey: String {
        get { KeychainHelper.read(service: "com.whisperino.app", account: "langdock-api-key") ?? "" }
        set { KeychainHelper.save(service: "com.whisperino.app", account: "langdock-api-key", value: newValue) }
    }

    enum CodingKeys: String, CodingKey {
        case llmRefinementEnabled
    }
}

/// Minimal Keychain wrapper — stores secrets securely instead of in plaintext JSON
enum KeychainHelper {
    static func save(service: String, account: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Don't store empty strings — just delete
        guard !value.isEmpty else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}

struct DictionaryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var term: String

    init(id: UUID = UUID(), term: String) {
        self.id = id
        self.term = term
    }
}

struct Snippet: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, text: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.text = text
        self.createdAt = createdAt
    }
}
