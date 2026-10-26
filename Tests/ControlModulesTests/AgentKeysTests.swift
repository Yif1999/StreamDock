import CoreGraphics
import DockCore
import Testing
@testable import ControlModules

@MainActor struct AgentKeysTests {
    private func module(front: String?) -> (AgentKeysModule, () -> [String]) {
        let module = AgentKeysModule()
        var log: [String] = []
        module.frontmost = { front }
        module.permitted = { true }
        module.press = { log.append("\($0.key)/\($0.flags.rawValue)") }
        module.setFn = { log.append($0 ? "fn↓" : "fn↑") }
        module.codexWorking = { false }
        module.stopped = { log.append("stopped \($0.rawValue)") }
        return (module, { log })
    }

    @Test func keysGoOnlyToCodexOrClaudeInFront() {
        let (other, sent) = module(front: "com.apple.Safari")
        for slot in 0..<5 { other.keyDown(slot: slot); other.keyUp(slot: slot) }
        #expect(sent().isEmpty)
        #expect((0..<5).allSatisfy { other.face(forSlot: $0).tone == .dim })
    }

    @Test func eachAppGetsItsOwnShortcuts() {
        let command = CGEventFlags.maskCommand.rawValue, shift = CGEventFlags.maskShift.rawValue
        let (codex, codexSent) = module(front: AIService.codex.bundleID)
        for slot in 0..<4 { codex.keyDown(slot: slot) }
        #expect(codexSent() == ["36/0", "53/0", "stopped codex", "31/\(command | shift)", "36/0"]) // Enter, Esc, ⌘⇧O, Enter
        let (claude, claudeSent) = module(front: AIService.claude.bundleID)
        for slot in 0..<4 { claude.keyDown(slot: slot) }
        #expect(claudeSent() == ["36/\(command)", "53/0", "stopped claude", "45/\(command)", "36/0"]) // ⌘↩, Esc, ⌘N, Enter
    }

    @Test func stopConfirmsItselfWhileCodexWorks() async throws {
        let (codex, sent) = module(front: AIService.codex.bundleID)
        codex.codexWorking = { true }
        codex.keyDown(slot: 1)
        // Wait for the confirming Esc (due 150 ms later) however busy the machine is.
        let deadline = ContinuousClock.now + .seconds(3)
        while sent().count < 3 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(sent() == ["53/0", "stopped codex", "53/0"])  // Esc, then the confirming Esc
        // Codex waiting on an approval (not working), idle Codex, or Claude: a single Esc,
        // which declines the request where there is one.
        let (idle, idleSent) = module(front: AIService.codex.bundleID)
        idle.keyDown(slot: 1)
        let (claude, claudeSent) = module(front: AIService.claude.bundleID)
        claude.codexWorking = { true }
        claude.keyDown(slot: 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(idleSent() == ["53/0", "stopped codex"] && claudeSent() == ["53/0", "stopped claude"])
    }

    @Test func voiceHoldsFnForAsLongAsTheKeyAndNeverLeavesItDown() {
        let (keys, sent) = module(front: AIService.claude.bundleID)
        keys.keyDown(slot: 4)
        keys.keyDown(slot: 4) // Key repeat: still one press.
        #expect(keys.face(forSlot: 4).tone == .on)
        keys.keyUp(slot: 4)
        #expect(sent() == ["fn↓", "fn↑"])
        keys.keyDown(slot: 4)
        keys.sceneDidDeactivate()
        #expect(sent() == ["fn↓", "fn↑", "fn↓", "fn↑"])
    }
}
