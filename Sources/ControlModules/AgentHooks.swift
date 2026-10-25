import Foundation

/// Loads and restores the hooks that tell StreamDock what Codex and Claude are doing. Each hook
/// runs `dock-hook <app>` (see `AgentMonitor.helperPath`). Loading merges our entries into the
/// app's config and leaves everything else as it was; restoring removes exactly our entries (any
/// handler whose command runs StreamDock's dock-hook), so edits made after loading survive. Every
/// write backs the previous file up first.
public enum AgentHooks {
    public enum State: Equatable, Sendable {
        case notLoaded, loaded
        /// Our entries are there but not as this version writes them (missing events, an older
        /// timeout, edited by hand): load again to bring them up to date.
        case outdated
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// The events each app reports; a matcher where only some of an event's kinds matter.
    static func events(for service: AIService) -> [(name: String, matcher: String?)] {
        switch service {
        case .claude: [
            ("UserPromptSubmit", nil), ("PermissionRequest", nil),
            ("Notification", "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|idle_prompt"),
            ("Elicitation", nil), ("PostToolUse", nil), ("PostToolUseFailure", nil),
            ("Stop", nil), ("StopFailure", nil), ("SessionEnd", nil),
        ]
        case .codex: [
            ("UserPromptSubmit", nil), ("PermissionRequest", nil), ("PreToolUse", nil), ("PostToolUse", nil),
            ("Stop", nil), ("Interrupt", nil), ("SessionEnd", nil),
        ]
        }
    }

    /// Claude Code's user settings; Codex's user hooks file. A symlink (dotfiles kept elsewhere)
    /// is followed, so writes go to the real file and the link stays a link.
    public static func configFile(for service: AIService) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = service == .claude ? home.appendingPathComponent(".claude/settings.json") : home.appendingPathComponent(".codex/hooks.json")
        return url.resolvingSymlinksInPath()
    }

    static func command(for service: AIService, helper: String = AgentMonitor.helperPath) -> String {
        "\"\(helper)\" \(service.rawValue)"
    }

    /// Whether a handler is one of ours.
    static func isOurs(_ handler: Any) -> Bool {
        ((handler as? [String: Any])?["command"] as? String)?.contains("StreamDock/dock-hook") == true
    }

    public static func state(for service: AIService) -> State {
        guard let config = try? read(configFile(for: service)) else { return .notLoaded }
        return state(of: config, service: service)
    }

    static func state(of config: [String: Any], service: AIService, helper: String = AgentMonitor.helperPath) -> State {
        let hooks = config["hooks"] as? [String: Any] ?? [:]
        let ours = hooks.values.flatMap { ($0 as? [Any] ?? []).flatMap { (($0 as? [String: Any])?["hooks"] as? [Any] ?? []).filter(isOurs) } }
        guard !ours.isEmpty else { return .notLoaded }
        // Loaded means exactly what this version writes: one group per event, nothing else of ours.
        let current = events(for: service).allSatisfy { event in
            (hooks[event.name] as? [Any] ?? []).contains { NSDictionary(dictionary: $0 as? [String: Any] ?? [:]).isEqual(to: group(for: event, service: service, helper: helper)) }
        }
        return current && ours.count == events(for: service).count ? .loaded : .outdated
    }

    /// Seconds an app waits for the helper. The helper gives up after one second itself; Codex
    /// caps Interrupt and SessionEnd hooks at 3 s (and clamps, with a warning), so stay under it.
    static let timeout = 2

    /// The matcher group written for one event.
    static func group(for event: (name: String, matcher: String?), service: AIService, helper: String) -> [String: Any] {
        var group: [String: Any] = ["hooks": [["type": "command", "command": command(for: service, helper: helper), "timeout": timeout]]]
        if let matcher = event.matcher { group["matcher"] = matcher }
        return group
    }

    /// `config` with our entries for `service` (replacing any earlier ones of ours).
    static func loaded(_ config: [String: Any], service: AIService, helper: String = AgentMonitor.helperPath) -> [String: Any] {
        var config = restored(config)
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        for event in events(for: service) {
            hooks[event.name] = (hooks[event.name] as? [Any] ?? []) + [group(for: event, service: service, helper: helper)]
        }
        config["hooks"] = hooks
        if service == .codex, config["description"] == nil {
            config["description"] = "StreamDock light-strip reminders: dock-hook hands each event to the StreamDock app and prints nothing."
        }
        return config
    }

    /// `config` without any of our entries; groups, events and the hooks table left empty go too.
    static func restored(_ config: [String: Any]) -> [String: Any] {
        var config = config
        guard var hooks = config["hooks"] as? [String: Any] else { return config }
        for (event, value) in hooks {
            let groups = (value as? [Any] ?? []).compactMap { group -> Any? in
                guard var group = group as? [String: Any], let handlers = group["hooks"] as? [Any] else { return group }
                let kept = handlers.filter { !isOurs($0) }
                if kept.isEmpty { return nil }
                group["hooks"] = kept
                return group
            }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        config["hooks"] = hooks.isEmpty ? nil : hooks
        return config
    }

    /// The file `load` would write, from the config as it is now. Writes nothing.
    public static func preview(_ service: AIService) throws -> String {
        let url = configFile(for: service)
        let current = FileManager.default.fileExists(atPath: url.path) ? try read(url) : [:]
        let data = try JSONSerialization.data(withJSONObject: loaded(current, service: service), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Adds our hooks to the app's config, backing the old file up first.
    public static func load(_ service: AIService) throws {
        try load(service, at: configFile(for: service), backups: backupDirectory, helper: AgentMonitor.helperPath)
    }
    static func load(_ service: AIService, at url: URL, backups: URL, helper: String) throws {
        let current = FileManager.default.fileExists(atPath: url.path) ? try read(url) : [:]
        try write(loaded(current, service: service, helper: helper), to: url, service: service, backups: backups)
    }

    /// Removes our hooks from the app's config, backing the old file up first. A Codex hooks file
    /// with nothing else in it (we created it) is deleted.
    public static func restore(_ service: AIService) throws {
        try restore(service, at: configFile(for: service), backups: backupDirectory)
    }
    static func restore(_ service: AIService, at url: URL, backups: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let current = try read(url)
        guard state(of: current, service: service) != .notLoaded else { return }
        var cleaned = restored(current)
        if service == .codex, cleaned["hooks"] == nil {
            cleaned["description"] = nil
            if cleaned.isEmpty {
                try backUp(url, service: service, to: backups)
                try FileManager.default.removeItem(at: url)
                return
            }
        }
        try write(cleaned, to: url, service: service, backups: backups)
    }

    public static var backupDirectory: URL { AgentMonitor.supportDirectory.appendingPathComponent("backups") }

    static func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure("\(url.path) 不是 JSON 对象，未作改动")
        }
        return object
    }

    private static func write(_ config: [String: Any], to url: URL, service: AIService, backups: URL) throws {
        try backUp(url, service: service, to: backups)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // An atomic write makes a new file: carry the old one's permissions over (Claude's settings
        // are owner-only), and make a new one owner-only too.
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o600
        var data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func backUp(_ url: URL, service: AIService, to backupDirectory: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        // Milliseconds in the name, and a counter if that is taken: two writes in one second
        // (load, then restore straight away) must not collide and abort the second.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss.SSS"
        let base = "\(service.rawValue)-\(url.lastPathComponent)-\(formatter.string(from: Date()))"
        var target = backupDirectory.appendingPathComponent(base)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = backupDirectory.appendingPathComponent("\(base)-\(counter)")
            counter += 1
        }
        try FileManager.default.copyItem(at: url, to: target)
    }
}
