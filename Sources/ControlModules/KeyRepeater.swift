/// Runs an action once on key down, then repeatedly while the key is held.
@MainActor
final class KeyRepeater {
    private var task: Task<Void, Never>?

    func start(_ action: @escaping @MainActor () -> Void) {
        stop()
        action()
        task = Task {
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
