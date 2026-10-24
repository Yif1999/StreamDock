import AppKit
import DockCore
import os

private let log = Logger(subsystem: "StreamDock", category: "Music")

/// Previous / play-pause / next for Apple Music only. While Music plays, the light strip
/// glows in the colors of the current album and moves with the music (only while this
/// module's scene is on screen; the audio tap runs only then too). Paused, the glow settles
/// into a slow breath; only when Music stops (or quits) does the strip go back to the scene's
/// color — after a grace period, since Music reports "stopped" for a moment between tracks.
@MainActor
public final class MediaModule: DockModule {
    public let keyCount = 3

    private let music = AppleMusic()
    private let artwork = ArtworkLoader()
    private var glow: MusicGlow?
    private let audio = MusicAudioTap()
    private var audioTask: Task<Void, Never>?
    private var audioStopTask: Task<Void, Never>?
    private var lightOffTask: Task<Void, Never>?
    private var visible = false
    private var paletteTrack: AppleMusic.Track?
    private var context: ModuleContext?
    private static let tint = RGB(hex: "#FF375F")
    private static let dimmed = RGB(hex: "#8E8E93")

    public init() {}

    public func attach(_ context: ModuleContext) {
        self.context = context
        music.onChange = { [weak self] in
            self?.context?.setNeedsDisplay()
            self?.updateGlow()
        }
    }

    public func face(forSlot slot: Int) -> KeyFace {
        if music.permission == .denied {
            return KeyFace(symbol: symbol(forSlot: slot), caption: slot == 1 ? "需授权" : nil, foreground: RGB(hex: "#FF9F0A"))
        }
        let running = music.state != .notRunning
        switch slot {
        case 1:
            return KeyFace(
                symbol: symbol(forSlot: 1),
                caption: running ? nil : "Music",
                foreground: running ? Self.tint : Self.dimmed
            )
        default:
            return KeyFace(symbol: symbol(forSlot: slot), foreground: running ? .white : Self.dimmed)
        }
    }

    public func keyDown(slot: Int) {
        if music.permission == .denied {
            music.openPermissionSettings()
            return
        }
        switch slot {
        case 0: music.previous()
        case 1: music.playPause()
        default: music.next()
        }
    }

    // Keep following Music in the background so the key is right when the scene comes back.
    public func sceneDidActivate() {
        visible = true
        music.startObserving()
        updateGlow()
    }

    public func sceneDidDeactivate() {
        visible = false
        stopAudio()
    }

    private static let lightOffDelay = 2.5

    private func updateGlow() {
        guard music.state == .playing, let track = music.track else {
            glow?.playing = false
            scheduleAudioStop()
            if music.state == .paused, music.track != nil {
                lightOffTask?.cancel()
                lightOffTask = nil
            } else {
                scheduleLightOff()
            }
            return
        }
        lightOffTask?.cancel()
        lightOffTask = nil
        glow?.playing = true
        if visible { startAudio() }
        if let glow { context?.setLight(glow) }
        guard track != paletteTrack else { return }
        paletteTrack = track
        Task {
            let palette = await artwork.palette(for: track, from: music)
            log.notice("Palette for \(track.artist, privacy: .public) – \(track.album, privacy: .public): \(palette.map(\.hex).joined(separator: " "), privacy: .public)")
            guard music.track == track else { return }
            if let glow {
                glow.setPalette(palette)
            } else {
                let glow = MusicGlow(palette: palette)
                glow.rhythm = { [audio] in
                    let input = audio.drain()
                    return audio.hasSignal ? input : nil
                }
                self.glow = glow
            }
            if music.state == .playing { context?.setLight(glow) }
        }
    }

    /// Starts tapping Music's audio, retrying while Music has not produced sound yet,
    /// logs the rhythm state every few seconds, and starts a debug trace when asked to
    /// (`defaults write dev.yif.StreamDock rhythmTraceSeconds 180`).
    private func startAudio() {
        audioStopTask?.cancel()
        audioStopTask = nil
        guard audioTask == nil else { return }
        audioTask = Task { [weak self] in
            var attempts = 0
            while let self, !Task.isCancelled {
                if !self.audio.isRunning, attempts < 5,
                   let pid = NSRunningApplication.runningApplications(withBundleIdentifier: AppleMusic.bundleID).first?.processIdentifier {
                    attempts += 1
                    self.audio.start(pid: pid)
                }
                try? await Task.sleep(for: .seconds(self.audio.isRunning ? 5 : 1))
                if self.audio.isRunning {
                    let rhythm = self.audio.snapshot
                    let bpm = rhythm.bpm.map { String(format: "%.0f", $0) } ?? "-"
                    log.notice("Rhythm \(rhythm.state.rawValue, privacy: .public) bpm=\(bpm, privacy: .public) confidence=\(rhythm.confidence, format: .fixed(precision: 2)) activity=\(rhythm.activity, format: .fixed(precision: 2)) intensity=\(rhythm.intensity, format: .fixed(precision: 2)) signal=\(self.audio.hasSignal)")
                    if let seconds = UserDefaults.standard.object(forKey: "rhythmTraceSeconds") as? Double, seconds > 0 {
                        UserDefaults.standard.removeObject(forKey: "rhythmTraceSeconds")
                        RhythmRecorder.shared.start(seconds: seconds, frameRate: self.audio.frameRate)
                    }
                }
            }
        }
    }

    private func scheduleLightOff() {
        guard lightOffTask == nil else { return }
        lightOffTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.lightOffDelay))
            guard !Task.isCancelled, let self else { return }
            self.lightOffTask = nil
            self.context?.setLight(nil)
        }
    }

    /// Music briefly reports non-playing states around track changes; wait before tearing down.
    private func scheduleAudioStop() {
        guard audioTask != nil, audioStopTask == nil else { return }
        audioStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.stopAudio()
        }
    }

    private func stopAudio() {
        audioStopTask?.cancel()
        audioStopTask = nil
        audioTask?.cancel()
        audioTask = nil
        if audio.isRunning { audio.stop() }
    }

    private func symbol(forSlot slot: Int) -> String {
        switch slot {
        case 0: "backward.fill"
        case 2: "forward.fill"
        default: music.state == .playing ? "pause.fill" : "play.fill"
        }
    }
}
