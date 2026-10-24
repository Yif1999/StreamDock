import DockCore
import Foundation

@MainActor
public final class HAModule: DockModule {
    public let keyCount = 15
    private let client: HAClient
    private var context: ModuleContext?
    private var heldKeys: Set<Int> = []
    private var holdTask: Task<Void, Never>?
    private var holdSlot: Int?
    private var holdBinding: HABinding?

    /// How long a protected power key must be held before it switches off.
    private let hold: Duration

    public convenience init() { self.init(client: .shared) }
    init(client: HAClient, hold: Duration = .seconds(1)) { self.client = client; self.hold = hold }
    public func attach(_ context: ModuleContext) {
        self.context = context
        client.onChange = { [weak self] in
            guard let self else { return }
            if let slot = self.holdSlot,
               self.client.connection != .ready || self.client.bindings[slot] != self.holdBinding || self.client.entity(for: self.client.bindings[slot])?.state != "on" {
                self.cancelHold()
            }
            self.context?.setNeedsDisplay()
        }
    }
    public func sceneDidActivate() { client.start(); context?.setNeedsDisplay() }
    public func face(forSlot slot: Int) -> KeyFace {
        guard client.bindings.indices.contains(slot) else { return .blank }
        if client.connection != .ready || client.bindings.allSatisfy({ $0.action == .none }) {
            switch slot {
            case 6: return KeyFace(symbol: "house", caption: "打开 HA", foreground: RGB(hex: "#18BDF1"))
            case 7: return KeyFace(title: "HA", caption: client.connection == .ready ? "请配置按键" : client.connection == .connecting ? "连接中" : "未连接")
            case 8: return KeyFace(symbol: "arrow.triangle.2.circlepath", caption: "重连")
            default: return .blank
            }
        }
        if holdSlot == slot { return KeyFace(title: "1 秒", caption: "松手取消", foreground: RGB(hex: "#FF9F0A")) }
        let binding = client.bindings[slot]
        guard binding.action != .none else { return .blank }
        let entity = client.entity(for: binding)
        let name = binding.label.isEmpty ? (entity?.name ?? binding.entityID) : binding.label
        let caption = String((name.isEmpty ? "未选择设备" : name).prefix(9))
        var detail = entity?.displayState ?? "离线"
        if client.busySlot == slot { detail = "处理中" }
        else if client.lastActionSlot == slot, client.errorMessage != nil { detail = "失败" }
        else if client.successSlot == slot, [.scene, .script].contains(binding.action) { detail = "已发送" }
        let available = binding.action == .status ? entity?.available == true : client.command(for: binding) != nil
        let tint = !available ? RGB(hex: "#636366") : entity?.active == true ? RGB(hex: "#30D158") : RGB(hex: "#18BDF1")
        if binding.action == .status {
            return KeyFace(title: String(detail.prefix(9)), caption: caption, foreground: tint)
        }
        if client.busySlot == slot || (client.lastActionSlot == slot && client.errorMessage != nil) {
            return KeyFace(title: detail, caption: caption, foreground: tint)
        }
        switch binding.action {
        case .safePower:
            if entity?.state == "off" { return KeyFace(symbol: "power", caption: caption, foreground: tint) }
            return KeyFace(title: "长按1秒", caption: caption, foreground: tint)
        case .toggle where ["climate", "fan", "light"].contains(entity?.domain ?? ""):
            if entity?.state == "off" { return KeyFace(symbol: "power", caption: caption, foreground: tint) }
            return KeyFace(title: detail, caption: caption, foreground: tint)
        case .temperatureDown, .temperatureUp:
            return KeyFace(symbol: binding.action == .temperatureDown ? "minus" : "plus", caption: caption, foreground: tint)
        case .climateMode:
            if entity?.state == "off" { return KeyFace(symbol: "power", caption: caption, foreground: tint) }
            return KeyFace(title: entity?.modeTitle ?? "—", caption: caption, foreground: tint)
        case .fanSpeedDown, .fanSpeedUp, .brighter, .dimmer:
            let decrease = binding.action == .fanSpeedDown || binding.action == .dimmer
            return KeyFace(symbol: decrease ? "minus" : "plus", caption: caption, foreground: tint)
        case .fanOscillate:
            let swinging = entity?.attributes["oscillating"]?.bool == true
            return KeyFace(symbol: "arrow.left.and.right", caption: swinging ? "摇头 · 开" : "摇头 · 关", foreground: available && swinging ? RGB(hex: "#30D158") : tint)
        case .fanPreset:
            return KeyFace(title: String((entity?.attributes["preset_mode"]?.string ?? "—").prefix(6)), caption: caption, foreground: tint)
        default: break
        }
        let symbol: String
        switch binding.action {
        case .warmer: symbol = "sun.haze.fill"
        case .cooler: symbol = "sun.max"
        case .brighter: symbol = "sun.max.fill"
        case .dimmer: symbol = "sun.min.fill"
        case .scene: symbol = "sparkles"
        case .script: symbol = "play.rectangle"
        case .openCover: symbol = "arrow.up"
        case .closeCover: symbol = "arrow.down"
        case .stopCover: symbol = "stop.fill"
        default: symbol = entity?.domain == "light" ? "lightbulb.fill" : entity?.domain == "fan" ? "fan.fill" : "power"
        }
        return KeyFace(symbol: symbol, caption: caption, foreground: tint)
    }
    public func keyDown(slot: Int) {
        if client.connection != .ready || client.bindings.allSatisfy({ $0.action == .none }) {
            if slot == 6 { client.openDashboard() }
            if slot == 8 { client.reconnect() }
            return
        }
        guard client.bindings.indices.contains(slot), heldKeys.insert(slot).inserted else { return }
        let binding = client.bindings[slot]
        if binding.action == .safePower, client.entity(for: binding)?.state == "on" {
            guard client.command(for: binding) != nil, client.busySlot == nil else { return }
            cancelHold()
            holdSlot = slot; holdBinding = binding
            context?.setNeedsDisplay()
            holdTask = Task { [weak self, hold] in
                do { try await Task.sleep(for: hold) } catch { return }
                guard let self, !Task.isCancelled, self.heldKeys.contains(slot), self.holdSlot == slot,
                      self.context?.isVisible != false, self.client.connection == .ready,
                      self.client.bindings[slot] == binding, self.client.entity(for: binding)?.state == "on" else { return }
                self.holdSlot = nil; self.holdBinding = nil; self.holdTask = nil
                self.client.perform(slot: slot, holdConfirmed: true)
                self.context?.setNeedsDisplay()
            }
        } else { client.perform(slot: slot) }
    }
    public func keyUp(slot: Int) {
        heldKeys.remove(slot)
        if holdSlot == slot { cancelHold() }
    }
    public func sceneDidDeactivate() { heldKeys.removeAll(); cancelHold() }
    private func cancelHold() {
        holdTask?.cancel(); holdTask = nil; holdSlot = nil; holdBinding = nil
        context?.setNeedsDisplay()
    }
}
