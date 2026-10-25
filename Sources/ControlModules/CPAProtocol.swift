import DockCore
import Foundation

/// The two AI subscriptions whose quotas the VibeCoding scene shows, read through CPA
/// (CLIProxyAPI), which holds both accounts' sign-ins on a server.
public enum AIService: String, CaseIterable, Sendable {
    case codex, claude
    public var name: String { self == .codex ? "Codex" : "Claude" }
    /// CPA's `provider` for this service's accounts.
    var provider: String { rawValue }
    /// The desktop app the open key launches (`ChatGPT.app` carries Codex's bundle ID).
    public var bundleID: String { self == .codex ? "com.openai.codex" : "com.anthropic.claudefordesktop" }
    /// The meter fill: each app icon's own dominant color (sampled 2026-10-25). The M18 panel
    /// washes colors out, so these are the icons' saturated tones, not the softer brand palettes.
    public var color: RGB { self == .codex ? RGB(hex: "#576EFE") : RGB(hex: "#E4643F") }
    /// Codex ships inside ChatGPT.app, whose own icon is ChatGPT's; its Codex icon is a resource there.
    var iconResource: String? { self == .codex ? "icon-codex-light.png" : nil }
    /// The open key's full-bleed ground under the icon's glyph: Codex's white tile, Claude's orange.
    public var iconGround: RGB { self == .codex ? .white : color }
    /// The one upstream request made with this service's credential: a GET for its quota.
    /// Nothing else is ever sent (no reset-credit redemption, no credential changes).
    var usageRequest: (url: String, header: [String: String]) {
        switch self {
        case .claude: ("https://api.anthropic.com/api/oauth/usage", ["anthropic-beta": "oauth-2025-04-20"])
        case .codex: ("https://chatgpt.com/backend-api/wham/usage", [:])
        }
    }
}

/// One rolling usage window (the 5-hour session or the week).
public struct QuotaWindow: Equatable, Sendable {
    public var usedPercent: Double
    public var resetsAt: Date?
    /// What is left, 0...1.
    public var remaining: Double { min(1, max(0, (100 - usedPercent) / 100)) }
}

public struct QuotaSnapshot: Equatable, Sendable {
    public var session: QuotaWindow?
    public var weekly: QuotaWindow?
    /// Codex rate-limit reset credits on hand.
    public var resetCredits: Int?
    /// Codex credits balance (nil when the account has none).
    public var credits: Double?

    /// Anthropic's `/api/oauth/usage`: `five_hour` / `seven_day` with `utilization` and ISO `resets_at`.
    static func claude(_ json: [String: Any]) -> QuotaSnapshot {
        func window(_ key: String) -> QuotaWindow? {
            guard let body = json[key] as? [String: Any], let used = number(body["utilization"]) else { return nil }
            return QuotaWindow(usedPercent: used, resetsAt: (body["resets_at"] as? String).flatMap(isoDate))
        }
        return QuotaSnapshot(session: window("five_hour"), weekly: window("seven_day"))
    }

    /// ChatGPT's `/wham/usage`: windows told apart by their length (a plan may have only a weekly one).
    static func codex(_ json: [String: Any]) -> QuotaSnapshot {
        var snapshot = QuotaSnapshot()
        let limits = json["rate_limit"] as? [String: Any] ?? [:]
        for key in ["primary_window", "secondary_window"] {
            guard let body = limits[key] as? [String: Any], let used = number(body["used_percent"]) else { continue }
            let window = QuotaWindow(usedPercent: used, resetsAt: number(body["reset_at"]).map { Date(timeIntervalSince1970: $0) })
            if (number(body["limit_window_seconds"]) ?? 0) <= 86_400 { snapshot.session = window } else { snapshot.weekly = window }
        }
        snapshot.resetCredits = ((json["rate_limit_reset_credits"] as? [String: Any])?["available_count"]).flatMap(number).map { Int($0) }
        if let credits = json["credits"] as? [String: Any], credits["has_credits"] as? Bool == true {
            snapshot.credits = number(credits["balance"])
        }
        return snapshot
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
    /// ISO 8601 with any number of fractional digits ("…06:40:00.440933+00:00").
    static func isoDate(_ text: String) -> Date? {
        let plain = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: plain)
    }
}

/// An account CPA holds, from `/v0/management/auth-files`.
public struct CPAAccount: Identifiable, Equatable, Sendable {
    /// The credential file name; stable, so settings remember it.
    public let id: String
    let authIndex: String
    public let provider: String
    public let email: String
    public let active: Bool

    static func list(_ json: [String: Any]) -> [CPAAccount] {
        (json["files"] as? [[String: Any]] ?? []).compactMap { file in
            guard let name = file["name"] as? String, let index = file["auth_index"] as? String,
                  let provider = file["provider"] as? String else { return nil }
            let usable = file["disabled"] as? Bool != true && file["unavailable"] as? Bool != true
            return CPAAccount(id: name, authIndex: index, provider: provider.lowercased(),
                              email: file["email"] as? String ?? name, active: usable)
        }
    }
}

struct CPAFailure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// The CPA server address. The management key it is sent with can act on every account CPA
/// holds, so plain HTTP is accepted only to this Mac.
struct CPAEndpoint: Equatable {
    let base: URL
    init(_ text: String) throws {
        var input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.contains("://") { input = "https://" + input }
        guard var parts = URLComponents(string: input), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw CPAFailure("请输入有效的 CPA 地址，例如 https://cpa.example.com")
        }
        guard scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(host) else {
            throw CPAFailure("管理密钥只能通过 HTTPS 发送（本机地址除外）")
        }
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !parts.path.isEmpty { parts.path = "/" + parts.path }
        guard let url = parts.url else { throw CPAFailure("CPA 地址无效") }
        base = url
    }
    var authFiles: URL { base.appendingPathComponent("v0/management/auth-files") }
    var apiCall: URL { base.appendingPathComponent("v0/management/api-call") }
}
