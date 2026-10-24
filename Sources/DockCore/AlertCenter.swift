/// Global, scene-independent signals on the light strip (e.g. "a coding task finished").
/// While an alert runs, scene changes do not touch the strip; when it ends the
/// active scene's color comes back.
@MainActor
public final class AlertCenter {
    var setLED: ((RGB) -> Void)?
    var restoreLED: (() -> Void)?

    public private(set) var isFlashing = false
    private var flashTask: Task<Void, Never>?

    public func flash(_ color: RGB, times: Int = 3, interval: Duration = .milliseconds(220)) {
        flashTask?.cancel()
        isFlashing = true
        flashTask = Task { [weak self] in
            for _ in 0..<times {
                self?.setLED?(color)
                try? await Task.sleep(for: interval)
                self?.setLED?(.black)
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
            }
            self?.finish()
        }
    }

    public func cancel() {
        guard isFlashing else { return }
        flashTask?.cancel()
        finish()
    }

    private func finish() {
        flashTask = nil
        isFlashing = false
        restoreLED?()
    }
}
