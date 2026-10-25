import Foundation
import Security

/// Where a client keeps its secret (an access token or key), one per server address.
protocol SecretStore {
    func read(account: String) throws -> String?
    func save(_ secret: String, account: String) throws
    func delete(account: String) throws
}

struct KeychainFailure: LocalizedError {
    let errorDescription: String?
}

/// A secret in the login keychain, readable on this Mac only; `name` is how errors refer to it.
struct Keychain: SecretStore {
    let service: String
    let name: String
    static let homeAssistant = Keychain(service: "dev.yif.StreamDock.HomeAssistant", name: "HA 令牌")
    static let cpa = Keychain(service: "dev.yif.StreamDock.CPA", name: "CPA 管理密钥")

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    func read(account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainFailure(errorDescription: "无法读取钥匙串中的\(name)（\(status)）") }
        return String(data: data, encoding: .utf8)
    }
    func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let q = query(account)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = q
            entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainFailure(errorDescription: "无法把\(name)保存到钥匙串（\(status)）") }
    }
    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(errorDescription: "无法删除\(name)（\(status)）") }
    }
}
