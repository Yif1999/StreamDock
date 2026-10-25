import DockCore
import Foundation

/// Hold for one second to sleep displays. Releasing early or leaving cancels.
@MainActor
public final class DisplaySleepModule: DockModule {
    public let keyCount = 1
    private var context: ModuleContext?
    let hold: KeyHold
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

    init(hold: Duration = KeyHold.duration, sleepDisplay: @escaping @MainActor () async -> Bool) {
        self.hold = KeyHold(duration: hold)
        self.sleepDisplay = sleepDisplay
    }

    public func attach(_ context: ModuleContext) { self.context = context }

    public func face(forSlot slot: Int) -> KeyFace {
        KeyFace(symbol: "moon.fill", caption: failed ? "Failed" : "Sleep", hold: hold.progress)
    }

    public func keyDown(slot: Int) {
        guard !held else { return }
        held = true
        failed = false
        hold.begin(redraw: { [weak self] in self?.context?.setNeedsDisplay() }) { [weak self] in
            guard let self, self.held else { return }
            Task {
                self.failed = !(await self.sleepDisplay())
                self.context?.setNeedsDisplay()
            }
        }
    }

    public func keyUp(slot: Int) { cancel() }

    public func sceneDidDeactivate() { cancel() }

    private func cancel() {
        held = false
        if hold.cancel() { context?.setNeedsDisplay() }
    }
}
