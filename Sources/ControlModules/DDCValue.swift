import Foundation

/// One DDC feature of the external monitor (brightness, volume), as a 0...1 level
/// kept on the main actor. Reads and writes run on a background queue; writes are
/// applied optimistically and coalesced so holding a key does not flood the bus.
@MainActor
final class DDCValue {
    var onChange: (() -> Void)?
    /// Nil until the monitor answers (or when no DDC monitor is connected).
    private(set) var level: Float?

    private let feature: DDCDisplay.Feature
    private let queue = DispatchQueue(label: "StreamDock.DDC")
    private var display: DDCDisplay?
    private var maximum = 100
    private var pendingWrite: Int?
    private var writing = false

    init(_ feature: DDCDisplay.Feature) {
        self.feature = feature
    }

    func refresh() {
        guard !writing else { return }
        let feature = feature
        let known = display
        queue.async { [weak self] in
            let display = known ?? DDCDisplay.firstExternal()
            let value = display?.read(feature)
            Task { @MainActor in self?.applyRead(display: display, value: value) }
        }
    }

    func set(_ level: Float) {
        guard let display else { return }
        let clamped = min(1, max(0, level))
        self.level = clamped
        onChange?()
        pendingWrite = Int((clamped * Float(maximum)).rounded())
        guard !writing else { return }
        writing = true
        flush(display)
    }

    private func flush(_ display: DDCDisplay) {
        guard let value = pendingWrite else {
            writing = false
            return
        }
        pendingWrite = nil
        let feature = feature
        queue.async { [weak self] in
            display.write(feature, value: value)
            Task { @MainActor in self?.flush(display) }
        }
    }

    private func applyRead(display: DDCDisplay?, value: (current: Int, max: Int)?) {
        guard !writing else { return }
        self.display = value == nil ? nil : display
        let newLevel = value.map { Float($0.current) / Float($0.max) }
        if let value { maximum = value.max }
        guard newLevel != level else { return }
        level = newLevel
        onChange?()
    }
}
