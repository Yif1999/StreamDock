import AppKit
import Foundation
import Observation
import os

private let haLog = Logger(subsystem: "StreamDock", category: "HA")

@MainActor @Observable
public final class HAClient {
    public static let shared = HAClient()
    public enum Connection: Equatable {
        case offline(String), connecting, ready
        public var description: String {
            switch self {
            case .offline(let text): text
            case .connecting: "正在连接…"
            case .ready: "已连接 Home Assistant"
            }
        }
    }
    public private(set) var address: String
    public private(set) var connection: Connection = .offline("请填写地址和访问令牌")
    public private(set) var entities: [HAEntity] = []
    public private(set) var bindings: [HABinding]
    public private(set) var errorMessage: String?
    public private(set) var busySlot: Int?
    public private(set) var successSlot: Int?
    public private(set) var lastActionSlot: Int?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tokens: any HATokenStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var bootstrap: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var authenticated = false
    @ObservationIgnored private var services: HAData = [:]
    @ObservationIgnored private var changes: [String: HAValue] = [:]
    @ObservationIgnored private var pending: [Int: Pending] = [:]
    private struct Pending {
        let continuation: CheckedContinuation<HAValue, any Error>
        let timeout: Task<Void, Never>
    }
    /// How long a request may take before it is reported as timed out (not retried).
    @ObservationIgnored private let requestTimeout: Duration
    init(defaults: UserDefaults = .standard, tokens: any HATokenStore = HAKeychain(), requestTimeout: Duration = .seconds(6)) {
        self.defaults = defaults; self.tokens = tokens; self.requestTimeout = requestTimeout
        address = defaults.string(forKey: "haAddress") ?? ""
        let saved = defaults.data(forKey: "haBindings").flatMap { try? JSONDecoder().decode([HABinding].self, from: $0) }
        bindings = saved?.count == 15 ? saved! : Array(repeating: HABinding(), count: 15)
    }
    @discardableResult public func configure(address: String, token: String) -> Bool {
        do {
            let endpoint = try HAEndpoint(address)
            let account = endpoint.base.absoluteString
            let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                guard let existing = try tokens.read(account: account), !existing.isEmpty else { throw HAFailure.message("请输入 HA 的长期访问令牌") }
            } else { try tokens.save(clean, account: account) }
            self.address = account
            defaults.set(account, forKey: "haAddress")
            reconnect()
            return true
        } catch { errorMessage = error.localizedDescription; onChange?(); return false }
    }
    public func removeToken() {
        do {
            if let endpoint = try? HAEndpoint(address) { try tokens.delete(account: endpoint.base.absoluteString) }
            disconnect(); connection = .offline("令牌已移除"); onChange?()
        } catch { errorMessage = error.localizedDescription }
    }
    public func setBinding(_ binding: HABinding, at slot: Int) {
        guard bindings.indices.contains(slot) else { return }
        bindings[slot] = binding
        defaults.set(try? JSONEncoder().encode(bindings), forKey: "haBindings")
        successSlot = nil; errorMessage = nil; onChange?()
    }
    public func choices(for action: HAAction) -> [HAEntity] { entities.filter { action.accepts($0.domain) } }
    public func entity(for binding: HABinding) -> HAEntity? { entities.first { $0.id == binding.entityID } }
    public func openDashboard() {
        if let endpoint = try? HAEndpoint(address) { NSWorkspace.shared.open(endpoint.base) }
    }
    public func start() {
        guard task == nil, !address.isEmpty else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let retry = await self?.runSession() ?? false
                guard retry else { if !Task.isCancelled { self?.task = nil }; return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    public func reconnect() { disconnect(); start() }
    public func disconnect() {
        task?.cancel(); task = nil; clearSession()
        connection = .offline("HA 未连接"); onChange?()
    }
    private func clearSession() {
        generation = UUID()
        bootstrap?.cancel(); bootstrap = nil
        heartbeat?.cancel(); heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        authenticated = false
        let waiting = pending.values; pending.removeAll()
        for item in waiting { item.timeout.cancel(); item.continuation.resume(throwing: HAFailure.disconnected) }
        entities = []; services = [:]; changes = [:]
        busySlot = nil; successSlot = nil; lastActionSlot = nil
    }
    private func runSession() async -> Bool {
        let endpoint: HAEndpoint
        let accessToken: String
        do {
            endpoint = try HAEndpoint(address)
            guard let token = try tokens.read(account: endpoint.base.absoluteString), !token.isEmpty else { throw HAFailure.message("请在设置中填写 HA 访问令牌") }
            accessToken = token
        } catch { connection = .offline(error.localizedDescription); onChange?(); return false }
        let stamp = UUID(); generation = stamp
        let ws = URLSession.shared.webSocketTask(with: endpoint.websocket)
        socket = ws; ws.resume()
        connection = .connecting; errorMessage = nil; onChange?()
        var retry = true
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            if self.generation == stamp, self.connection != .ready { ws.cancel(with: .goingAway, reason: nil) }
        }
        defer { deadline.cancel() }
        do {
            while !Task.isCancelled, generation == stamp {
                let raw = try await ws.receive()
                guard generation == stamp, !Task.isCancelled else { return false }
                let data: Data
                switch raw {
                case .data(let bytes): data = bytes
                case .string(let text): data = Data(text.utf8)
                @unknown default: continue
                }
                let message = try JSONDecoder().decode(HAData.self, from: data)
                switch message["type"]?.string {
                case "auth_required": try await send(["type": .string("auth"), "access_token": .string(accessToken)], to: ws)
                case "auth_invalid":
                    retry = false
                    throw HAFailure.message("HA 令牌无效或已撤销，请重新填写")
                case "auth_ok":
                    authenticated = true
                    bootstrap = Task { [weak self] in await self?.loadInitialState(stamp: stamp) }
                case "result", "pong":
                    guard let number = message["id"]?.number, let item = pending.removeValue(forKey: Int(number)) else { continue }
                    item.timeout.cancel()
                    if message["success"]?.bool == true || message["type"]?.string == "pong" {
                        item.continuation.resume(returning: message["result"] ?? .null)
                    } else {
                        let code = message["error"]?.object?["code"]?.string ?? "unknown"
                        let text = code == "unauthorized" ? "HA 用户无权执行此操作" : "HA 拒绝了操作（\(code)）"
                        item.continuation.resume(throwing: HAFailure.message(text))
                    }
                case "event":
                    guard let event = message["event"]?.object, event["event_type"]?.string == "state_changed",
                          let body = event["data"]?.object, let id = body["entity_id"]?.string else { continue }
                    let state = body["new_state"] ?? .null
                    if connection != .ready { changes[id] = state }
                    else { apply(id: id, value: state); onChange?() }
                default: break
                }
            }
        } catch {
            guard generation == stamp else { return false }
            connection = .offline(retry ? "HA 连接中断，将自动重试" : error.localizedDescription)
        }
        if generation == stamp { clearSession(); onChange?() }
        return retry && !Task.isCancelled
    }
    private func loadInitialState(stamp: UUID) async {
        do {
            _ = try await request(["type": .string("subscribe_events"), "event_type": .string("state_changed")])
            let states = try await request(["type": .string("get_states")])
            let supported = try await request(["type": .string("get_services")])
            guard generation == stamp, !Task.isCancelled else { return }
            entities = (states.array ?? []).compactMap(HAEntity.init)
            services = supported.object ?? [:]
            for (id, value) in changes { apply(id: id, value: value) }
            changes = [:]; sortEntities()
            connection = .ready
            haLog.notice("Connected to HA; loaded \(self.entities.count) entities")
            let climateHumidity = entities.filter { $0.domain == "climate" }.compactMap { $0.attributes["current_humidity"]?.number }
            let humiditySensors = entities.filter { $0.domain == "sensor" && $0.attributes["device_class"]?.string == "humidity" }
            haLog.notice("Humidity: climate readings=\(climateHumidity.description, privacy: .public); sensors=\(humiditySensors.count), available=\(humiditySensors.filter(\.available).count)")
            onChange?()
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    guard let self, self.generation == stamp else { return }
                    do { _ = try await self.request(["type": .string("ping")]) }
                    catch { if self.generation == stamp { self.socket?.cancel(with: .goingAway, reason: nil) }; return }
                }
            }
        } catch {
            guard generation == stamp else { return }
            errorMessage = error.localizedDescription
            socket?.cancel(with: .goingAway, reason: nil)
        }
    }
    private func apply(id: String, value: HAValue) {
        entities.removeAll { $0.id == id }
        if let entity = HAEntity(value) { entities.append(entity) }
        sortEntities()
    }
    private func sortEntities() { entities.sort { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private func send(_ message: HAData, to ws: URLSessionWebSocketTask) async throws {
        let bytes = try JSONEncoder().encode(message)
        try await ws.send(.string(String(decoding: bytes, as: UTF8.self)))
    }
    private func request(_ body: HAData) async throws -> HAValue {
        guard authenticated, let ws = socket, !Task.isCancelled else { throw HAFailure.disconnected }
        sequence += 1
        let id = sequence; let stamp = generation
        var message = body; message["id"] = .number(Double(id))
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self, requestTimeout] in
                do { try await Task.sleep(for: requestTimeout) } catch { return }
                if let item = self?.pending.removeValue(forKey: id) { item.continuation.resume(throwing: HAFailure.timeout) }
            }
            pending[id] = Pending(continuation: continuation, timeout: timeout)
            Task { [weak self] in
                guard let self, self.generation == stamp else { return }
                do { try await self.send(message, to: ws) }
                catch {
                    if let item = self.pending.removeValue(forKey: id) { item.timeout.cancel(); item.continuation.resume(throwing: error) }
                }
            }
        }
    }
    func command(for binding: HABinding) -> HACommand? {
        guard connection == .ready, let entity = entity(for: binding), entity.available, binding.action.accepts(entity.domain) else { return nil }
        return HACommand.make(action: binding.action, entity: entity, services: services)
    }
    func perform(slot: Int, holdConfirmed: Bool = false) {
        guard busySlot == nil, bindings.indices.contains(slot), let command = command(for: bindings[slot]) else { return }
        if bindings[slot].action == .safePower, command.service == "turn_off", !holdConfirmed { return }
        busySlot = slot; lastActionSlot = slot; successSlot = nil; errorMessage = nil; onChange?()
        let stamp = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.request(command.message)
                guard self.generation == stamp else { return }
                self.successSlot = slot
            } catch {
                guard self.generation == stamp else { return }
                self.errorMessage = error.localizedDescription
            }
            guard self.generation == stamp else { return }
            self.busySlot = nil; self.onChange?()
        }
    }
}
