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

    struct Track: Equatable, Sendable {
        let name: String
        let artist: String
        let album: String
        var persistentID: String? = nil
        var catalog: CatalogID? = nil
        var durationMS: Int? = nil

        func matches(_ other: Track) -> Bool {
            if let id = persistentID, let otherID = other.persistentID, id != otherID { return false }
            return name == other.name && artist == other.artist && album == other.album
        }
    }

    struct CatalogID: Equatable, Sendable {
        enum Kind { case song, album }
        let kind: Kind
        let id: Int
        let storefront: String?

        /// Music can broadcast either an old iTunes link or a music.apple.com link.
        init?(storeURL: String) {
            guard let url = URLComponents(string: storeURL) else { return nil }
            let path = url.path.split(separator: "/")
            let storefront = path.first.map(String.init).flatMap { $0.count == 2 ? $0.uppercased() : nil }
            func query(_ name: String) -> Int? {
                url.queryItems?.first { $0.name == name }?.value.flatMap(Int.init)
            }
            let pathID = path.last.flatMap { Int($0) }
            if let song = query("i") ?? (path.contains("song") ? pathID : nil), song > 0 {
                self.init(kind: .song, id: song, storefront: storefront)
            } else if let album = query("p") ?? (path.contains("album") ? pathID : nil), album > 0 {
                self.init(kind: .album, id: album, storefront: storefront)
            } else {
                return nil
            }
        }

        private init(kind: Kind, id: Int, storefront: String?) {
            self.kind = kind
            self.id = id
            self.storefront = storefront
        }
    }

    nonisolated static let bundleID = "com.apple.Music"

    var onChange: (() -> Void)?
    private(set) var state: State = .notRunning
    private(set) var permission: Permission = .unknown
    private(set) var track: Track?
    private(set) var playbackRevision = 0

    private let scriptQueue = DispatchQueue(label: "StreamDock.AppleMusic")
    private var observers: [NSObjectProtocol] = []
    private var stateQueryRevision = 0

    func startObserving() {
        guard observers.isEmpty else { return }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] note in
            guard let event = Self.playerInfo(note.userInfo ?? [:]) else { return }
            MainActor.assumeIsolated {
                self?.receivePlayerInfo(state: event.state, track: event.track)
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

    nonisolated static func playerInfo(_ info: [AnyHashable: Any]) -> (state: String, track: Track?)? {
        guard let playerState = info["Player State"] as? String else { return nil }
        let storeURL = info["Store URL"] as? String ?? (info["Store URL"] as? URL)?.absoluteString
        let track = (info["Name"] as? String).map {
            Track(name: $0, artist: info["Artist"] as? String ?? "", album: info["Album"] as? String ?? "",
                  persistentID: Self.persistentID(info["PersistentID"]),
                  catalog: storeURL.flatMap(CatalogID.init(storeURL:)),
                  durationMS: info["Total Time"] as? Int)
        }
        return (playerState, track)
    }

    func receivePlayerInfo(state: String, track: Track?) {
        stateQueryRevision += 1
        // A playing notification without a song or library ID can be another track with the
        // same tags. Start a fresh request even if its display fields are identical.
        let unidentified = track.map { $0.persistentID == nil && $0.catalog?.kind != .song } ?? false
        apply(playerState: state, track: track, newPlayback: state.lowercased() == "playing" && unidentified)
    }

    private nonisolated static func persistentID(_ value: Any?) -> String? {
        if let number = value as? NSNumber, number.uint64Value != 0 {
            return String(format: "%016llX", number.uint64Value)
        }
        guard let string = value as? String, let number = UInt64(string, radix: 16), number != 0 else { return nil }
        return String(format: "%016llX", number)
    }

    func stopObserving() {
        stateQueryRevision += 1
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    func playPause() { run("playpause", launching: true) }
    func next() { run("next track", launching: false) }
    func previous() { run("previous track", launching: false) }

    struct Favorite: Equatable, Sendable {
        let id: String
        let enabled: Bool
    }

    func favorite() async -> Favorite? {
        guard isRunning, track != nil else { return nil }
        let result = await execute("""
        tell application id "com.apple.Music"
            set t to current track
            return {persistent ID of t, favorited of t as string}
        end tell
        """)
        guard result.error == nil, result.strings.count == 2,
              ["true", "false"].contains(result.strings[1]) else { return nil }
        return Favorite(id: result.strings[0], enabled: result.strings[1] == "true")
    }

    /// Bind the write to the track shown when the button was pressed, even across a skip.
    func toggleFavorite(_ favorite: Favorite) async -> Bool {
        guard isRunning, !favorite.id.isEmpty,
              favorite.id.allSatisfy({ $0.isHexDigit }) else { return false }
        let result = await execute("""
        tell application id "com.apple.Music"
            set t to current track
            if persistent ID of t is not "\(favorite.id)" then return "changed"
            set favorited of t to not (favorited of t)
            return "ok"
        end tell
        """)
        return result.error == nil && result.strings.first == "ok"
    }

    /// Seconds into the current track, if Music says.
    func playerPosition() async -> Double? {
        let result = await execute("tell application id \"\(Self.bundleID)\" to return player position")
        return result.strings.first.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
    }

    func airPlayEnabled() async -> Bool {
        guard isRunning else { return false }
        let result = await execute("tell application id \"com.apple.Music\" to get AirPlay enabled as string")
        return result.error == nil && result.strings.first == "true"
    }

    func revealCurrentTrack() {
        guard isRunning else { return }
        run("activate", launching: false)
        run("reveal current track", launching: false)
    }

    /// Quits Music the way ⌘Q does (it may still ask about unsaved changes).
    func quit() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first?.terminate()
    }

    /// Opens Privacy & Security → Automation.
    func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    /// Music can return the previous album's image for a URL track even with the correct
    /// persistent ID. Read local/library artwork only, using the same track for tags and bytes.
    func currentArtwork(for track: Track) async -> Data? {
        guard isRunning, !Task.isCancelled else { return nil }
        let result = await execute("""
        tell application id "\(Self.bundleID)"
            with timeout of 2 seconds
                set t to current track
                if class of t is URL track then return missing value
                set trackID to persistent ID of t
                set details to {name of t, artist of t, album of t, trackID}
                try
                    set pictureBytes to raw data of artwork 1 of t
                on error
                    set pictureBytes to data of artwork 1 of t
                end try
                if persistent ID of current track is not trackID then return missing value
                return details & {pictureBytes}
            end timeout
        end tell
        """, binaryItem: 5)
        let items = result.strings
        guard items.count == 5, let id = Self.persistentID(items[3]),
              track.matches(Track(name: items[0], artist: items[1], album: items[2], persistentID: id)) else { return nil }
        return result.data
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// Sends a command. Only play/pause may launch Music; the rest are ignored while it is closed.
    private func run(_ command: String, launching: Bool) {
        guard launching || isRunning else { return }
        Task { await execute("tell application id \"\(Self.bundleID)\" to \(command)") }
    }

    private func queryState() {
        stateQueryRevision += 1
        let revision = stateQueryRevision
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
                    set details to {playerState, name of t, artist of t, album of t}
                    try
                        set end of details to persistent ID of t
                    on error
                        set end of details to ""
                    end try
                    try
                        set end of details to (round ((duration of t) * 1000)) as string
                    end try
                    return details
                on error
                    return {playerState}
                end try
            end tell
            """)
            let items = result.strings
            guard revision == stateQueryRevision, !items.isEmpty else { return }
            let track = items.count >= 5 ? Track(name: items[1], artist: items[2], album: items[3],
                                                 persistentID: Self.persistentID(items[4]),
                                                 durationMS: items.count > 5 ? Int(items[5]) : nil) : nil
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
    private func execute(_ source: String, binaryItem: Int? = nil) async -> ScriptResult {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ScriptResult, Never>) in
            scriptQueue.async {
                var error: NSDictionary?
                var result = ScriptResult()
                if let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error) {
                    let count = descriptor.numberOfItems
                    if count > 0 {
                        result.strings = (1...count).map { $0 == binaryItem ? "" : descriptor.atIndex($0)?.stringValue ?? "" }
                        if let binaryItem, binaryItem <= count { result.data = descriptor.atIndex(binaryItem)?.data }
                    } else if let text = descriptor.stringValue {
                        result.strings = [text]
                    }
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

    private func apply(playerState: String?, track: Track?, newPlayback: Bool = false) {
        let newState: State = switch playerState?.lowercased() {
        case "playing": .playing
        case "paused": .paused
        case "stopped": .stopped
        default: isRunning ? .stopped : .notRunning
        }
        update(state: newState, track: newState == .stopped || newState == .notRunning ? nil : track ?? self.track,
               newPlayback: newPlayback)
    }

    private func update(state: State, track: Track?, newPlayback: Bool = false) {
        let trackChanged = newPlayback || track != self.track
        guard state != self.state || trackChanged else { return }
        if trackChanged { playbackRevision += 1 }
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
