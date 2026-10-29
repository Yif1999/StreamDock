import AppKit
import DockCore

/// VibeCoding rows 1–2: one row per service — open the app, then its quota.
///   Codex:  Open | 5h | Week | Resets | Credits
///   Claude: Open | 5h | Week | 5h reset countdown | Week reset countdown
/// Quota keys fill from the left with what is left, in the service's color (`KeyMeter`).
@MainActor
public final class AIQuotaModule: DockModule {
    public let keyCount = 10
    private let client: CPAClient
    private var context: ModuleContext?
    private var icons: [AIService: Data] = [:]
    /// The gauges glide to a new reading (a cached one replaced by a fresh one, say) instead of
    /// jumping; keyed by key slot.
    let gauges = ValueTransitions<Int>()
    /// The clock the countdowns read; tests pin it.
    var now: () -> Date = Date.init

    public convenience init() { self.init(client: .shared) }
    init(client: CPAClient) { self.client = client }

    public func attach(_ context: ModuleContext) {
        self.context = context
        gauges.redraw = { [weak self] in self?.context?.setNeedsDisplay() }
        client.onChange = { [weak self] in self?.context?.setNeedsDisplay() }
    }
    public func sceneDidActivate() { client.start(); context?.setNeedsDisplay() }
    public func sceneDidDeactivate() { client.stop() }

    public func face(forSlot slot: Int) -> KeyFace {
        let service: AIService = slot < 5 ? .codex : .claude
        let quota = client.quotas[service]
        switch (service, slot % 5) {
        case (_, 0):
            if let icon = icon(for: service) { return KeyFace(artwork: icon) }
            return KeyFace(symbol: "app.dashed", caption: service.name, tone: .dim)
        case (_, 1): return meter(quota?.session, label: "5h", service: service, slot: slot)
        case (_, 2): return meter(quota?.weekly, label: "Week", service: service, slot: slot)
        case (.codex, 3): return value(quota?.resetCredits.map(String.init), label: "Resets")
        case (.codex, _): return value(quota.map { $0.credits.map(Self.amount) ?? "0" }, label: "Credits")
        case (.claude, 3): return value(quota?.session.flatMap { countdown(to: $0.resetsAt) }, label: "5h Reset")
        case (.claude, _): return value(quota?.weekly.flatMap { countdown(to: $0.resetsAt) }, label: "Week Reset")
        }
    }

    public func keyDown(slot: Int) {
        let service: AIService = slot < 5 ? .codex : .claude
        guard slot % 5 == 0 else { return client.refreshNow([service]) }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: service.bundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Remaining share as a whole percent, over a fill of the same share; both glide to a new
    /// reading together (`gauges`).
    private func meter(_ window: QuotaWindow?, label: String, service: AIService, slot: Int) -> KeyFace {
        guard let window else { gauges.forget(slot); return value(nil, label: label) }
        let left = gauges.value(slot, target: window.remaining)
        return KeyFace(title: "\(Int((left * 100).rounded()))%", caption: label,
                       meter: KeyMeter(fraction: left, color: service.color))
    }
    private func value(_ text: String?, label: String) -> KeyFace {
        KeyFace(title: text ?? "—", caption: label, tone: text == nil ? .dim : .normal)
    }
    private func countdown(to date: Date?) -> String? {
        date.map { Self.countdown($0.timeIntervalSince(now())) }
    }

    /// "6d2h", "3h40", "45m": whole units left, never rounded up.
    static func countdown(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded(.down)))
        let (days, hours, rest) = (minutes / 1440, minutes % 1440 / 60, minutes % 60)
        if days > 0 { return hours > 0 ? "\(days)d\(hours)h" : "\(days)d" }
        if hours > 0 { return String(format: "%dh%02d", hours, rest) }
        return "\(rest)m"
    }
    /// "73k", "7.3k", "850", "1.2M".
    static func amount(_ value: Double) -> String {
        switch max(0, value) {
        case 1_000_000...: String(format: "%.1fM", value / 1_000_000)
        case 10_000...: "\(Int(value / 1000))k"
        case 1000...: String(format: "%.1fk", value / 1000)
        default: "\(Int(value))"
        }
    }

    private func icon(for service: AIService) -> Data? {
        if let cached = icons[service] { return cached }
        let icon = Self.icon(for: service)
        icons[service] = icon
        return icon
    }
    /// The open key's artwork: the service icon's glyph on a full-bleed ground (`IconGlyph`).
    public static func icon(for service: AIService) -> Data? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: service.bundleID) else { return nil }
        let resource = service.iconResource.map { url.appendingPathComponent("Contents/Resources").appendingPathComponent($0) }
        let image = resource.flatMap { NSImage(contentsOf: $0) } ?? NSWorkspace.shared.icon(forFile: url.path)
        return IconGlyph.key(icon: image, ground: service.iconGround)
    }
}
