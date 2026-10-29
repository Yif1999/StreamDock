import Foundation

/// A scene's persistent activities (e.g. OBS recording), above its own animation and color.
/// Alerts still take precedence.
@MainActor
public final class LightActivityCenter {
    private struct Entry { let priority: Int; let animation: LightAnimation }
    private var entries: [String: Entry] = [:]
    /// Called with how long the strip should take to ease into the change.
    var onChange: ((TimeInterval) -> Void)?
    public init() {}

    /// `fade`: how long the strip eases into the change (an activity that ends after its own
    /// fade-out may want longer than the default).
    public func set(_ animation: LightAnimation?, for id: String, priority: Int = 100, fade: TimeInterval = 0.6) {
        if let animation {
            if let old = entries[id], old.animation === animation, old.priority == priority { return }
            entries[id] = Entry(priority: priority, animation: animation)
        } else {
            guard entries.removeValue(forKey: id) != nil else { return }
        }
        onChange?(fade)
    }

    var leading: LightAnimation? {
        entries.sorted {
            $0.value.priority == $1.value.priority ? $0.key < $1.key : $0.value.priority > $1.value.priority
        }.first?.value.animation
    }

    func source(alert: RGB?, sceneAnimation: LightAnimation?, sceneColor: RGB) -> LightEngine.Source {
        if let alert { return .solid(alert, active: true) }
        if let leading { return .animation(leading) }
        if let sceneAnimation { return .animation(sceneAnimation) }
        return .solid(sceneColor)
    }
}

/// Perceived brightness combines the user setting with a smooth 50%/100% activity gain.
struct LightBrightness {
    private(set) var target: Double = 50
    private var from: Double = 50
    private var started: TimeInterval = -.infinity
    static let duration = 0.6

    mutating func setTarget(_ value: Double, at time: TimeInterval) {
        guard target != value else { return }
        from = level(at: time)
        target = value
        started = time
    }
    func level(at time: TimeInterval) -> Double {
        let progress = min(1, max(0, (time - started) / Self.duration))
        let eased = Motion.light.ease(progress)
        return from + (target - from) * eased
    }
    func isAnimating(at time: TimeInterval) -> Bool { time - started < Self.duration }
}
