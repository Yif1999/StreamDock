import ControlModules
import DockCore

/// Round key 2: AI coding tools. Rows 1–2 are the Codex and Claude quotas (through CPA);
/// row 3 (task status, quick keys) is not built yet.
@MainActor
public func makeVibeCodingScene() -> DockScene {
    let scene = DockScene(id: "vibecoding", name: "VibeCoding", defaultLEDColor: RGB(hex: "#FC8FFF"))
    scene.place(AIQuotaModule(), keys: Array(1...10))
    return scene
}
