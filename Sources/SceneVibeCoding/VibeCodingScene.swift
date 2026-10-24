import DockCore

/// Round key 2: AI coding tools (quota, task-finished alerts). Not built yet.
@MainActor
public func makeVibeCodingScene() -> DockScene {
    let scene = DockScene(id: "vibecoding", name: "VibeCoding", defaultLEDColor: RGB(hex: "#AF52DE"))
    scene.place(LabelModule(KeyFace(
        symbol: "chevron.left.forwardslash.chevron.right", caption: "VibeCoding", foreground: RGB(hex: "#BF5AF2")
    )), keys: [8])
    return scene
}
