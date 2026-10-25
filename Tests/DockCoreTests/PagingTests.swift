import Foundation
import Testing
@testable import DockCore

@MainActor
struct PagingTests {
    final class Module: DockModule {
        let keyCount = 1
        let title: String
        var context: ModuleContext?
        var activations = 0
        var deactivations = 0
        var presses = 0
        init(_ title: String) { self.title = title }
        func attach(_ context: ModuleContext) { self.context = context }
        func face(forSlot slot: Int) -> KeyFace { KeyFace(title: title) }
        func sceneDidActivate() { activations += 1 }
        func sceneDidDeactivate() { deactivations += 1 }
        func keyDown(slot: Int) { presses += 1 }
    }
    final class Host: SceneHost {
        var drawn: [Int] = []
        var lightUpdates = 0
        var litScenes: [String] = []
        func redraw(keys: [Int]) { drawn += keys }
        func lightDidChange(in scene: DockScene, fade: TimeInterval) { lightUpdates += 1; litScenes.append(scene.id) }
    }

    final class Steady: LightAnimation {
        func pixels(at time: TimeInterval, ledCount: Int) -> [LightPixel] { [] }
    }

    @Test func activitiesAndAlertsBelongToTheirScene() {
        let general = DockScene(id: "general", name: "General", defaultLEDColor: .white)
        let vibe = DockScene(id: "vibe", name: "Vibe", defaultLEDColor: .white)
        let host = Host()
        general.host = host; vibe.host = host
        let recording = Steady()
        general.activities.set(recording, for: "obs")
        // Only the owning scene reports it; another scene's strip stays its own.
        #expect(host.litScenes == ["general"])
        guard case .animation(let shown) = general.activities.source(alert: general.alerts.color, sceneAnimation: nil, sceneColor: .white) else {
            Issue.record("general should show its activity"); return
        }
        #expect(shown === recording)
        guard case .solid(let color, _) = vibe.activities.source(alert: vibe.alerts.color, sceneAnimation: nil, sceneColor: .black) else {
            Issue.record("vibe should show its own color"); return
        }
        #expect(color == .black)
    }

    @Test func pagesReuseKeysButOnlyForegroundReceivesInputAndRedraws() {
        let scene = DockScene(id: "test", name: "Test", defaultLEDColor: .white, pageTitles: ["日常", "HA", "OBS"])
        let first = Module("first"), second = Module("HA"), third = Module("OBS")
        scene.place(first, keys: [1]); scene.place(second, keys: [1], page: 1); scene.place(third, keys: [1], page: 2)
        let host = Host(); scene.host = host
        scene.activate()
        #expect(first.activations == 1 && third.activations == 0)
        scene.keyDown(1)
        scene.advancePage()
        #expect(scene.currentPageIndex == 1 && scene.face(forKey: 1).title == "HA")
        #expect(first.deactivations == 1 && second.activations == 1)
        first.context?.setNeedsDisplay()
        #expect(host.drawn.isEmpty)
        second.context?.setNeedsDisplay()
        #expect(host.drawn == [1])
        scene.advancePage(); scene.keyDown(1)
        #expect(first.presses == 1 && second.presses == 0 && third.presses == 1)
        scene.advancePage()
        #expect(scene.currentPageIndex == 0 && first.activations == 2)
        scene.deactivate()
    }

    @Test func reenteringSceneRemembersPageAndEmptyKeysAreBlank() {
        let scene = DockScene(id: "test", name: "Test", defaultLEDColor: .white, pageTitles: ["日常", "HA", "OBS"])
        let module = Module("OBS"); scene.place(module, keys: [8], page: 2)
        scene.activate(); scene.advancePage(); scene.advancePage(); scene.deactivate(); scene.activate()
        #expect(scene.currentPageIndex == 2)
        #expect(scene.face(forKey: 8).title == "OBS")
        #expect(scene.face(forKey: 1) == .blank)
        scene.deactivate()
    }

    @Test func singlePageSceneDoesNotReactivateOnAdvance() {
        let scene = DockScene(id: "test", name: "Test", defaultLEDColor: .white)
        let module = Module("one"); scene.place(module, keys: [1])
        scene.activate(); scene.advancePage()
        #expect(scene.currentPageIndex == 0 && module.activations == 1 && module.deactivations == 0)
        scene.deactivate()
    }
}
