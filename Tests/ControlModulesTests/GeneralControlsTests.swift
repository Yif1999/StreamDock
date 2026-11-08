import AppKit
import Testing
@testable import DockCore
@testable import ControlModules

@MainActor
struct GeneralControlsTests {
    /// The display-sleep hold, shortened from the real second, and a wait safely past it.
    static let hold: Duration = .milliseconds(100)
    static let pastHold: Duration = .milliseconds(250)

    /// Waits until `condition` holds, however busy the machine is (other suites share the main
    /// actor), giving up after three seconds.
    func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func displaySleepRequiresContinuousHoldAndCanBeRearmed() async throws {
        var calls = 0
        let module = DisplaySleepModule(hold: Self.hold) { calls += 1; return true }
        module.keyDown(slot: 0)
        #expect(module.hold.progress == 0 && module.face(forSlot: 0).hold == .holding(0))
        module.keyUp(slot: 0)
        #expect(module.hold.progress == nil)
        try await Task.sleep(for: Self.pastHold)
        #expect(calls == 0)
        module.keyDown(slot: 0)
        try await eventually { calls == 1 && module.hold.progress == nil }
        #expect(calls == 1)
        #expect(module.hold.progress == nil)
        // A repeated down while still held must not trigger another sleep.
        module.keyDown(slot: 0)
        try await Task.sleep(for: Self.pastHold)
        #expect(calls == 1)
        module.keyUp(slot: 0)
    }

    @Test func artworkTapRevealsAndHoldQuitsMusic() async throws {
        let module = MediaModule(hold: Self.hold)
        var quits = 0, reveals = 0
        module.musicRunning = { true }
        module.quitMusic = { quits += 1 }
        module.revealTrack = { reveals += 1 }
        // A tap: the reveal comes on release, nothing quits.
        module.keyDown(slot: 3)
        #expect(module.face(forSlot: 3).hold == .holding(0))
        module.keyUp(slot: 3)
        try await eventually { reveals == 1 }
        #expect(reveals == 1 && quits == 0)
        // Held through the second: quit, and the release does not also reveal.
        module.keyDown(slot: 3)
        try await eventually { quits == 1 }
        module.keyUp(slot: 3)
        #expect(quits == 1 && reveals == 1)
        // The hold is over; only its response may still be playing.
        #expect(module.quitHold.progress == nil)
        if case .holding = module.face(forSlot: 3).hold { Issue.record("still holding") }
        // Leaving the scene mid-hold cancels without either.
        module.keyDown(slot: 3)
        module.sceneDidDeactivate()
        try await Task.sleep(for: Self.pastHold)
        #expect(quits == 1 && reveals == 1)
        // With Music not running there is nothing to quit: no countdown.
        module.musicRunning = { false }
        module.keyDown(slot: 3)
        #expect(module.quitHold.progress == nil)
        module.keyUp(slot: 3)
    }

    @Test func leavingSceneCancelsDisplaySleep() async throws {
        var calls = 0
        let module = DisplaySleepModule(hold: Self.hold) { calls += 1; return true }
        module.keyDown(slot: 0)
        module.sceneDidDeactivate()
        try await Task.sleep(for: Self.pastHold)
        #expect(calls == 0)
        #expect(module.hold.progress == nil)
    }

    @Test func failedDisplaySleepIsVisible() async throws {
        let module = DisplaySleepModule(hold: Self.hold) { false }
        module.keyDown(slot: 0)
        // Sleeping runs after the hold completes, in a task of its own: wait for its outcome.
        let deadline = ContinuousClock.now + .seconds(3)
        while module.face(forSlot: 0).caption != "Failed" && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(module.face(forSlot: 0).caption == "Failed")
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
        let source = try #require(KeyRenderer.jpeg(for: KeyFace(title: "Cover", tone: .alert)))
        let cover = try #require(KeyRenderer.image(for: KeyFace(artwork: source)))
        #expect(cover.width == 64 && cover.height == 64)
        let fallback = try #require(KeyRenderer.jpeg(for: KeyFace(symbol: "music.note", artwork: Data([0, 1]))))
        #expect(!fallback.isEmpty)
    }

    @Test func lateArtworkCannotReplaceTheCoverOrLightAfterSwitchingBack() async throws {
        let music = AppleMusic()
        var requests: [CheckedContinuation<ArtworkLoader.Artwork?, Never>] = []
        defer { requests.forEach { $0.resume(returning: nil) } }
        let module = MediaModule(hold: Self.hold, music: music) { _ in
            await withCheckedContinuation { requests.append($0) }
        }
        let scene = DockScene(id: "media-test", name: "Media", defaultLEDColor: .white)
        scene.place(module, keys: [1, 2, 3, 4, 5])
        let first = AppleMusic.Track(name: "Title", artist: "Artist", album: "Album", persistentID: "A")
        let second = AppleMusic.Track(name: "Title", artist: "Artist", album: "Album", persistentID: "B")
        let oldBytes = try #require(KeyRenderer.jpeg(for: KeyFace(title: "Old", tone: .alert)))
        let otherBytes = try #require(KeyRenderer.jpeg(for: KeyFace(title: "Other", tone: .dim)))
        let newBytes = try #require(KeyRenderer.jpeg(for: KeyFace(title: "New", tone: .on)))
        let oldArtwork = try #require(ArtworkLoader.Artwork(image: oldBytes))
        let otherArtwork = try #require(ArtworkLoader.Artwork(image: otherBytes))
        let newArtwork = try #require(ArtworkLoader.Artwork(image: newBytes))

        music.receivePlayerInfo(state: "Playing", track: first)
        let oldRequest = try #require(module.artworkTask)
        try await eventually { requests.count == 1 }
        _ = try #require(requests.count == 1)

        music.receivePlayerInfo(state: "Playing", track: second)
        let secondRequest = try #require(module.artworkTask)
        try await eventually { requests.count == 2 }
        _ = try #require(requests.count == 2)
        requests.removeLast().resume(returning: otherArtwork)
        await secondRequest.value
        #expect(module.face(forSlot: 3).artwork == otherBytes)

        music.receivePlayerInfo(state: "Playing", track: first)
        #expect(module.face(forSlot: 3).artwork == nil)
        let newRequest = try #require(module.artworkTask)
        try await eventually { requests.count == 2 }
        _ = try #require(requests.count == 2)
        requests.removeLast().resume(returning: newArtwork)
        await newRequest.value
        requests.removeFirst().resume(returning: oldArtwork)
        await oldRequest.value

        #expect(module.face(forSlot: 3).artwork == newBytes)
        let glow = try #require(scene.light as? MusicGlow)
        for tick in 0..<80 { _ = glow.frame(at: Double(tick) / 10, ledCount: 24, input: nil) }
        #expect(glow.main.color.srgb == MusicGlow(palette: newArtwork.palette).main.color.srgb)
    }
}
