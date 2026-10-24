import DockCore

/// Previous / play-pause / next for Apple Music only.
@MainActor
public final class MediaModule: DockModule {
    public let keyCount = 3

    private let music = AppleMusic()
    private var context: ModuleContext?
    private static let tint = RGB(hex: "#FF375F")
    private static let dimmed = RGB(hex: "#8E8E93")

    public init() {}

    public func attach(_ context: ModuleContext) {
        self.context = context
        music.onChange = { [weak self] in self?.context?.setNeedsDisplay() }
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
        music.startObserving()
    }

    private func symbol(forSlot slot: Int) -> String {
        switch slot {
        case 0: "backward.fill"
        case 2: "forward.fill"
        default: music.state == .playing ? "pause.fill" : "play.fill"
        }
    }
}
