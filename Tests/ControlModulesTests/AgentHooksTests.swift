import Foundation
import Testing
@testable import ControlModules

struct AgentHooksTests {
    let helper = "/Users/me/Library/Application Support/StreamDock/dock-hook"

    @Test func loadingMergesAndRestoringRemovesOnlyOurs() throws {
        // Someone's own settings and an existing hook of theirs on an event we also use.
        let mine: [String: Any] = ["model": "x", "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]]
        let loaded = AgentHooks.loaded(mine, service: .claude, helper: helper)
        #expect(AgentHooks.state(of: loaded, service: .claude, helper: helper) == .loaded)
        #expect(loaded["model"] as? String == "x")
        let stop = try #require((loaded["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)  // theirs kept, ours added
        // Loading again does not add a second copy.
        let twice = AgentHooks.loaded(loaded, service: .claude, helper: helper)
        #expect(((twice["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 2)
        // Restoring leaves exactly what was there.
        let restored = AgentHooks.restored(twice)
        #expect(AgentHooks.state(of: restored, service: .claude) == .notLoaded)
        #expect(NSDictionary(dictionary: restored).isEqual(to: mine))
    }

    @Test func olderEntriesOfOursShowAsOutdated() throws {
        // Written by an earlier version, with a 5 s timeout Codex clamps.
        var config = AgentHooks.loaded([:], service: .codex, helper: helper)
        var hooks = try #require(config["hooks"] as? [String: Any])
        hooks["SessionEnd"] = [["hooks": [["type": "command", "command": "\"\(helper)\" codex", "timeout": 5]]]]
        config["hooks"] = hooks
        #expect(AgentHooks.state(of: config, service: .codex, helper: helper) == .outdated)
        #expect(AgentHooks.state(of: AgentHooks.loaded(config, service: .codex, helper: helper), service: .codex, helper: helper) == .loaded)
        #expect(AgentHooks.state(of: [:], service: .codex, helper: helper) == .notLoaded)
    }

    @Test func restoringASettingsFileWithOnlyOurHooksDropsTheHooksTable() {
        let loaded = AgentHooks.loaded(["theme": "auto"], service: .claude, helper: helper)
        let restored = AgentHooks.restored(loaded)
        #expect(restored["hooks"] == nil && restored["theme"] as? String == "auto")
    }

    @Test func eachEventRunsTheHelperForItsApp() throws {
        let loaded = AgentHooks.loaded([:], service: .codex, helper: helper)
        let hooks = try #require(loaded["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["UserPromptSubmit", "PermissionRequest", "PreToolUse", "PostToolUse", "Stop", "Interrupt", "SessionEnd"])
        let handler = try #require(((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
        #expect(handler["command"] as? String == "\"\(helper)\" codex")
        #expect(handler["timeout"] as? Int == 2)
        // Claude's notifications only for the kinds that need you.
        let claude = try #require(AgentHooks.loaded([:], service: .claude, helper: helper)["hooks"] as? [String: Any])
        #expect((claude["Notification"] as? [[String: Any]])?.first?["matcher"] as? String == "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|idle_prompt")
    }
}

struct AgentHooksFileTests {
    @Test func loadingAndRestoringAFileKeepsItsContentAndPermissions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StreamDock.Tests.\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("settings.json"), backups = folder.appendingPathComponent("backups")
        let original = #"{"theme": "auto", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}, "n": 3}"#
        try Data(original.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        try AgentHooks.load(.claude, at: file, backups: backups, helper: "/x/StreamDock/dock-hook")
        #expect(AgentHooks.state(of: try AgentHooks.read(file), service: .claude, helper: "/x/StreamDock/dock-hook") == .loaded)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        try AgentHooks.restore(.claude, at: file, backups: backups)

        let after = try AgentHooks.read(file)
        let before = try #require(try JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        #expect(NSDictionary(dictionary: after).isEqual(to: before))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        // Both writes backed the file up first; the first backup is the original, byte for byte.
        let saved = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        #expect(saved.count >= 1)
        #expect(try saved.contains { try Data(contentsOf: $0) == Data(original.utf8) })
    }

    @Test func aCodexFileWeCreatedIsRemovedOnRestore() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StreamDock.Tests.\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("hooks.json"), backups = folder.appendingPathComponent("backups")
        try AgentHooks.load(.codex, at: file, backups: backups, helper: "/x/StreamDock/dock-hook")
        #expect(FileManager.default.fileExists(atPath: file.path))
        try AgentHooks.restore(.codex, at: file, backups: backups)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
