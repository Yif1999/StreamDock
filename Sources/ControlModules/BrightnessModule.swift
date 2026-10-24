import CoreGraphics
import DockCore

/// Display brightness: down / level / up.
/// Uses the system's own brightness control (built-in display first, then a natively
/// supported external one); falls back to the external monitor's DDC when there is none.
@MainActor
public final class BrightnessModule: DockModule {
    public let keyCount = 3

    private let repeater = KeyRepeater()
    private let external = DDCValue(.brightness)
    private var context: ModuleContext?
    private var systemDisplay: CGDirectDisplayID?
    private var systemLevel: Float?
    private var poll: Task<Void, Never>?

    public init() {}

    private var level: Float? { systemDisplay != nil ? systemLevel : external.level }

    public func attach(_ context: ModuleContext) {
        self.context = context
        external.onChange = { [weak self] in self?.context?.setNeedsDisplay() }
    }

    public func face(forSlot slot: Int) -> KeyFace {
        guard let level else {
            return slot == 1 ? KeyFace(symbol: "sun.max.fill", caption: "Brightness", tone: .dim) : .blank
        }
        switch slot {
        case 0: return KeyFace(symbol: "sun.min.fill")
        case 2: return KeyFace(symbol: "sun.max.fill")
        default: return KeyFace(title: "\(Int((level * 100).rounded()))", caption: "Brightness")
        }
    }

    public func keyDown(slot: Int) {
        switch slot {
        case 0: repeater.start { [weak self] in self?.step(by: -1) }
        case 2: repeater.start { [weak self] in self?.step(by: 1) }
        default: break
        }
    }

    public func keyUp(slot: Int) {
        repeater.stop()
    }

    // Neither source notifies on change; poll while visible so the monitor's own
    // buttons and the keyboard keys show up. DDC is slow, so poll it less often.
    public func sceneDidActivate() {
        refresh()
        poll = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                tick += 1
                guard let self else { return }
                if self.systemDisplay != nil || tick % 4 == 0 { self.refresh() }
            }
        }
    }

    public func sceneDidDeactivate() {
        poll?.cancel()
        poll = nil
        repeater.stop()
    }

    /// 1/16 steps, like the keyboard brightness keys.
    private func step(by steps: Int) {
        guard let current = level else { return }
        let target = ((current * 16).rounded() + Float(steps)) / 16
        if let display = systemDisplay {
            DisplayBrightness.set(target, on: display)
            refresh()
        } else {
            external.set(target)
        }
    }

    private func refresh() {
        // Re-pick each time: the lid or the cabling may have changed.
        let display = DisplayBrightness.controllableDisplay()
        if let display {
            let now = DisplayBrightness.get(display)
            guard display != systemDisplay || now != systemLevel else { return }
            systemDisplay = display
            systemLevel = now
            context?.setNeedsDisplay()
        } else {
            let changed = systemDisplay != nil
            systemDisplay = nil
            external.refresh()
            if changed { context?.setNeedsDisplay() }
        }
    }
}
