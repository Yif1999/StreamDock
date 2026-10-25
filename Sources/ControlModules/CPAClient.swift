import Foundation
import Observation

/// Reads the Codex and Claude quotas through CPA's management API: the account list, then one
/// `api-call` GET per service, made by CPA with that account's credential (which never leaves
/// the server). Upstream quotas have no push, so this polls, only while the VibeCoding scene is
/// on screen. A reading is good for `interval` (5 minutes): coming back to the scene within it
/// shows the cached one and queries nothing; only a deliberate refresh (a quota key, Settings,
/// a new address or account) queries before it runs out.
@MainActor @Observable
public final class CPAClient {
    public static let shared = CPAClient()
    public enum Status: Equatable {
        case unset, loading, ready(Date), failed(String)
        public var description: String {
            switch self {
            case .unset: "请填写 CPA 地址和管理密钥"
            case .loading: "正在读取…"
            case .ready(let date): "已更新 \(date.formatted(date: .omitted, time: .standard))"
            case .failed(let text): text
            }
        }
    }
    public private(set) var address: String
    public private(set) var status: Status = .unset
    public private(set) var accounts: [CPAAccount] = []
    public private(set) var quotas: [AIService: QuotaSnapshot] = [:]
    /// Per-service failures; the last good snapshot stays on the keys.
    public private(set) var errors: [AIService: String] = [:]
    /// Chosen account (credential file name) per service; unset picks the first active one.
    public private(set) var chosen: [AIService: String]
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let send: @Sendable (URLRequest) async throws -> (Data, Int)
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var poll: Task<Void, Never>?
    /// Services with a query on the way; a second request for one of them is dropped.
    @ObservationIgnored private var inFlight: Set<AIService> = []
    @ObservationIgnored private var generation = UUID()
    /// When each service was last queried; its reading counts as fresh for `interval` after.
    @ObservationIgnored private var queried: [AIService: ContinuousClock.Instant] = [:]
    /// The clock the cache reads; tests move it on.
    @ObservationIgnored var clock: () -> ContinuousClock.Instant = { ContinuousClock.now }

