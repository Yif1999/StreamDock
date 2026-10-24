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
    public let keyCount = 5

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
    private var cover: Data?
    private var favorite: AppleMusic.Favorite?
    private var favoriteTask: Task<Void, Never>?
    private var favoriteBusy = false
    private var favoriteFailed = false
    private var displayedTrack: AppleMusic.Track?


    public init() {}

    public func attach(_ context: ModuleContext) {
        self.context = context
        music.onChange = { [weak self] in
            self?.trackDidChange()
            self?.context?.setNeedsDisplay()
            self?.updateGlow()
        }
    }

    public func face(forSlot slot: Int) -> KeyFace {
        if music.permission == .denied {
            return KeyFace(symbol: symbol(forSlot: slot), caption: slot == 1 ? "Allow" : nil, tone: slot == 1 ? .caution : .dim)
        }
        if slot == 3 {
            return KeyFace(symbol: "music.note", artwork: cover, caption: cover == nil ? "Music" : nil,
                           tone: music.track == nil ? .dim : .normal)
        }
        if slot == 4 {
            guard let favorite else { return KeyFace(symbol: "star.fill", caption: "Love", tone: .dim) }
            let caption = favoriteBusy ? "…" : favoriteFailed ? "Retry" : favorite.enabled ? "Loved" : "Love"
            return KeyFace(symbol: "star.fill", caption: caption, tone: favorite.enabled ? .on : .normal)
        }
        let running = music.state != .notRunning
        return KeyFace(symbol: symbol(forSlot: slot), caption: slot == 1 && !running ? "Music" : nil, tone: running ? .normal : .dim)
    }

    public func keyDown(slot: Int) {
        if music.permission == .denied {
            music.openPermissionSettings()
            return
        }
        switch slot {
        case 0: music.previous()
        case 1: music.playPause()
        case 2: music.next()
        case 3: music.revealCurrentTrack()
        case 4:
            guard let favorite, !favoriteBusy else { return }
            favoriteBusy = true
            context?.setNeedsDisplay()
            Task {
                let success = await music.toggleFavorite(favorite)
                favoriteFailed = !success
                await refreshFavorite()
                favoriteBusy = false
                context?.setNeedsDisplay()
            }
        default: break
        }
    }

    // Keep following Music in the background so the key is right when the scene comes back.
    public func sceneDidActivate() {
        visible = true
        music.startObserving()
        updateGlow()
        favoriteTask?.cancel()
        favoriteTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshFavorite()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public func sceneDidDeactivate() {
        visible = false
        favoriteTask?.cancel()
        favoriteTask = nil
        stopAudio()
    }

    private func trackDidChange() {
        guard displayedTrack != music.track else { return }
        displayedTrack = music.track
        paletteTrack = nil
        cover = nil
        favorite = nil
        favoriteFailed = false
    }

    private func refreshFavorite() async {
        let track = music.track
        let value = await music.favorite()
        guard track == music.track else { return }
        favorite = value
        context?.setNeedsDisplay()
    }

    private static let lightOffDelay = 2.5

    private func updateGlow() {
        guard music.state == .playing || music.state == .paused, let track = music.track else {
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
        glow?.playing = music.state == .playing
        if visible && music.state == .playing { startAudio() } else { scheduleAudioStop() }
        if let glow { context?.setLight(glow) }
        guard track != paletteTrack else { return }
        paletteTrack = track
        Task {
            let palette = await artwork.palette(for: track, from: music)
            log.notice("Palette for \(track.artist, privacy: .public) – \(track.album, privacy: .public): \(palette.map(\.hex).joined(separator: " "), privacy: .public)")
            guard music.track == track else { return }
            cover = artwork.image(for: track)
            context?.setNeedsDisplay()
            if let glow {
                glow.setPalette(palette)
            } else {
                let glow = MusicGlow(palette: palette)
                glow.rhythm = { [audio] in
                    let input = audio.drain()
                    return audio.hasSignal ? input : nil
                }
                glow.playing = music.state == .playing
                self.glow = glow
            }
            if music.state == .playing || music.state == .paused { context?.setLight(glow) }
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
            while let self, !Task.isCancelled {
                if let pid = NSRunningApplication.runningApplications(withBundleIdentifier: AppleMusic.bundleID).first?.processIdentifier {
                    let airPlay = await self.music.airPlayEnabled()
                    guard !Task.isCancelled, self.visible else { return }
                    if self.music.state == .playing { self.audio.start(pid: pid, airPlayEnabled: airPlay) }
                }
                try? await Task.sleep(for: .seconds(2))
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
        case 3: "music.note"
        case 4: "star"
        default: music.state == .playing ? "pause.fill" : "play.fill"
        }
    }
}
