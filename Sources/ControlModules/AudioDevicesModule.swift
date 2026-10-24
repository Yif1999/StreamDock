import DockCore

/// Output selection, input selection, and mute for the current system input.
@MainActor
public final class AudioDevicesModule: DockModule {
    public let keyCount = 3
    private let audio = AudioDevices.shared
    private var context: ModuleContext?
    private var errorSlot: Int?
    public init() {}

    public func attach(_ context: ModuleContext) {
        self.context = context
        audio.onChange = { [weak self] in self?.context?.setNeedsDisplay() }
    }

    public func sceneDidActivate() { audio.start(); audio.refresh() }

    public func face(forSlot slot: Int) -> KeyFace {
        // The error text itself is in the settings window; the key only says it failed.
        let failed = errorSlot == slot && audio.error != nil
        switch slot {
        case 0:
            return KeyFace(symbol: "hifispeaker", caption: failed ? "Failed" : shortName(audio.output?.name, fallback: "No Output"),
                           tone: audio.output == nil ? .dim : .normal)
        case 1:
            return KeyFace(symbol: "mic", caption: failed ? "Failed" : shortName(audio.input?.name, fallback: "No Input"),
                           tone: audio.input == nil ? .dim : .normal)
        default:
            guard let muted = audio.inputMuted else { return KeyFace(symbol: "mic.fill", caption: "Mic", tone: .dim) }
            return muted
                ? KeyFace(symbol: "mic.slash.fill", caption: failed ? "Failed" : "Muted", tone: .alert)
                : KeyFace(symbol: "mic.fill", caption: failed ? "Failed" : "Mic")
        }
    }

    public func keyDown(slot: Int) {
        errorSlot = slot
        if slot == 2 { audio.toggleInputMute() } else { audio.cycle(input: slot == 1) }
        context?.setNeedsDisplay()
    }

    private func shortName(_ name: String?, fallback: String) -> String {
        guard let name else { return fallback }
        return name.count <= 9 ? name : String(name.prefix(8)) + "…"
    }
}