    init(defaults: UserDefaults = .standard, secrets: any SecretStore = Keychain.cpa, interval: Duration = .seconds(300),
         send: @escaping @Sendable (URLRequest) async throws -> (Data, Int) = CPAClient.urlSession) {
        self.defaults = defaults; self.secrets = secrets; self.interval = interval; self.send = send
        address = defaults.string(forKey: "cpaAddress") ?? ""
        let saved = defaults.dictionary(forKey: "cpaAccounts") as? [String: String] ?? [:]
        chosen = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in AIService(rawValue: key).map { ($0, value) } })
    }
    nonisolated static func urlSession(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    @discardableResult public func configure(address: String, key: String) -> Bool {
        do {
            let endpoint = try CPAEndpoint(address)
            let account = endpoint.base.absoluteString
            let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                guard let existing = try secrets.read(account: account), !existing.isEmpty else { throw CPAFailure("请输入 CPA 管理密钥") }
            } else { try secrets.save(clean, account: account) }
            self.address = account
            defaults.set(account, forKey: "cpaAddress")
            reset()
            refreshNow()
            return true
        } catch { status = .failed(error.localizedDescription); onChange?(); return false }
    }
    public func removeKey() {
        do {
            if let endpoint = try? CPAEndpoint(address) { try secrets.delete(account: endpoint.base.absoluteString) }
            reset(); status = .unset
        } catch { status = .failed(error.localizedDescription) }
        onChange?()
    }
    public func choose(_ accountID: String?, for service: AIService) {
        chosen[service] = accountID
        defaults.set(Dictionary(uniqueKeysWithValues: chosen.map { ($0.key.rawValue, $0.value) }), forKey: "cpaAccounts")
        quotas[service] = nil; errors[service] = nil
        refreshNow([service])
    }
    public func choices(for service: AIService) -> [CPAAccount] { accounts.filter { $0.provider == service.provider } }
    public func account(for service: AIService) -> CPAAccount? {
        let candidates = choices(for: service)
        if let id = chosen[service], let account = candidates.first(where: { $0.id == id }) { return account }
        return candidates.filter(\.active).min { $0.id < $1.id }
    }

    /// Polls until `stop()`: the VibeCoding scene calls these as it comes on and off screen. Each
    /// round queries only the services whose reading has run out, then sleeps until the next one does.
    public func start() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = await self?.refreshStale() else { return }
                do { try await Task.sleep(for: wait) } catch { return }
            }
        }
    }
    public func stop() { poll?.cancel(); poll = nil }
    /// Queries the given services now, cached or not (a row's key refreshes only its own service).
    public func refreshNow(_ services: Set<AIService> = Set(AIService.allCases)) { Task { await refresh(services) } }

    /// Queries the services not queried within `interval`; returns how long until the next one is due.
    func refreshStale() async -> Duration {
        let now = clock()
        let stale = AIService.allCases.filter { queried[$0].map { now - $0 >= interval } ?? true }
        if !stale.isEmpty { await refresh(Set(stale)) }
        let later = clock()
        let next = AIService.allCases.map { queried[$0].map { $0 + interval - later } ?? interval }.min() ?? interval
        return max(next, .zero)
    }

    private func reset() {
        generation = UUID()
        accounts = []; quotas = [:]; errors = [:]; queried = [:]
    }

    func refresh(_ services: Set<AIService> = Set(AIService.allCases)) async {
        let wanted = services.subtracting(inFlight)
        guard !wanted.isEmpty else { return }
        guard let endpoint = try? CPAEndpoint(address), let key = try? secrets.read(account: endpoint.base.absoluteString), !key.isEmpty else {
            status = .unset; onChange?(); return
        }
        inFlight.formUnion(wanted)
        defer { inFlight.subtract(wanted) }
        let stamp = generation
        // A failed query counts too: it is tried again when the interval runs out, or on a key press.
        for service in wanted { queried[service] = clock() }
        if quotas.isEmpty { status = .loading; onChange?() }
        do {
            let list = try await management(endpoint.authFiles, key: key)
            guard generation == stamp else { return }
            accounts = CPAAccount.list(list).sorted { $0.id < $1.id }
            for service in AIService.allCases where wanted.contains(service) {
                guard let account = account(for: service) else {
                    quotas[service] = nil; errors[service] = "CPA 中没有 \(service.name) 账号"
                    continue
                }
                do {
                    let body = try await usage(service, account: account, endpoint: endpoint, key: key)
                    guard generation == stamp else { return }
                    quotas[service] = service == .claude ? .claude(body) : .codex(body)
                    errors[service] = nil
                } catch {
                    guard generation == stamp else { return }
                    errors[service] = error.localizedDescription
                }
            }
            status = .ready(Date())
        } catch {
            guard generation == stamp else { return }
            status = .failed(error.localizedDescription)
        }
        onChange?()
    }

    private func usage(_ service: AIService, account: CPAAccount, endpoint: CPAEndpoint, key: String) async throws -> [String: Any] {
        var header = service.usageRequest.header
        header["Authorization"] = "Bearer $TOKEN$"  // CPA puts the account's token here.
        let reply = try await management(endpoint.apiCall, key: key, body: [
            "auth_index": account.authIndex, "method": "GET", "url": service.usageRequest.url, "header": header,
        ])
        let code = QuotaSnapshot.number(reply["status_code"]).map(Int.init) ?? 0
        guard code == 200 else { throw CPAFailure("\(service.name) 额度查询返回 \(code)") }
        guard let text = reply["body"] as? String, let body = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CPAFailure("\(service.name) 额度格式无法识别")
        }
        return body
    }

    private func management(_ url: URL, key: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, code) = try await send(request)
        switch code {
        case 200: break
        case 401, 403: throw CPAFailure("CPA 管理密钥无效")
        case 404: throw CPAFailure("CPA 没有管理接口，请确认地址并开启远程管理")
        default: throw CPAFailure("CPA 返回 \(code)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CPAFailure("CPA 返回格式无法识别") }
        return json
    }
}
