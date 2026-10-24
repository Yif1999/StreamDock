/// Global, scene-independent signals on the light strip (e.g. "a coding task finished").
/// An alert takes over the strip from any scene or animation; when it ends, whatever
/// was showing fades back in. Each on/off of a flash is eased by the light engine.
@MainActor
public final class AlertCenter {
    var onChange: (() -> Void)?

    /// The color an alert is showing right now, or nil when no alert is running.
    public private(set) var color: RGB?
    public var isFlashing: Bool { flashTask != nil }
    private var flashTask: Task<Void, Never>?

    public func flash(_ color: RGB, times: Int = 3, interval: Duration = .milliseconds(450)) {
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            for _ in 0..<times {
                self?.set(color)
                do { try await Task.sleep(for: interval) } catch { return }
                self?.set(.black)
                do { try await Task.sleep(for: interval) } catch { return }
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

    private func set(_ color: RGB) {
        self.color = color
        onChange?()
    }

    private func finish() {
        flashTask = nil
        color = nil
        onChange?()
    }
}
