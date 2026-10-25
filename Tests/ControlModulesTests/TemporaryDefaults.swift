import Foundation

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
