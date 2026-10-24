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
            if slot == 6 { return KeyFace(symbol: "video", caption: "打开 OBS", foreground: RGB(hex: "#FF9F0A")) }
            if slot == 8 { return KeyFace(symbol: "arrow.triangle.2.circlepath", caption: "重连") }
            if slot == 7 { return KeyFace(title: "OBS", caption: "未连接", foreground: RGB(hex: "#8E8E93")) }
            return .blank
        }
        let binding = client.bindings[slot]
        guard binding.action != .none else { return .blank }
        var symbol: String
        var caption = binding.action.title
        var active = false
        switch binding.action {
        case .none: return .blank
        case .record:
            symbol = client.recording == true ? "stop.circle.fill" : "record.circle"
            active = client.recording == true
            caption = active ? "停止录制" : "开始录制"
        case .pauseRecord:
            symbol = client.recordPaused == true ? "play.fill" : "pause.fill"
            active = client.recordPaused == true
            caption = active ? "继续录制" : "暂停录制"
        case .stream:
            symbol = "antenna.radiowaves.left.and.right"
            active = client.streaming == true
            caption = active ? "停止推流" : "开始推流"
        case .studio:
            symbol = "rectangle.split.2x1"
            active = client.studio == true
            caption = active ? "工作室开" : "工作室关"
        case .transition: symbol = "arrow.right.square"; caption = "执行转场"
        case .scene:
            symbol = "rectangle.on.rectangle"
            let name = client.sceneName(for: binding)
            caption = name ?? "未配场景"
            active = name == client.programScene
            if client.studio == true && name == client.previewScene && !active { symbol = "eye" }
        case .inputMute:
            let name = client.inputName(for: binding)
            active = name.flatMap { client.inputMute[$0] } == true
            symbol = active ? "mic.slash.fill" : "mic.fill"
            caption = name ?? "未配音频"
        case .sourceVisibility:
            let item = client.item(for: binding)
            active = item?.enabled == true
            symbol = active ? "eye.fill" : "eye.slash"
            caption = item?.name ?? "未配来源"
        case .replayBuffer:
            symbol = "arrow.counterclockwise.circle"
            active = client.replayActive == true
            caption = active ? "停止缓存" : "启动缓存"
        case .saveReplay:
            symbol = "square.and.arrow.down"
            caption = client.lastSuccessSlot == slot ? "已保存" : "保存回放"
        case .virtualCamera:
            symbol = "video.fill"
            active = client.virtualCamera == true
            caption = active ? "停止相机" : "虚拟相机"
        case .hotkey: symbol = "keyboard"; caption = binding.target.isEmpty ? "未配热键" : binding.target
        }
        if client.busy && client.lastActionSlot == slot { caption = "处理中" }
        if client.actionError != nil && client.lastActionSlot == slot { caption = "操作失败" }
        let available = client.command(for: binding) != nil
        let tint = !available ? RGB(hex: "#636366") : active ? RGB(hex: "#FF453A") : RGB(hex: "#64D2FF")
        let short = caption.count > 9 ? String(caption.prefix(8)) + "…" : caption
        return KeyFace(symbol: symbol, caption: short, foreground: tint)
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
