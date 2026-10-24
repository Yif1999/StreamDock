/// What a scene needs from the core. Implemented by `DockController`.
@MainActor
protocol SceneHost: AnyObject {
    var alerts: AlertCenter { get }
    func redraw(keys: [Int])
    func lightDidChange(in scene: DockScene)
}

/// One full-screen layout bound to a round key. Scenes never see each other:
/// each lives in its own target and talks only to the core.
@MainActor
open class DockScene {
    public let id: String
    public let name: String
    public let pageTitles: [String]
    public private(set) var currentPageIndex = 0
    /// Light-strip color while this scene is active (user can override in settings).
    public let defaultLEDColor: RGB

    public private(set) var isActive = false
    weak var host: SceneHost?
    /// Set by a module; shown instead of `defaultLEDColor` while the scene is active.
    var light: LightAnimation? { pageLights[currentPageIndex] }
    private var pageLights: [Int: LightAnimation] = [:]

    private var placements: [(module: DockModule, keys: [Int], page: Int)] = []
    private var slots: [Int: [Int: (module: DockModule, slot: Int)]] = [:]

    public init(id: String, name: String, defaultLEDColor: RGB, pageTitles: [String] = ["主页"]) {
        precondition(!pageTitles.isEmpty)
        self.pageTitles = pageTitles
        self.id = id
        self.name = name
        self.defaultLEDColor = defaultLEDColor
    }

    /// Places a module on LCD keys (1–15, row by row from the top-left), one key per slot.
    public func place(_ module: DockModule, keys: [Int], page: Int = 0) {
        precondition(pageTitles.indices.contains(page))
        precondition(keys.count == module.keyCount, "\(type(of: module)) needs \(module.keyCount) keys, got \(keys.count)")
        for key in keys {
            precondition((1...15).contains(key), "Key \(key) out of range")
            precondition(slots[page]?[key] == nil, "Key \(key) is already used in scene \(id)")
        }
        placements.append((module, keys, page))
        for (slot, key) in keys.enumerated() {
            slots[page, default: [:]][key] = (module, slot)
        }
        module.attach(ModuleContext(scene: self, keys: keys, page: page))
    }

    func face(forKey key: Int) -> KeyFace {
        guard let (module, slot) = slots[currentPageIndex]?[key] else { return .blank }
        return module.face(forSlot: slot)
    }

    func keyDown(_ key: Int) {
        guard let (module, slot) = slots[currentPageIndex]?[key] else { return }
        module.keyDown(slot: slot)
    }

    func keyUp(_ key: Int) {
        guard let (module, slot) = slots[currentPageIndex]?[key] else { return }
        module.keyUp(slot: slot)
    }

    func hasModule(onKey key: Int) -> Bool { slots[currentPageIndex]?[key] != nil }

    func setLight(_ animation: LightAnimation?, page: Int) {
        guard animation !== pageLights[page] else { return }
        pageLights[page] = animation
        if page == currentPageIndex { host?.lightDidChange(in: self) }
    }

    func advancePage() {
        guard pageTitles.count > 1 else { return }
        let wasActive = isActive
        if wasActive { deactivate() }
        currentPageIndex = (currentPageIndex + 1) % pageTitles.count
        if wasActive { activate() }
    }

    func activate() {
        isActive = true
        placements.filter { $0.page == currentPageIndex }.forEach { $0.module.sceneDidActivate() }
    }

    func deactivate() {
        isActive = false
        placements.filter { $0.page == currentPageIndex }.forEach { $0.module.sceneDidDeactivate() }
    }
}

/// Row/column helper: `KeyGrid.key(row: 0, column: 0)` is the top-left key (1).
public enum KeyGrid {
    public static func key(row: Int, column: Int) -> Int { row * 5 + column + 1 }
}
