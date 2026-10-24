import DockCore

/// Volume down / level + mute toggle / volume up.
///
/// Uses the default output device. When that is a monitor's speakers (which macOS
/// cannot adjust), it drives the monitor's own volume over DDC instead.
@MainActor
public final class VolumeModule: DockModule {
    public let keyCount = 3

    private let audio = SystemAudio()
    private let monitor = DDCValue(.volume)
    private let repeater = KeyRepeater()
    private var context: ModuleContext?
    /// DDC monitors here have no mute command; we mute by going to 0 and remember the level.
    private var monitorLevelBeforeMute: Float?

    public init() {}

    private enum Source {
        case system(level: Float, muted: Bool)
        case monitor(level: Float, muted: Bool)
        case none
    }

    private var source: Source {
        if let level = audio.volume { return .system(level: level, muted: audio.isMuted) }
        if audio.outputIsDisplay, let level = monitor.level { return .monitor(level: level, muted: monitorLevelBeforeMute != nil) }
        return .none
    }

    public func attach(_ context: ModuleContext) {
        self.context = context
        audio.onChange = { [weak self] in
            guard let self else { return }
            if self.audio.volume == nil, self.audio.outputIsDisplay { self.monitor.refresh() }
            self.context?.setNeedsDisplay()
        }
        monitor.onChange = { [weak self] in self?.context?.setNeedsDisplay() }
    }

    public func face(forSlot slot: Int) -> KeyFace {
        let (level, muted): (Float, Bool)
        switch source {
        case .system(let l, let m), .monitor(let l, let m): (level, muted) = (l, m)
        case .none:
            return slot == 1 ? KeyFace(symbol: "speaker.fill", caption: "Volume", tone: .dim) : .blank
        }
        switch slot {
        case 0: return KeyFace(symbol: "speaker.wave.1.fill")
        case 2: return KeyFace(symbol: "speaker.wave.3.fill")
        default:
            if muted { return KeyFace(symbol: "speaker.slash.fill", caption: "Muted", tone: .alert) }
            return KeyFace(title: "\(Int((level * 100).rounded()))", caption: "Volume")
        }
    }

    public func keyDown(slot: Int) {
        switch slot {
        case 0: repeater.start(accelerating: true) { [weak self] in self?.step(by: -1) }
        case 2: repeater.start(accelerating: true) { [weak self] in self?.step(by: 1) }
        default: toggleMute()
        }
    }

    public func keyUp(slot: Int) {
        repeater.stop()
    }

    // Listening is cheap, so keep the level current even in the background.
    public func sceneDidActivate() {
        audio.startObserving()
        if audio.volume == nil, audio.outputIsDisplay { monitor.refresh() }
    }

    public func sceneDidDeactivate() {
        repeater.stop()
    }

    private func step(by steps: Int) {
        switch source {
        case .system:
            audio.step(by: steps)
        case .monitor(let level, _):
            // Like the system keys: raising the volume unmutes.
            let base = monitorLevelBeforeMute.map { steps > 0 ? $0 : 0 } ?? level
            monitorLevelBeforeMute = nil
            monitor.set(base + Float(steps) * 0.02)
        case .none:
            break
        }
    }

    private func toggleMute() {
        switch source {
        case .system:
            audio.toggleMute()
        case .monitor(let level, let muted):
            if muted, let restore = monitorLevelBeforeMute {
                monitorLevelBeforeMute = nil
                monitor.set(restore)
            } else {
                monitorLevelBeforeMute = level
                monitor.set(0)
            }
        case .none:
            break
        }
    }
}
