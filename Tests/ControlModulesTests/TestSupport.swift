import Foundation
@testable import ControlModules

/// Settings in a temporary file instead of `~/Library/Preferences`, deleted by `cleanup`.
/// (Removing a named suite's domain still leaves an empty plist behind there.)
func temporaryDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("StreamDock.Tests.\(UUID())").path
    let defaults = UserDefaults(suiteName: path)!
    return (defaults, {
        defaults.removePersistentDomain(forName: path)
        try? FileManager.default.removeItem(atPath: path + ".plist")
    })
}

/// Secrets kept in memory instead of the keychain.
final class MemorySecrets: SecretStore {
    var values: [String: String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func save(_ token: String, account: String) throws { values[account] = token }
    func delete(account: String) throws { values.removeValue(forKey: account) }
}
