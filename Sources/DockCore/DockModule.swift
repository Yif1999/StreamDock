/// A self-contained feature that owns a few LCD keys inside a scene
/// (e.g. "volume" owns down / mute / up).
///
/// Slots are numbered 0..<keyCount in the order the scene placed the module.
@MainActor
public protocol DockModule: AnyObject {
    var keyCount: Int { get }

    /// Called once when the module is placed in a scene.
    func attach(_ context: ModuleContext)
    func face(forSlot slot: Int) -> KeyFace
    func keyDown(slot: Int)
    func keyUp(slot: Int)
    /// The module's scene became the one on screen. Start polling or listening here.
    func sceneDidActivate()
    /// The module's scene left the screen. The module may keep working in the
    /// background but its keys will not be drawn.
    func sceneDidDeactivate()
}

public extension DockModule {
    func attach(_ context: ModuleContext) {}
    func keyDown(slot: Int) {}
    func keyUp(slot: Int) {}
    func sceneDidActivate() {}
    func sceneDidDeactivate() {}
}

/// A module's handle back to the core.
@MainActor
public final class ModuleContext {
    weak var scene: DockScene?
    let keys: [Int]

    init(scene: DockScene, keys: [Int]) {
        self.scene = scene
        self.keys = keys
    }

    /// True while the module's scene is on screen.
    public var isVisible: Bool { scene?.isActive ?? false }

    /// Redraws the module's keys. Ignored while the scene is in the background.
    public func setNeedsDisplay() {
        guard let scene, scene.isActive else { return }
        scene.host?.redraw(keys: keys)
    }

    /// Lets the module paint the light strip while its scene is on screen (nil gives the strip
    /// back to the scene color). The last module to call this wins within a scene.
    public func setLight(_ animation: LightAnimation?) {
        scene?.setLight(animation)
    }

    /// Global alerts work from any scene, active or not.
    public var alerts: AlertCenter? { scene?.host?.alerts }
}

/// A key that only shows something.
@MainActor
public final class LabelModule: DockModule {
    public let keyCount = 1
    private let face: KeyFace

    public init(_ face: KeyFace) {
        self.face = face
    }

    public func face(forSlot slot: Int) -> KeyFace { face }
}
