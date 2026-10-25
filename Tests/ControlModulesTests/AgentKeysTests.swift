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
        #expect(codexSent() == ["36/0", "53/0", "31/\(command | shift)", "36/0"]) // Enter, Esc, ⌘⇧O, Enter
        let (claude, claudeSent) = module(front: AIService.claude.bundleID)
        claude.keyDown(slot: 2)
        #expect(claudeSent() == ["45/\(command)"]) // ⌘N
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
