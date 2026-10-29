import DockCore
import Foundation
import Testing
@testable import ControlModules

/// Upstream replies trimmed from a real probe (2026-10-25), accounts anonymized.
private let claudeUsage = #"{"five_hour":{"utilization":17,"resets_at":"2026-10-25T06:40:00.440933+00:00"},"seven_day":{"utilization":7,"resets_at":"2026-10-31T15:00:00.440951+00:00"},"extra_usage":{"is_enabled":false}}"#
private let codexPlus = #"{"plan_type":"plus","credits":{"balance":"73487.1743720000","has_credits":true,"unlimited":false},"rate_limit":{"primary_window":{"limit_window_seconds":18000,"reset_at":1792913864,"used_percent":3},"secondary_window":{"limit_window_seconds":604800,"reset_at":1793430539,"used_percent":19}},"rate_limit_reset_credits":{"available_count":2}}"#
private let codexWeeklyOnly = #"{"plan_type":"prolite","credits":{"balance":"0","has_credits":false},"rate_limit":{"primary_window":{"limit_window_seconds":604800,"reset_at":1793501360,"used_percent":0},"secondary_window":null},"rate_limit_reset_credits":{"available_count":0}}"#
private let authFiles = #"{"files":[{"name":"antigravity-a.json","auth_index":"a1","provider":"antigravity"},{"name":"claude-me.json","auth_index":"c1","provider":"claude","email":"me@example.com"},{"name":"codex-a-prolite.json","auth_index":"x1","provider":"codex"},{"name":"codex-b-plus.json","auth_index":"x2","provider":"codex"}]}"#

private func json(_ text: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any] }

