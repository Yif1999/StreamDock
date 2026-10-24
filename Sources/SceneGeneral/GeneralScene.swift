import ControlModules
import DockCore

/// Round key 1: everyday controls.
///
///   ⏮  ⏯  ⏭  ·  ·
///   🔉 音量 🔊 ·  ·
///   🔅 亮度 🔆 ·  ·
@MainActor
public func makeGeneralScene() -> DockScene {
    let scene = DockScene(id: "general", name: "通用控制", defaultLEDColor: RGB(255, 255, 255))
    scene.place(MediaModule(), keys: [1, 2, 3])
    scene.place(VolumeModule(), keys: [6, 7, 8])
    scene.place(BrightnessModule(), keys: [11, 12, 13])
    return scene
}
