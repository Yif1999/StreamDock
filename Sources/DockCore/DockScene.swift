/// What a scene needs from the core. Implemented by `DockController`.
@MainActor
protocol SceneHost: AnyObject {
    var alerts: AlertCenter { get }
    func redraw(keys: [Int])
}

/// One full-screen layout bound to a round key. Scenes never see each other:
/// each lives in its own target and talks only to the core.
@MainActor
open class DockScene {
    public let id: String
    public let name: String
    /// Light-strip color while this scene is active (user can override in settings).
    public let defaultLEDColor: RGB

    public private(set) var isActive = false
    weak var host: SceneHost?

    private var placements: [(module: DockModule, keys: [Int])] = []
    private var slotForKey: [Int: (module: DockModule, slot: Int)] = [:]

    public init(id: String, name: String, defaultLEDColor: RGB) {
        self.id = id
        self.name = name
        self.defaultLEDColor = defaultLEDColor
    }

    /// Places a module on LCD keys (1–15, row by row from the top-left), one key per slot.
    public func place(_ module: DockModule, keys: [Int]) {
        precondition(keys.count == module.keyCount, "\(type(of: module)) needs \(module.keyCount) keys, got \(keys.count)")
        for key in keys {
            precondition((1...15).contains(key), "Key \(key) out of range")
            precondition(slotForKey[key] == nil, "Key \(key) is already used in scene \(id)")
        }
        placements.append((module, keys))
        for (slot, key) in keys.enumerated() {
            slotForKey[key] = (module, slot)
        }
        module.attach(ModuleContext(scene: self, keys: keys))
    }

    func face(forKey key: Int) -> KeyFace {
        guard let (module, slot) = slotForKey[key] else { return .blank }
        return module.face(forSlot: slot)
    }

    func keyDown(_ key: Int) {
        guard let (module, slot) = slotForKey[key] else { return }
        module.keyDown(slot: slot)
    }

    func keyUp(_ key: Int) {
        guard let (module, slot) = slotForKey[key] else { return }
        module.keyUp(slot: slot)
    }

    func hasModule(onKey key: Int) -> Bool { slotForKey[key] != nil }

    func activate() {
        isActive = true
        placements.forEach { $0.module.sceneDidActivate() }
    }

    func deactivate() {
        isActive = false
        placements.forEach { $0.module.sceneDidDeactivate() }
    }
}

/// Row/column helper: `KeyGrid.key(row: 0, column: 0)` is the top-left key (1).
public enum KeyGrid {
    public static func key(row: Int, column: Int) -> Int { row * 5 + column + 1 }
}
