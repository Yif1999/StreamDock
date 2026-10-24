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
        var alerts = AlertCenter()
        var drawn: [Int] = []
        var lightUpdates = 0
        func redraw(keys: [Int]) { drawn += keys }
        func lightDidChange(in scene: DockScene) { lightUpdates += 1 }
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
