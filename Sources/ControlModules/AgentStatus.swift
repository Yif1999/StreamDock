import Foundation

/// What Codex and Claude are doing, session by session, as the light strip shows it
/// (docs/design.md, 编程助手提醒). Events come from the apps' hooks and session logs; a state
/// ends only on a clear signal (done, failed, interrupted, the session or the app ending, you
/// looking at the app), never on a timeout: a long quiet task still shows as working.
@MainActor
public final class AgentStatus {
    /// One thing that happened in a session, whichever source reported it.
    public enum Event: String, Sendable {
        /// You sent a message: it is working.
        case prompt
        /// It needs you to approve something or answer.
        case approval
        /// It carried on (a tool ran), so any approval was given.
        case resumed
        case done, failed
        /// You stopped it yourself: back to idle, no reminder.
        case interrupted
        /// It says it is waiting for your input (Claude's idle notice). Ends work, or a wait for
        /// approval, it never reported finishing — as after an interrupt or a declined request,
        /// which Claude reports with no hook at all; reminders stay. Claude Code may send it in a
        /// terminal; the desktop app was seen not to (2026-10-25).
        case idle
        /// The session closed.
        case ended
    }

    /// How one app shows on the strip at a moment.
    public enum Light: Equatable, Sendable {
        case idle, cruise
        case summon(quiet: Bool)
        /// The moment it finished (`since` on the status clock), then `hold` until you look.
        case close(since: TimeInterval)
        case hold
        /// The moment it failed, then `fault` until you look.
        case fail(since: TimeInterval)
        case fault

        /// Same-tier lights take turns on the ring; a higher tier takes it alone.
        public var tier: Int {
            switch self {
            case .idle: 0
            case .cruise: 1
            case .hold, .fault: 2
            case .close, .fail: 3
            case .summon: 4
            }
        }
    }

    enum State: Equatable { case working, summon, done, failed }
    struct Session: Equatable {
        var state: State
        /// When it entered `state`.
        var since: TimeInterval
        /// Done or failed while you were looking, or looked at since: no lasting reminder.
        var seen = false
    }
    struct Key: Hashable {
        let service: AIService
        let id: String
    }

    private(set) var sessions: [Key: Session] = [:]
    /// The app in front, if it is one of the two.
    public private(set) var frontmost: AIService?
    var onChange: (() -> Void)?

    public init() {}

    public func record(_ event: Event, service: AIService, session id: String, at time: TimeInterval) {
        let key = Key(service: service, id: id)
        let current = sessions[key]
        switch event {
        case .prompt:
            set(key, Session(state: .working, since: time), from: current)
        case .approval:
            set(key, Session(state: .summon, since: time), from: current)
        case .resumed:
            // A tool ran: whatever was asked was answered. It only ever means working again.
            guard current?.state != .working else { return }
            guard current == nil || current?.state == .summon else { return }
            set(key, Session(state: .working, since: time), from: current)
        case .done, .failed:
            // A late duplicate (hook and log both report the end) changes nothing.
            let state: State = event == .done ? .done : .failed
            guard current?.state != state else { return }
            set(key, Session(state: state, since: time, seen: frontmost == service), from: current)
        case .idle:
            guard current?.state == .working || current?.state == .summon else { return }
            sessions[key] = nil
            onChange?()
        case .interrupted, .ended:
            guard current != nil else { return }
            sessions[key] = nil
            onChange?()
        }
    }

    /// The app in front changed: looking at an app clears its finished and failed reminders.
    public func setFrontmost(_ service: AIService?) {
        guard frontmost != service else { return }
        frontmost = service
        if let service {
            for (key, session) in sessions where key.service == service && [.done, .failed].contains(session.state) {
                sessions[key]?.seen = true
            }
        }
        onChange?()
    }

    /// The app quit: none of its sessions are running any more.
    public func appQuit(_ service: AIService) {
        let before = sessions.count
        sessions = sessions.filter { $0.key.service != service }
        if sessions.count != before { onChange?() }
    }

    /// Forgets sessions that have nothing left to show: finished or failed, seen, moment played.
    func prune(at time: TimeInterval) {
        let settled = max(AgentLight.closeDuration, AgentLight.failDuration)
        sessions = sessions.filter { !([.done, .failed].contains($0.value.state) && $0.value.seen && time - $0.value.since > settled) }
    }

    /// The session of `service` that moved last among those working or waiting on you: the one
    /// you are most likely looking at.
    func latestActiveSession(of service: AIService) -> String? {
        sessions.filter { $0.key.service == service && [.working, .summon].contains($0.value.state) }
            .max { $0.value.since < $1.value.since }?.key.id
    }

    /// Sessions of `service` that are working or waiting on you, for watchers that need them.
    func activeSessions(of service: AIService) -> [String] {
        sessions.filter { $0.key.service == service && [.working, .summon].contains($0.value.state) }.map(\.key.id)
    }

    /// The most urgent thing about `service` at `time`.
    public func light(for service: AIService, at time: TimeInterval) -> Light {
        let mine = sessions.filter { $0.key.service == service }.map(\.value)
        if mine.contains(where: { $0.state == .summon }) { return .summon(quiet: frontmost == service) }
        if let failed = mine.filter({ $0.state == .failed }).max(by: { $0.since < $1.since }) {
            if time - failed.since < AgentLight.failDuration { return .fail(since: failed.since) }
            if mine.contains(where: { $0.state == .failed && !$0.seen }) { return .fault }
        }
        if let done = mine.filter({ $0.state == .done }).max(by: { $0.since < $1.since }) {
            if time - done.since < AgentLight.closeDuration { return .close(since: done.since) }
            if mine.contains(where: { $0.state == .done && !$0.seen }) { return .hold }
        }
        if mine.contains(where: { $0.state == .working }) { return .cruise }
        return .idle
    }

    /// Whether anything is showing (or about to finish showing) for either app.
    public func isIdle(at time: TimeInterval) -> Bool {
        AIService.allCases.allSatisfy { light(for: $0, at: time) == .idle }
    }

    private func set(_ key: Key, _ session: Session, from current: Session?) {
        guard session != current else { return }
        sessions[key] = session
        onChange?()
    }
}
