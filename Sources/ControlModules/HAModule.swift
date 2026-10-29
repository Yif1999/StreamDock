import DockCore
import Foundation

@MainActor
public final class HAModule: DockModule {
    public let keyCount = 15
    private let client: HAClient
    private var context: ModuleContext?
    private var heldKeys: Set<Int> = []
    /// A protected power key must be held through this before it switches off.
    private let hold: KeyHold
    private var holdSlot: Int?
    private var holdBinding: HABinding?
    /// The key the hold is drawn on: kept after it fires, for the response.
    private var holdShownSlot: Int?

    public convenience init() { self.init(client: .shared) }
    init(client: HAClient, hold: Duration = KeyHold.duration) { self.client = client; self.hold = KeyHold(duration: hold) }
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
            case 6: return KeyFace(symbol: "house.fill", caption: "Open HA")
            case 7:
                let status = client.connection == .ready ? "Set Up" : client.connection == .connecting ? "Connecting" : "Offline"
                return KeyFace(title: "HA", caption: status, tone: client.connection == .ready ? .normal : .dim)
            case 8: return KeyFace(symbol: "arrow.triangle.2.circlepath", caption: "Retry")
            default: return .blank
            }
        }
        let binding = client.bindings[slot]
        guard binding.action != .none else { return .blank }
        let entity = client.entity(for: binding)
        let name = binding.label.isEmpty ? (entity?.name ?? binding.entityID) : binding.label
        let available = binding.action == .status ? entity?.available == true : client.command(for: binding) != nil
        let on = entity?.active == true
        var caption = name.isEmpty ? "Unset" : name
        // While a command is on its way the name stays (the press already shows); only an outcome replaces it.
        if client.lastActionSlot == slot, client.errorMessage != nil { caption = "Failed" }
        else if client.successSlot == slot, [.scene, .script].contains(binding.action) { caption = "Sent" }
        // A switch that is on shows its power reading in place of its icon.
        let reading = entity?.state == "on" ? client.meter(for: binding)?.powerText : nil
        let holding = holdShownSlot == slot ? hold.phase : nil
        func key(symbol: String? = nil, value: String? = nil, active: Bool = false) -> KeyFace {
            KeyFace(symbol: symbol, title: value, caption: caption, tone: !available ? .dim : active ? .on : .normal, hold: holding)
        }
        if let reading { return key(value: reading, active: true) }
        switch binding.action {
        case .status:
            return key(value: String((entity?.keyState ?? "Offline").prefix(7)))
        case .safePower:
            return key(symbol: entity?.state == "on" ? "powerplug.fill" : "power", active: entity?.state == "on")
        case .toggle where ["climate", "fan", "light"].contains(entity?.domain ?? ""):
            return entity?.state == "off" || !on ? key(symbol: "power") : key(value: entity?.keyState, active: true)
        case .toggle, .turnOn, .turnOff:
            return key(symbol: "power", active: on)
        case .temperatureDown, .fanSpeedDown: return key(symbol: "minus")
        case .temperatureUp, .fanSpeedUp: return key(symbol: "plus")
        case .climateMode: return key(value: entity?.keyMode ?? "—")
        case .fanOscillate: return key(symbol: "arrow.left.and.right", active: entity?.attributes["oscillating"]?.bool == true)
        case .fanPreset: return key(value: String((entity?.attributes["preset_mode"]?.string ?? "—").prefix(7)))
        case .brighter: return key(symbol: "sun.max.fill")
        case .dimmer: return key(symbol: "sun.min.fill")
        case .warmer: return key(symbol: "flame.fill")
        case .cooler: return key(symbol: "snowflake")
        case .scene: return key(symbol: "sparkles")
        case .script: return key(symbol: "play.fill")
        case .openCover: return key(symbol: "arrow.up")
        case .closeCover: return key(symbol: "arrow.down")
        case .stopCover: return key(symbol: "stop.fill")
        case .none: return .blank
        }
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
            holdSlot = slot; holdBinding = binding; holdShownSlot = slot
            hold.begin(redraw: { [weak self] in self?.context?.setNeedsDisplay() }) { [weak self] in
                guard let self, self.heldKeys.contains(slot), self.holdSlot == slot,
                      self.context?.isVisible != false, self.client.connection == .ready,
                      self.client.bindings[slot] == binding, self.client.entity(for: binding)?.state == "on" else {
                    self?.holdSlot = nil; self?.holdBinding = nil
                    return false
                }
                self.holdSlot = nil; self.holdBinding = nil
                self.client.perform(slot: slot, holdConfirmed: true)
                return true
            }
        } else { client.perform(slot: slot) }
    }
    public func keyUp(slot: Int) {
        heldKeys.remove(slot)
        if holdSlot == slot { cancelHold() }
    }
    public func sceneDidDeactivate() { heldKeys.removeAll(); cancelHold() }
    private func cancelHold() {
        hold.cancel(); holdSlot = nil; holdBinding = nil
        context?.setNeedsDisplay()
    }
}
