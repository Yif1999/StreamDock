import DockCore

/// Fifteen configurable keys, with state read back from OBS rather than optimistic toggles.
@MainActor
public final class OBSModule: DockModule {
    public let keyCount = 15
    private let client: OBSClient
    private var context: ModuleContext?
    public convenience init() { self.init(client: .shared) }
    init(client: OBSClient) { self.client = client }
    public func attach(_ context: ModuleContext) {
        self.context = context
        client.onChange = { [weak self] in self?.context?.setNeedsDisplay() }
    }
    public func sceneDidActivate() { client.start(); context?.setNeedsDisplay() }

    public func face(forSlot slot: Int) -> KeyFace {
        guard client.bindings.indices.contains(slot) else { return .blank }
        guard client.connection == .ready else {
            if slot == 6 { return KeyFace(symbol: "video.fill", caption: "Open OBS") }
            if slot == 7 { return KeyFace(title: "OBS", caption: "Offline", tone: .dim) }
            if slot == 8 { return KeyFace(symbol: "arrow.triangle.2.circlepath", caption: "Retry") }
            return .blank
        }
        let binding = client.bindings[slot]
        guard binding.action != .none else { return .blank }
        var symbol: String?
        var value: String?
        var caption: String
        // The tone a running state gets: red for recording / muted, green for live, amber for paused.
        var tone = KeyTone.normal
        switch binding.action {
        case .none: return .blank
        case .record:
            symbol = "record.circle"
            caption = client.recording == true ? "Recording" : "Record"
            if client.recording == true { tone = .alert }
        case .pauseRecord:
            symbol = client.recordPaused == true ? "play.fill" : "pause.fill"
            caption = client.recordPaused == true ? "Resume" : "Pause"
            if client.recordPaused == true { tone = .caution }
        case .stream:
            symbol = "dot.radiowaves.left.and.right"
            caption = client.streaming == true ? "Live" : "Stream"
            if client.streaming == true { tone = .live }
        case .studio:
            symbol = "rectangle.split.2x1"
            caption = "Studio"
            if client.studio == true { tone = .on }
        case .transition:
            symbol = "arrow.right.square"
            caption = "Transition"
        case .scene:
            let name = client.sceneName(for: binding)
            value = name.flatMap { client.scenes.firstIndex(of: $0) }.map { "\($0 + 1)" } ?? "\(binding.automaticIndex + 1)"
            caption = name ?? "Unset"
            if name == client.programScene { tone = .on }
            else if client.studio == true && name == client.previewScene { tone = .caution }
        case .inputMute:
            let name = client.inputName(for: binding)
            let muted = name.flatMap { client.inputMute[$0] } == true
            symbol = muted ? "mic.slash.fill" : "mic.fill"
            caption = name ?? "Unset"
            if muted { tone = .alert }
        case .sourceVisibility:
            let item = client.item(for: binding)
            symbol = item?.enabled == true ? "eye.fill" : "eye.slash"
            caption = item?.name ?? "Unset"
            if item?.enabled == true { tone = .on }
        case .replayBuffer:
            symbol = "arrow.counterclockwise.circle"
            caption = "Replay"
            if client.replayActive == true { tone = .on }
        case .saveReplay:
            symbol = "square.and.arrow.down"
            caption = client.lastSuccessSlot == slot ? "Saved" : "Save"
        case .virtualCamera:
            symbol = "video.fill"
            caption = "Camera"
            if client.virtualCamera == true { tone = .on }
        case .hotkey:
            symbol = "keyboard"
            caption = binding.target.isEmpty ? "Unset" : binding.target
        }
        if client.actionError != nil && client.lastActionSlot == slot { caption = "Failed" }
        if client.command(for: binding) == nil { tone = .dim }
        return KeyFace(symbol: symbol, title: value, caption: caption, tone: tone)
    }

    public func keyDown(slot: Int) {
        guard client.connection == .ready else {
            if slot == 6 { client.openOBS() }
            if slot == 8 { client.reconnect() }
            return
        }
        client.perform(slot: slot)
    }
}
