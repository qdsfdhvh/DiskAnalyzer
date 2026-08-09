import Foundation
import Security

// MARK: - Seam

/// Stores and loads the user's API key. The real adapter uses the Keychain;
/// tests use an in-memory fake.
protocol APIKeyStoring: Sendable {
    func store(key: String, for account: String) throws
    func loadKey(for account: String) throws -> String?
    func deleteKey(for account: String) throws
}

enum KeychainError: Error, Equatable {
    case status(OSStatus)
}

// MARK: - Keychain adapter

struct KeychainAPIKeyStore: APIKeyStoring, Sendable {

    private let serviceName: String

    init(serviceName: String = "com.diskanalyzer.planning") {
        self.serviceName = serviceName
    }

    func store(key: String, for account: String) throws {
        try deleteKey(for: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.status(status)
        }
    }

    func loadKey(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    func deleteKey(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}