/// A CPA stand-in that records every request.
private final class FakeCPA: @unchecked Sendable {
    var requests: [URLRequest] = []
    var managementStatus = 200
    func send(_ request: URLRequest) -> (Data, Int) {
        requests.append(request)
        guard managementStatus == 200 else { return (Data(#"{"error":"invalid management key"}"#.utf8), managementStatus) }
        if request.url?.path.hasSuffix("auth-files") == true { return (Data(authFiles.utf8), 200) }
        let call = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let body: String
        switch (call["url"] as? String ?? "", call["auth_index"] as? String ?? "") {
        case (let url, "c1") where url.contains("anthropic"): body = claudeUsage
        case (let url, "x1") where url.contains("wham/usage"): body = codexWeeklyOnly
        case (let url, "x2") where url.contains("wham/usage"): body = codexPlus
        default: return (Data(#"{"status_code":404,"body":""}"#.utf8), 200)
        }
        let reply = try! JSONSerialization.data(withJSONObject: ["status_code": 200, "body": body])
        return (reply, 200)
    }
}

@MainActor struct CPAClientTests {
    @Test func quotasParseFromBothServices() throws {
        let claude = QuotaSnapshot.claude(json(claudeUsage))
        #expect(claude.session?.remaining == 0.83 && claude.weekly?.remaining == 0.93)
        #expect(claude.session?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-25T06:40:00Z"))
        #expect(claude.resetCredits == nil && claude.credits == nil)
        let plus = QuotaSnapshot.codex(json(codexPlus))
        #expect(plus.session?.usedPercent == 3 && plus.weekly?.usedPercent == 19)
        #expect(plus.resetCredits == 2 && plus.credits == 73487.174372)
        // Windows are told apart by length, not position: this plan's only window is weekly.
        let weekly = QuotaSnapshot.codex(json(codexWeeklyOnly))
        #expect(weekly.session == nil && weekly.weekly?.remaining == 1 && weekly.credits == nil)
    }

    @Test func managementKeyTravelsOnlyOverHTTPS() throws {
        #expect(try CPAEndpoint("cpa.example.com/").base.absoluteString == "https://cpa.example.com")
        #expect(try CPAEndpoint("http://127.0.0.1:8317").base.absoluteString == "http://127.0.0.1:8317")
        for value in ["", "http://cpa.example.com", "ftp://cpa.example.com", "https://u:p@cpa.example.com", "https://cpa.example.com/?k=1"] {
            #expect(throws: (any Error).self) { try CPAEndpoint(value) }
        }
    }

    @Test func readsQuotasWithGETsOnlyAndRemembersTheAccount() async throws {
        let (defaults, cleanup) = temporaryDefaults()
        defer { cleanup() }
        let fake = FakeCPA()
        let secrets = MemorySecrets()
        let client = CPAClient(defaults: defaults, secrets: secrets, send: { fake.send($0) })
        #expect(client.configure(address: "https://cpa.example.com", key: "management-secret"))
        await client.refresh()
        #expect(client.status != .unset && client.errors.isEmpty)
        #expect(client.quotas[.claude]?.session?.usedPercent == 17)
        // Unset picks the first active account by name: here the weekly-only one.
        #expect(client.account(for: .codex)?.id == "codex-a-prolite.json" && client.quotas[.codex]?.session == nil)
        client.choose("codex-b-plus.json", for: .codex)
        await client.refresh()
        #expect(client.quotas[.codex]?.resetCredits == 2)
        #expect(CPAClient(defaults: defaults, secrets: secrets).account(for: .codex) == nil) // Accounts load on refresh…
        #expect(CPAClient(defaults: defaults, secrets: secrets).chosen[.codex] == "codex-b-plus.json") // …the choice is saved.
        // Every request carries the management key; upstream calls are fixed quota GETs with CPA's token placeholder.
        let allowed = Set(AIService.allCases.map(\.usageRequest.url))
        for request in fake.requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer management-secret")
            guard request.httpMethod == "POST" else { continue }
            let call = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            #expect(call["method"] as? String == "GET" && allowed.contains(call["url"] as? String ?? ""))
            #expect((call["header"] as? [String: String])?["Authorization"] == "Bearer $TOKEN$")
        }
        #expect(!defaults.dictionaryRepresentation().description.contains("management-secret"))
        fake.managementStatus = 401
        await client.refresh()
        #expect(client.status == .failed("CPA 管理密钥无效"))
        #expect(client.quotas[.codex]?.resetCredits == 2) // The last good reading stays on the keys.
    }

    @Test func aRowRefreshesOnlyItsServiceAndTheSceneUsesAFiveMinuteCache() async throws {
        let (defaults, cleanup) = temporaryDefaults()
        defer { cleanup() }
        let fake = FakeCPA()
        // Already set up (saving would start a refresh of its own).
        let secrets = MemorySecrets()
        secrets.values["https://cpa.example.com"] = "k"
        defaults.set("https://cpa.example.com", forKey: "cpaAddress")
        let client = CPAClient(defaults: defaults, secrets: secrets, send: { fake.send($0) })
        var now = ContinuousClock.now
        client.clock = { now }
        let upstream = { fake.requests.compactMap { request -> String? in
            guard let body = request.httpBody else { return nil }
            return (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["url"] as? String
        } }
        let enter = { (count: Int) in
            let module = AIQuotaModule(client: client)
            module.sceneDidActivate()
            let deadline = ContinuousClock.now + .seconds(5)
            while upstream().count < count && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(100))  // Nothing more comes.
            module.sceneDidDeactivate()
        }
        await client.refresh([.claude])  // A Claude key press.
        #expect(upstream() == [AIService.claude.usageRequest.url])
        // Coming on screen queries only what is not cached: Codex.
        try await enter(2)
        #expect(upstream() == [AIService.claude.usageRequest.url, AIService.codex.usageRequest.url])
        // Back within five minutes: the cache, no queries.
        now += .seconds(299)
        try await enter(2)
        #expect(upstream().count == 2)
        // Past five minutes: both again.
        now += .seconds(2)
        try await enter(4)
        #expect(upstream().count == 4)
        // A key press always queries.
        await client.refresh([.codex])
        #expect(upstream().count == 5)
        #expect(await client.refreshStale() == .seconds(300))  // Both fresh: the next round is a full interval away.
    }

    @Test func keysShowWhatIsLeftOverAFillInTheServiceColor() async throws {
        let (defaults, cleanup) = temporaryDefaults()
        defer { cleanup() }
        let fake = FakeCPA()
        let client = CPAClient(defaults: defaults, secrets: MemorySecrets(), send: { fake.send($0) })
        let module = AIQuotaModule(client: client)
        #expect(module.face(forSlot: 1) == KeyFace(title: "—", caption: "5h", tone: .dim))
        client.configure(address: "https://cpa.example.com", key: "k")
        client.choose("codex-b-plus.json", for: .codex)
        await client.refresh()
        module.now = { ISO8601DateFormatter().date(from: "2026-10-25T03:00:00Z")! }
        // The gauges fill up from empty to their first reading, then hold it.
        #expect(module.face(forSlot: 1).meter!.fraction < 0.05)
        _ = (module.face(forSlot: 2), module.face(forSlot: 6))
        let deadline = ContinuousClock.now + .seconds(3)
        while module.gauges.isAnimating && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(module.face(forSlot: 1) == KeyFace(title: "97%", caption: "5h", meter: KeyMeter(fraction: 0.97, color: AIService.codex.color)))
        #expect(module.face(forSlot: 2).title == "81%")
        #expect(module.face(forSlot: 3) == KeyFace(title: "2", caption: "Resets"))
        #expect(module.face(forSlot: 4) == KeyFace(title: "73k", caption: "Credits"))
        #expect(module.face(forSlot: 6).meter == KeyMeter(fraction: 0.83, color: AIService.claude.color))
        #expect(module.face(forSlot: 8) == KeyFace(title: "3h40", caption: "5h Reset"))
        #expect(module.face(forSlot: 9).title == "6d12h")
    }

    @Test func countdownsAndAmountsStayShort() {
        #expect(AIQuotaModule.countdown(-5) == "0m")
        #expect(AIQuotaModule.countdown(44 * 60 + 50) == "44m")
        #expect(AIQuotaModule.countdown(3 * 3600 + 5 * 60) == "3h05")
        #expect(AIQuotaModule.countdown(2 * 86400) == "2d")
        #expect(AIQuotaModule.amount(850.4) == "850" && AIQuotaModule.amount(7342) == "7.3k")
        #expect(AIQuotaModule.amount(73487.17) == "73k" && AIQuotaModule.amount(1_250_000) == "1.2M")
    }
}
