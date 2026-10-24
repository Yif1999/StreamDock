import Foundation
import Security

protocol HATokenStore {
    func read(account: String) throws -> String?
    func save(_ token: String, account: String) throws
    func delete(account: String) throws
}

struct HAKeychain: HATokenStore {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.yif.StreamDock.HomeAssistant",
         kSecAttrAccount as String: account]
    }
    func read(account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw HAFailure.message("无法读取钥匙串中的 HA 令牌（\(status)）") }
        return String(data: data, encoding: .utf8)
    }
    func save(_ token: String, account: String) throws {
        let data = Data(token.utf8)
        let q = query(account)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = q
            entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw HAFailure.message("无法保存 HA 令牌到钥匙串（\(status)）") }
    }
    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HAFailure.message("无法删除 HA 令牌（\(status)）") }
    }
}
