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

    struct Track: Hashable, Sendable {
        let name: String
        let artist: String
        let album: String
    }

    nonisolated static let bundleID = "com.apple.Music"

    var onChange: (() -> Void)?
    private(set) var state: State = .notRunning
    private(set) var permission: Permission = .unknown
    private(set) var track: Track?
    /// Apple's catalog ID for the playing album (or track), from the notification's store link.
    /// The same ID works in every storefront, unlike searching by name.
    private(set) var storeID: String?

    private let scriptQueue = DispatchQueue(label: "StreamDock.AppleMusic")
    private var observers: [NSObjectProtocol] = []

    func startObserving() {
        guard observers.isEmpty else { return }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            let playerState = info["Player State"] as? String
            let storeURL = info["Store URL"] as? String
            let track = (info["Name"] as? String).map {
                Track(name: $0, artist: info["Artist"] as? String ?? "", album: info["Album"] as? String ?? "")
            }
            MainActor.assumeIsolated {
                self?.storeID = storeURL.flatMap(Self.catalogID(fromStoreURL:))
                self?.apply(playerState: playerState, track: track)
            }
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

    /// The current track's artwork as Music stores it (JPEG or PNG), if it has any.
    /// Returns the data and, on failure, the AppleScript error number for diagnostics.
    func currentArtwork() async -> (data: Data?, error: Int?) {
        guard isRunning else { return (nil, nil) }
        var lastError: Int?
        // Library tracks answer `raw data`; some streamed tracks only answer `data`.
        for property in ["raw data", "data"] {
            let result = await execute("tell application id \"\(Self.bundleID)\" to get \(property) of artwork 1 of current track")
            if let data = result.data, NSImage(data: data) != nil { return (data, nil) }
            lastError = result.error
        }
        return (nil, lastError)
    }

    /// "itms://itunes.com/album?p=1440873107&i=1440873109" → the album ID (p), else the track ID (i).
    private nonisolated static func catalogID(fromStoreURL url: String) -> String? {
        let items = URLComponents(string: url)?.queryItems ?? []
        return (items.first { $0.name == "p" } ?? items.first { $0.name == "i" })?.value
    }

    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// Sends a command. Only play/pause may launch Music; the rest are ignored while it is closed.
    private func run(_ command: String, launching: Bool) {
        guard launching || isRunning else { return }
        Task { await execute("tell application id \"\(Self.bundleID)\" to \(command)") }
    }

    private func queryState() {
        guard isRunning else {
            update(state: .notRunning, track: nil)
            return
        }
        Task {
            let result = await execute("""
            tell application id "\(Self.bundleID)"
                set playerState to player state as string
                try
                    set t to current track
                    return {playerState, name of t, artist of t, album of t}
                on error
                    return {playerState}
                end try
            end tell
            """)
            let items = result.strings
            guard !items.isEmpty else { return }
            let track = items.count >= 4 ? Track(name: items[1], artist: items[2], album: items[3]) : nil
            apply(playerState: items[0], track: track)
        }
    }

    private struct ScriptResult: Sendable {
        /// The result as text, or each item's text when it is a list.
        var strings: [String] = []
        var data: Data?
        var error: Int?
    }

    /// Runs AppleScript off the main thread and records whether Music let us in.
    @discardableResult
    private func execute(_ source: String) async -> ScriptResult {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ScriptResult, Never>) in
            scriptQueue.async {
                var error: NSDictionary?
                var result = ScriptResult()
                if let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error) {
                    if descriptor.numberOfItems > 0 {
                        result.strings = (1...descriptor.numberOfItems).map { descriptor.atIndex($0)?.stringValue ?? "" }
                    } else if let text = descriptor.stringValue {
                        result.strings = [text]
                    }
                    result.data = descriptor.data
                }
                result.error = error?[NSAppleScript.errorNumber] as? Int
                continuation.resume(returning: result)
            }
        }
        if result.error == Int(errAEEventNotPermitted) {
            setPermission(.denied)
        } else if result.error == nil {
            setPermission(.granted)
        }
        return result
    }

    private func apply(playerState: String?, track: Track?) {
        let newState: State = switch playerState?.lowercased() {
        case "playing": .playing
        case "paused": .paused
        case "stopped": .stopped
        default: isRunning ? .stopped : .notRunning
        }
        update(state: newState, track: newState == .stopped || newState == .notRunning ? nil : track ?? self.track)
    }

    private func update(state: State, track: Track?) {
        guard state != self.state || track != self.track else { return }
        self.state = state
        self.track = track
        onChange?()
    }

    private func setPermission(_ permission: Permission) {
        guard permission != self.permission else { return }
        self.permission = permission
        onChange?()
    }
}
