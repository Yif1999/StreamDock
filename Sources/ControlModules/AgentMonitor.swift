import AppKit
import DockCore
import Observation
import os

private let log = Logger(subsystem: "StreamDock", category: "Agents")

/// Follows Codex and Claude for the VibeCoding light strip, from app launch whichever scene is
/// on screen (the glow itself shows only in that scene's light). Only two sources, by choice —
/// nothing reads the apps' logs or transcripts:
/// - hook events from `dock-hook` over a local socket (prompts, approvals, tool runs, stops,
///   failures, interrupts, idle notices, session ends);
/// - the system's word on which app is in front (looking clears reminders, quiets a summon) and
///   which apps quit.
@MainActor @Observable
public final class AgentMonitor {
    public static private(set) var current: AgentMonitor?
    /// The last event each app reported, for Settings.
    public private(set) var lastEvents: [AIService: (event: String, date: Date)] = [:]
    public private(set) var listening = false
    /// Whether the hook helper is installed where the hooks expect it.
    public private(set) var helperInstalled = FileManager.default.isExecutableFile(atPath: AgentMonitor.helperPath)

    @ObservationIgnored let status = AgentStatus()
    @ObservationIgnored private lazy var glow = AgentGlow(status: status)
    @ObservationIgnored private let center: LightActivityCenter
    @ObservationIgnored private var server: AgentEventServer?
    @ObservationIgnored private var settle: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    public init(center: LightActivityCenter) {
        self.center = center
        status.onChange = { [weak self] in self?.update() }
    }

    public nonisolated static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/StreamDock")
    public nonisolated static var socketPath: String { supportDirectory.appendingPathComponent("agent.sock").path }
    /// Where the hook commands point: a copy of the bundled helper on the internal disk, so the
    /// hooks keep working wherever the app itself lives.
    public nonisolated static var helperPath: String { supportDirectory.appendingPathComponent("dock-hook").path }

