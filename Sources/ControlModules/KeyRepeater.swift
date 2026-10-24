/// Runs an action once on key down, then repeatedly while the key is held.
@MainActor
final class KeyRepeater {
    private var task: Task<Void, Never>?

    func start(accelerating: Bool = false, _ action: @escaping @MainActor () -> Void) {
        stop()
        action()
        task = Task {
            try? await Task.sleep(for: .milliseconds(400))
            var repeats = 0
            while !Task.isCancelled {
                action()
                repeats += 1
                try? await Task.sleep(for: .milliseconds(accelerating && repeats >= 12 ? 45 : 90))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
