import DockCore
import Foundation

/// Hold for one second to sleep displays. Releasing early or leaving cancels.
@MainActor
public final class DisplaySleepModule: DockModule {
    public let keyCount = 1
    private var context: ModuleContext?
    private var countdown: Task<Void, Never>?
    private(set) var remaining: Int?
    private var failed = false
    private var held = false
    private let sleepDisplay: @MainActor () async -> Bool

    public convenience init() {
        self.init(sleepDisplay: {
            await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                process.arguments = ["displaysleepnow"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus == 0
                } catch { return false }
            }.value
        })
    }

    init(sleepDisplay: @escaping @MainActor () async -> Bool) {
        self.sleepDisplay = sleepDisplay
    }

    public func attach(_ context: ModuleContext) { self.context = context }

    public func face(forSlot slot: Int) -> KeyFace {
        if let remaining {
            return KeyFace(title: "\(remaining)", caption: "松手取消", foreground: RGB(hex: "#FF9F0A"))
        }
        return KeyFace(symbol: "display", caption: failed ? "关屏失败" : "长按关屏")
    }

    public func keyDown(slot: Int) {
        guard !held else { return }
        held = true
        failed = false
        remaining = 1
        context?.setNeedsDisplay()
        countdown = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, !Task.isCancelled, self.held else { return }
            self.remaining = nil
            self.context?.setNeedsDisplay()
            self.countdown = nil
            self.failed = !(await self.sleepDisplay())
            self.context?.setNeedsDisplay()
        }
    }

    public func keyUp(slot: Int) { cancel() }

    public func sceneDidDeactivate() { cancel() }

    private func cancel() {
        held = false
        countdown?.cancel()
        countdown = nil
        remaining = nil
        context?.setNeedsDisplay()
    }
}
