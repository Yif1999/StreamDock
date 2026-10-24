import DockCore

/// Round key 3: synthesizer controller. Not built yet.
@MainActor
public func makeSynthScene() -> DockScene {
    let scene = DockScene(id: "synth", name: "合成器", defaultLEDColor: RGB(hex: "#FF9F0A"))
    scene.place(LabelModule(KeyFace(symbol: "pianokeys", caption: "Synth")), keys: [8])
    return scene
}
