import AppKit
import CoreServices

/// Controls the Music app directly (not whatever app owns the media keys) and
/// follows its player state through the notifications Music broadcasts.
@MainActor
final class AppleMusic {
    enum State: Equatable {
        case notRunning
        case stopped
        case paused
        case playing
    }

    enum Permission: Equatable {
        case granted
        case denied
        /// Music is not running, so macOS cannot tell yet.
        case unknown
    }

    nonisolated static let bundleID = "com.apple.Music"

    var onChange: (() -> Void)?
    private(set) var state: State = .notRunning
    private(set) var permission: Permission = .unknown

    private let scriptQueue = DispatchQueue(label: "StreamDock.AppleMusic")
    private var observers: [NSObjectProtocol] = []

    func startObserving() {
        guard observers.isEmpty else { return }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] note in
            let playerState = note.userInfo?["Player State"] as? String
            MainActor.assumeIsolated { self?.apply(playerState: playerState) }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.bundleID else { return }
                MainActor.assumeIsolated { self?.queryState() }
            })
        }
        queryState()
    }

    func stopObserving() {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    func playPause() { run("playpause", launching: true) }
    func next() { run("next track", launching: false) }
    func previous() { run("previous track", launching: false) }

    /// Opens Privacy & Security → Automation.
    func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// Sends a command. Only play/pause may launch Music; the rest are ignored while it is closed.
    private func run(_ command: String, launching: Bool) {
        guard launching || isRunning else { return }
        execute("tell application id \"\(Self.bundleID)\" to \(command)")
    }

    private func queryState() {
        guard isRunning else {
            update(state: .notRunning, permission: permission)
            return
        }
        execute("tell application id \"\(Self.bundleID)\" to get player state as string")
    }

    private func execute(_ source: String) {
        scriptQueue.async { [weak self] in
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
            let code = error?[NSAppleScript.errorNumber] as? Int
            Task { @MainActor in self?.handleScript(result: result, errorCode: code) }
        }
    }

    private func handleScript(result: String?, errorCode: Int?) {
        if errorCode == Int(errAEEventNotPermitted) {
            update(state: state, permission: .denied)
            return
        }
        if errorCode == nil { permission = .granted }
        if let result { apply(playerState: result) } else { onChange?() }
    }

    private func apply(playerState: String?) {
        let newState: State = switch playerState?.lowercased() {
        case "playing": .playing
        case "paused": .paused
        case "stopped": .stopped
        default: isRunning ? .stopped : .notRunning
        }
        update(state: newState, permission: permission == .denied ? .denied : .granted)
    }

    private func update(state: State, permission: Permission) {
        guard state != self.state || permission != self.permission else { return }
        self.state = state
        self.permission = permission
        onChange?()
    }
}
