import DockCore
import Foundation

/// While a rhythm trace is recording, a key to tap along to the beat — the reference the
/// analyzer is scored against (`dock-probe rhythm-eval`). Blank otherwise.
@MainActor
public final class BeatTapModule: DockModule {
    public let keyCount = 1

    private var context: ModuleContext?
    private var recording = false
    private var poll: Task<Void, Never>?

    public init() {}

    public func attach(_ context: ModuleContext) {
        self.context = context
    }

    public func face(forSlot slot: Int) -> KeyFace {
        recording ? KeyFace(symbol: "metronome.fill", caption: "打拍", foreground: RGB(hex: "#FF453A")) : .blank
    }

    public func keyDown(slot: Int) {
        RhythmRecorder.shared.tap(at: ProcessInfo.processInfo.systemUptime)
    }

    public func sceneDidActivate() {
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = RhythmRecorder.shared.isRecording
                if now != self.recording {
                    self.recording = now
                    self.context?.setNeedsDisplay()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func sceneDidDeactivate() {
        poll?.cancel()
        poll = nil
    }
}
