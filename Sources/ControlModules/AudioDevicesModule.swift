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
        let failure = errorSlot == slot ? audio.error : nil
        switch slot {
        case 0:
            return KeyFace(symbol: "speaker.wave.2", caption: failure ?? shortName(audio.output?.name, fallback: "无输出"), foreground: RGB(hex: "#64D2FF"))
        case 1:
            return KeyFace(symbol: "mic", caption: failure ?? shortName(audio.input?.name, fallback: "无输入"), foreground: RGB(hex: "#64D2FF"))
        default:
            let muted = audio.inputMuted == true
            return KeyFace(symbol: muted ? "mic.slash.fill" : "mic.fill",
                           caption: failure ?? (audio.inputMuted == nil ? "不可静音" : muted ? "已静音" : "麦克风"),
                           foreground: audio.inputMuted == nil ? RGB(hex: "#8E8E93") : muted ? RGB(hex: "#FF453A") : RGB(hex: "#64D2FF"))
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
