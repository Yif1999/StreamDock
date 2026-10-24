import AppKit
import Testing
import DockCore
@testable import ControlModules

@MainActor
struct GeneralControlsTests {
    /// The display-sleep hold, shortened from the real second, and a wait safely past it.
    static let hold: Duration = .milliseconds(100)
    static let pastHold: Duration = .milliseconds(250)

    @Test func displaySleepRequiresContinuousHoldAndCanBeRearmed() async throws {
        var calls = 0
        let module = DisplaySleepModule(hold: Self.hold) { calls += 1; return true }
        module.keyDown(slot: 0)
        #expect(module.remaining == 1)
        module.keyUp(slot: 0)
        #expect(module.remaining == nil)
        try await Task.sleep(for: Self.pastHold)
        #expect(calls == 0)
        module.keyDown(slot: 0)
        try await Task.sleep(for: Self.pastHold)
        #expect(calls == 1)
        #expect(module.remaining == nil)
        // A repeated down while still held must not trigger another sleep.
        module.keyDown(slot: 0)
        try await Task.sleep(for: Self.pastHold)
        #expect(calls == 1)
        module.keyUp(slot: 0)
    }

    @Test func leavingSceneCancelsDisplaySleep() async throws {
        var calls = 0
        let module = DisplaySleepModule(hold: Self.hold) { calls += 1; return true }
        module.keyDown(slot: 0)
        module.sceneDidDeactivate()
        try await Task.sleep(for: Self.pastHold)
        #expect(calls == 0)
        #expect(module.remaining == nil)
    }

    @Test func failedDisplaySleepIsVisible() async throws {
        let module = DisplaySleepModule(hold: Self.hold) { false }
        module.keyDown(slot: 0)
        let deadline = ContinuousClock.now + .seconds(3)
        while module.remaining != nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(module.face(forSlot: 0).caption == "关屏失败")
        module.keyUp(slot: 0)
    }

    @Test func releasingVolumeKeyStopsRepeating() async throws {
        let repeater = KeyRepeater()
        var calls = 0
        repeater.start(accelerating: true) { calls += 1 }
        #expect(calls == 1)
        repeater.stop()
        try await Task.sleep(for: .milliseconds(550))
        #expect(calls == 1)
    }

    @Test func deviceCycleHandlesDisconnectionAndEmptySelection() {
        #expect(AudioDevices.nextDevice(in: [], current: 8) == nil)
        #expect(AudioDevices.nextDevice(in: [3, 5], current: 8) == 3)
        #expect(AudioDevices.nextDevice(in: [3, 5], current: 5) == 3)
        #expect(AudioDevices.nextDevice(in: [3, 5], current: 3) == 5)
        #expect(AudioDevices.nextDevice(in: [3], current: 3) == 3)
    }

    @Test func airPlayCaptureOnlyUsesHelperWhenMusicDelegatesPlayback() {
        #expect(MusicAudioTap.selectProcesses(music: 10, musicHasOutput: false, airPlayEnabled: true, activeHelpers: [20]) == [20])
        #expect(MusicAudioTap.selectProcesses(music: 10, musicHasOutput: true, airPlayEnabled: true, activeHelpers: [20]) == [10])
        #expect(MusicAudioTap.selectProcesses(music: 10, musicHasOutput: false, airPlayEnabled: false, activeHelpers: [20]) == [10])
        #expect(MusicAudioTap.selectProcesses(music: 10, musicHasOutput: false, airPlayEnabled: true, activeHelpers: []) == [10])
    }

    @Test func artworkRendersAndInvalidArtworkFallsBack() throws {
        let source = try #require(KeyRenderer.jpeg(for: KeyFace(title: "封面", background: RGB(220, 30, 60))))
        let cover = try #require(KeyRenderer.image(for: KeyFace(artwork: source)))
        #expect(cover.width == 64 && cover.height == 64)
        let fallback = try #require(KeyRenderer.jpeg(for: KeyFace(symbol: "music.note", artwork: Data([0, 1]))))
        #expect(!fallback.isEmpty)
    }
}
