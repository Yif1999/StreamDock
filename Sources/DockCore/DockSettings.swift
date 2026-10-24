import Foundation
import Observation

/// User preferences, persisted in the app's UserDefaults.
@MainActor
@Observable
public final class DockSettings {
    /// LCD backlight, 0–100.
    public var screenBrightness: Int {
        didSet { defaults.set(screenBrightness, forKey: Keys.screenBrightness) }
    }

    /// Light strip, 0–100.
    public var ledBrightness: Int {
        didSet { defaults.set(ledBrightness, forKey: Keys.ledBrightness) }
    }

    /// Scene id -> light-strip color chosen by the user.
    public var ledColorOverrides: [String: RGB] {
        didSet { defaults.set(try? JSONEncoder().encode(ledColorOverrides), forKey: Keys.ledColors) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let screenBrightness = "screenBrightness"
        static let ledBrightness = "ledBrightness"
        static let ledColors = "ledColorOverrides"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        screenBrightness = defaults.object(forKey: Keys.screenBrightness) as? Int ?? 80
        ledBrightness = defaults.object(forKey: Keys.ledBrightness) as? Int ?? 100
        ledColorOverrides = defaults.data(forKey: Keys.ledColors)
            .flatMap { try? JSONDecoder().decode([String: RGB].self, from: $0) } ?? [:]
    }
}
