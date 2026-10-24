import ControlModules
import DockCore

/// Volume / devices, brightness / display sleep / microphone, then Music.
@MainActor
public func makeGeneralScene() -> DockScene {
    let scene = DockScene(id: "general", name: "通用控制", defaultLEDColor: RGB(255, 255, 255),
                          pageTitles: ["日常控制", "Home Assistant", "OBS 控台"])
    scene.place(VolumeModule(), keys: [1, 2, 3])
    scene.place(AudioDevicesModule(), keys: [4, 5, 10])
    scene.place(BrightnessModule(), keys: [6, 7, 8])
    scene.place(DisplaySleepModule(), keys: [9])
    scene.place(MediaModule(), keys: [11, 12, 13, 14, 15])
    scene.place(HAModule(), keys: Array(1...15), page: 1)
    scene.place(OBSModule(), keys: Array(1...15), page: 2)
    return scene
}