    public func start() {
        Self.current = self
        // Keep an installed helper up to date; one that was cleaned up stays gone.
        if helperInstalled { try? installHelper() }
        do {
            let server = AgentEventServer(path: Self.socketPath) { [weak self] message in
                Task { @MainActor in self?.handle(message) }
            }
            try server.start()
            self.server = server
            listening = true
        } catch {
            log.error("Agent event socket failed: \(error.localizedDescription, privacy: .public)")
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.status.setFrontmost(Self.service(bundleID: id)) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if let service = Self.service(bundleID: id) { self?.status.appQuit(service) } }
        })
        status.setFrontmost(Self.service(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier))
    }

    public func stop() {
        settle?.cancel()
        server?.stop(); server = nil
        listening = false
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        center.set(nil, for: "agents")
    }

    static func service(bundleID: String?) -> AIService? {
        AIService.allCases.first { $0.bundleID == bundleID }
    }

    // MARK: - Events

    /// One hook event from `dock-hook`.
    func handle(_ message: [String: String]) {
        guard let service = AIService(rawValue: message["app"] ?? ""), let name = message["event"] else { return }
        let session = message["session"] ?? "unknown"
        lastEvents[service] = (name, Date())
        let detail = [message["tool"], message["kind"]].compactMap { $0 }.joined(separator: " ")
        guard let event = Self.event(for: name, kind: message["kind"], tool: message["tool"], service: service) else {
            log.notice("\(service.name, privacy: .public) \(name, privacy: .public) \(detail, privacy: .public) (no change)")
            return
        }
        log.notice("\(service.name, privacy: .public) \(name, privacy: .public) \(detail, privacy: .public) → \(event.rawValue, privacy: .public)")
        status.record(event, service: service, session: session, at: clock())
    }

    /// You pressed the console's Stop with Claude in front. Claude ends the turn either way —
    /// interrupted at work, or a declined request — and reports neither with a hook, so the press
    /// itself is the signal: its latest active turn is over.
    public func consoleStopped(_ service: AIService) {
        guard service == .claude, let session = status.latestActiveSession(of: service) else { return }
        log.notice("Claude stopped from the console")
        status.record(.interrupted, service: service, session: session, at: clock())
    }

    /// Hook event names, mapped onto what the strip shows.
    static func event(for name: String, kind: String?, tool: String? = nil, service: AIService) -> AgentStatus.Event? {
        switch name {
        case "UserPromptSubmit": .prompt
        case "PermissionRequest", "Elicitation": .approval
        // Codex asks for more permissions (network access) through a tool of its own, and no
        // approval hook fires for it: the tool starting means it waits on you. Other tools say
        // nothing new; every tool's PostToolUse means it carried on.
        case "PreToolUse": tool == "request_permissions" ? .approval : nil
        case "Notification":
            switch kind {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": .approval
            case "idle_prompt": .idle
            default: nil
            }
        case "PostToolUse", "PostToolUseFailure": .resumed
        case "Stop": .done
        case "StopFailure": .failed
        case "Interrupt": .interrupted
        case "SessionEnd": .ended
        default: nil
        }
    }

    // MARK: - Light

    /// Puts the glow on the strip while anything shows, takes it off (easing to the scene color
    /// over 1.2 s) when both apps are idle, and wakes again when a one-shot ends.
    private func update() {
        let now = clock()
        status.prune(at: now)
        if status.isIdle(at: now) {
            center.set(nil, for: "agents", fade: 1.2)
        } else {
            center.set(glow, for: "agents", priority: 100)
        }
        settle?.cancel()
        let ends = AIService.allCases.compactMap { service -> TimeInterval? in
            switch status.light(for: service, at: now) {
            case .close(let since): since + AgentLight.closeDuration
            case .fail(let since): since + AgentLight.failDuration
            default: nil
            }
        }
        guard let next = ends.min() else { return }
        settle = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, next - now) + 0.02)) } catch { return }
            self?.update()
        }
    }

    // MARK: - Helper

    /// Copies the helper bundled with the app to `helperPath` (only if it differs, unless `clean`,
    /// which removes the old copy first).
    public func installHelper(clean: Bool = false) throws {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "dock-hook") else {
            throw AgentHooks.Failure("应用包里没有 dock-hook（请用 scripts/build_app.sh 构建）")
        }
        let data = try Data(contentsOf: bundled)
        let target = URL(fileURLWithPath: Self.helperPath)
        if clean { try? FileManager.default.removeItem(at: target) }
        if (try? Data(contentsOf: target)) != data {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try data.write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            log.notice("Installed hook helper at \(target.path, privacy: .public)")
        }
        helperInstalled = true
    }

    /// Restores both apps' hooks (they would fail without the helper), then deletes the helper.
    public func removeHelper() throws {
        for service in AIService.allCases { try AgentHooks.restore(service) }
        try? FileManager.default.removeItem(atPath: Self.helperPath)
        helperInstalled = FileManager.default.isExecutableFile(atPath: Self.helperPath)
    }

    /// Loads an app's hooks, installing the helper first if needed.
    public func loadHooks(_ service: AIService) throws {
        if !helperInstalled { try installHelper() }
        try AgentHooks.load(service)
    }
}

/// A Unix-domain socket in Application Support that `dock-hook` writes one JSON line to per event.
final class AgentEventServer: @unchecked Sendable {
    private let path: String
    private let onMessage: @Sendable ([String: String]) -> Void
    private let queue = DispatchQueue(label: "StreamDock.agents")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, onMessage: @escaping @Sendable ([String: String]) -> Void) {
        self.path = path
        self.onMessage = onMessage
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ call: String) { errorDescription = "\(call): \(String(cString: strerror(errno)))" }
    }

    func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure("path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in path.utf8.enumerated() { raw[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw Failure("bind") }
        chmod(path, 0o600)  // only this user's processes may write to it
        guard listen(fd, 16) == 0 else { throw Failure("listen") }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel(); source = nil
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path)
    }

    private func accept() {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65536 {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        for line in data.split(separator: 0x0A) {
            if let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: String] { onMessage(message) }
        }
    }
}
