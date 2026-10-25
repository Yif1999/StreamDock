import AppKit
import DockCore

/// VibeCoding row 3: Accept | Stop | New | Send | Voice, sent as keystrokes to the Codex or
/// Claude desktop app, and only while one of them is the frontmost app; otherwise the keys
/// dim and send nothing. Shortcuts were read from the apps themselves (2026-10-25):
/// Codex's command table binds Approve request to Enter and Decline request to Escape, its
/// new chat to ⌘⇧O; Claude's menu binds New to ⌘N. Voice holds Fn for as long as the key is
/// held (the user's input method dictates while Fn is down).
@MainActor
public final class AgentKeysModule: DockModule {
    public let keyCount = 5

    /// A key press: a virtual key code and its modifiers.
    struct Keystroke: Equatable {
        let key: CGKeyCode
        var flags: CGEventFlags = []
        static let enter = Keystroke(key: 36), escape = Keystroke(key: 53)
    }
    enum Action: Int, CaseIterable { case accept, stop, new, send, voice }
    /// The desktop apps the row talks to.
    static let targets: [String: AIService] = [AIService.codex.bundleID: .codex, AIService.claude.bundleID: .claude]
    /// Fn's virtual key code.
    static let fn: CGKeyCode = 63

    private var context: ModuleContext?
    private var observer: NSObjectProtocol?
    private var voiceHeld = false
    // The system's side, replaceable in tests.
    var frontmost: @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var press: @MainActor (Keystroke) -> Void = AgentKeysModule.post
    var setFn: @MainActor (Bool) -> Void = AgentKeysModule.postFn
    var permitted: @MainActor () -> Bool = AgentKeysModule.ensurePermission

    public init() {}

    public func attach(_ context: ModuleContext) {
        self.context = context
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Switching away mid-dictation must not leave Fn down.
                if self?.target == nil { self?.releaseVoice() }
                self?.context?.setNeedsDisplay()
            }
        }
    }

    var target: AIService? { frontmost().flatMap { Self.targets[$0] } }

    public func face(forSlot slot: Int) -> KeyFace {
        guard let action = Action(rawValue: slot) else { return .blank }
        let (symbol, label): (String, String) = switch action {
        case .accept: ("checkmark", "Accept")
        case .stop: ("stop.fill", "Stop")
        case .new: ("plus", "New")
        case .send: ("arrow.up", "Send")
        case .voice: ("mic.fill", "Voice")
        }
        let tone: KeyTone = target == nil ? .dim : action == .voice && voiceHeld ? .on : .normal
        return KeyFace(symbol: symbol, caption: label, tone: tone)
    }

    public func keyDown(slot: Int) {
        guard let action = Action(rawValue: slot), let target else { return }
        guard permitted() else { return }
        switch action {
        case .accept, .send: press(.enter)
        case .stop: press(.escape)
        case .new: press(target == .codex ? Keystroke(key: 31, flags: [.maskCommand, .maskShift])  // ⌘⇧O
                                          : Keystroke(key: 45, flags: .maskCommand))            // ⌘N
        case .voice:
            guard !voiceHeld else { return }
            voiceHeld = true
            setFn(true)
            context?.setNeedsDisplay()
        }
    }

    public func keyUp(slot: Int) {
        if slot == Action.voice.rawValue { releaseVoice() }
    }

    public func sceneDidDeactivate() { releaseVoice() }

    private func releaseVoice() {
        guard voiceHeld else { return }
        voiceHeld = false
        setFn(false)
        context?.setNeedsDisplay()
    }

    // MARK: - Keystrokes

    /// Sending keys to another app needs the Accessibility permission; the first press asks.
    static func ensurePermission() -> Bool {
        CGPreflightPostEventAccess() || CGRequestPostEventAccess()
    }

    static func post(_ stroke: Keystroke) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.key, keyDown: down)
            event?.flags = stroke.flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Fn is a modifier: it goes down and up as a flags change, not a key press.
    static func postFn(_ down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: fn, keyDown: down)
        event?.type = .flagsChanged
        event?.flags = down ? .maskSecondaryFn : []
        event?.post(tap: .cghidEventTap)
    }
}
