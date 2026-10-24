import AppKit
import Foundation
import Observation
import os

private let obsLog = Logger(subsystem: "StreamDock", category: "OBS")

@MainActor
@Observable
public final class OBSClient {
    public static let shared = OBSClient()
    public enum Connection: Equatable {
        case offline(String), connecting, ready
        public var description: String {
            switch self {
            case .offline(let message): message
            case .connecting: "正在连接 OBS…"
            case .ready: "已连接本机 OBS"
            }
        }
    }
    public struct SceneItem: Identifiable, Equatable {
        public let scene: String
        public let itemID: Int
        public let name: String
        public let enabled: Bool
        public var id: String { "\(scene)\u{1f}\(itemID)" }
    }
    public private(set) var connection: Connection = .offline("尚未连接 OBS")
    /// Everything read from OBS; see `OBSState` for how it is kept current.
    private(set) var state = OBSState()
    public var scenes: [String] { state.scenes }
    public var audioInputs: [String] { state.audioInputs }
    public var sceneItems: [SceneItem] { state.sceneItems }
    public var hotkeys: [String] { state.hotkeys }
    public var programScene: String { state.programScene }
    public var previewScene: String { state.previewScene }
    public var inputMute: [String: Bool] { state.inputMute }
    public var recording: Bool? { state.recording }
    public var recordPaused: Bool? { state.recordPaused }
    public var streaming: Bool? { state.streaming }
    public var studio: Bool? { state.studio }
    public var replayActive: Bool? { state.replayActive }
    public var virtualCamera: Bool? { state.virtualCamera }
    public private(set) var busy = false
    public private(set) var actionError: String?
    public private(set) var lastActionSlot: Int?
    public private(set) var lastSuccessSlot: Int?
    public private(set) var bindings: [OBSBinding]

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onOutputsChange: ((OBSOutputState) -> Void)?
    @ObservationIgnored private var publishedOutputs: OBSOutputState?
    var outputState: OBSOutputState {
        OBSOutputState(recording: recording == true, paused: recordPaused == true, streaming: streaming == true)
    }
    private func publishOutputs() {
        let state = outputState
        guard publishedOutputs != state else { return }
        publishedOutputs = state
        obsLog.notice("Output lights recording=\(state.recording) paused=\(state.paused) streaming=\(state.streaming)")
        onOutputsChange?(state)
    }
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var pending: [String: Pending] = [:]
    /// Parts of `state` waiting to be (re)loaded.
    @ObservationIgnored private var pendingParts: Set<OBSState.Part> = []
    /// A part with no news (event or read) for this long is read back, in case an event was missed.
    static let verifyAfter: Duration = .seconds(10)
    @ObservationIgnored private var verification = OBSVerification(quiet: verifyAfter)
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let configurationProvider: () throws -> OBSLocalConfiguration
    private struct Pending {
        let continuation: CheckedContinuation<OBSData, any Error>
        let timeout: Task<Void, Never>
    }
    enum Failure: Error, LocalizedError {
        case unavailable, timeout, response(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "OBS 连接已断开"
            case .timeout: "OBS 响应超时"
            case .response(let text): text
            }
        }
    }

    init(defaults: UserDefaults = .standard, configuration: @escaping () throws -> OBSLocalConfiguration = OBSLocalConfiguration.read) {
        self.defaults = defaults
        self.configurationProvider = configuration
        let saved = defaults.data(forKey: "obsBindings").flatMap { try? JSONDecoder().decode([OBSBinding].self, from: $0) }
        bindings = saved?.count == 15 ? saved! : OBSBinding.defaults
    }

    public func setBinding(_ binding: OBSBinding, at slot: Int) {
        guard bindings.indices.contains(slot) else { return }
        bindings[slot] = binding
        defaults.set(try? JSONEncoder().encode(bindings), forKey: "obsBindings")
        actionError = nil
        lastSuccessSlot = nil
        if binding.action == .sourceVisibility { pendingParts.insert(.sceneItems) }
        onChange?()
    }

    public func openOBS() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/OBS.app"),
                                          configuration: NSWorkspace.OpenConfiguration())
    }

    public func start() {
        guard sessionTask == nil else { return }
        sessionTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runSession()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    public func reconnect() {
        disconnect()
        start()
    }

    func disconnect() {
        sessionTask?.cancel()
        sessionTask = nil
        tearDown()
        connection = .offline("OBS 已断开")
        onChange?()
    }

    private func runSession() async {
        let configuration: OBSLocalConfiguration
        do { configuration = try configurationProvider() }
        catch { connection = .offline("请在 OBS 中设置 WebSocket 服务"); onChange?(); return }
        guard configuration.server_enabled else {
            connection = .offline("请在 OBS 中启用 WebSocket 服务"); onChange?(); return
        }
        guard (1...65535).contains(configuration.server_port) else {
            connection = .offline("OBS 端口无效"); onChange?(); return
        }
        connection = .connecting
        onChange?()
        let token = UUID()
        sessionID = token
        let websocket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(configuration.server_port)")!)
        socket = websocket
        websocket.resume()
        let handshakeTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            if let self, self.sessionID == token, self.connection != .ready {
                websocket.cancel(with: .goingAway, reason: nil)
            }
        }
        defer { handshakeTimeout.cancel() }
        do {
            while !Task.isCancelled, sessionID == token {
                let incoming = try await websocket.receive()
                guard sessionID == token, !Task.isCancelled else { return }
                let data: Data
                switch incoming {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                let message = try JSONDecoder().decode(OBSMessage.self, from: data)
                switch message.op {
                case 0:
                    var identify: OBSData = ["rpcVersion": .number(1), "eventSubscriptions": .number(2047)]
                    if let auth = message.d["authentication"]?.object {
                        guard let salt = auth["salt"]?.string, let challenge = auth["challenge"]?.string,
                              let password = configuration.server_password else { throw Failure.response("OBS 认证配置不完整") }
                        identify["authentication"] = .string(OBSProtocol.authentication(password: password, salt: salt, challenge: challenge))
                    }
                    try await send(OBSMessage(op: 1, d: identify), through: websocket)
                case 2:
                    handshakeTimeout.cancel()
                    connection = .ready
                    obsLog.notice("Connected and authenticated to local OBS")
                    onChange?()
                    startSync(token: token)
                case 5:
                    guard let type = message.d["eventType"]?.string else { continue }
                    let before = state
                    pendingParts.formUnion(state.apply(event: type, data: message.d["eventData"]?.object ?? [:]))
                    verification.heard(OBSState.Part.allCases.filter { state.revision($0) != before.revision($0) }, at: .now)
                    if state != before {
                        publishOutputs()
                        onChange?()
                    }
                case 7:
                    guard let id = message.d["requestId"]?.string, let waiting = pending.removeValue(forKey: id) else { continue }
                    waiting.timeout.cancel()
                    if message.d["requestStatus"]?.object?["result"]?.bool == true {
                        waiting.continuation.resume(returning: message.d["responseData"]?.object ?? [:])
                    } else {
                        let detail = message.d["requestStatus"]?.object?["comment"]?.string ?? "OBS 拒绝了操作"
                        waiting.continuation.resume(throwing: Failure.response(detail))
                    }
                default: break
                }
            }
        } catch {
            guard sessionID == token else { return }
            connection = .offline(websocket.closeCode.rawValue == 4009 ? "OBS 认证失败，请检查配置" : "OBS 未连接，将自动重试")
        }
        if sessionID == token { tearDown(); onChange?() }
    }

    private func tearDown() {
        sessionID = UUID()
        syncTask?.cancel()
        syncTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        let waiting = pending.values
        pending.removeAll()
        for item in waiting { item.timeout.cancel(); item.continuation.resume(throwing: Failure.unavailable) }
        pendingParts = []
        state = OBSState()
        actionError = nil; lastSuccessSlot = nil
        publishOutputs()
    }

    private func send(_ message: OBSMessage, through websocket: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder().encode(message)
        try await websocket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func request(_ type: String, _ data: OBSData = [:]) async throws -> OBSData {
        guard connection == .ready, let websocket = socket, !Task.isCancelled else { throw Failure.unavailable }
        let id = UUID().uuidString
        let token = sessionID
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if let waiting = self?.pending.removeValue(forKey: id) { waiting.continuation.resume(throwing: Failure.timeout) }
            }
            pending[id] = Pending(continuation: continuation, timeout: timeout)
            Task { [weak self] in
                guard let self, self.sessionID == token else { return }
                do { try await self.send(OBSMessage(op: 6, d: ["requestType": .string(type), "requestId": .string(id), "requestData": .object(data)]), through: websocket) }
                catch {
                    if let waiting = self.pending.removeValue(forKey: id) {
                        waiting.timeout.cancel(); waiting.continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Loads every part once, then whatever events ask for, plus any part that has been quiet
    /// for `verifyAfter` (see `OBSVerification`).
    private func startSync(token: UUID) {
        pendingParts = Set(OBSState.Part.allCases)
        verification = OBSVerification(quiet: Self.verifyAfter)
        syncTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.sessionID == token {
                self.pendingParts.formUnion(self.verification.due(at: .now))
                if !self.pendingParts.isEmpty { await self.load(token: token) }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    private func load(token: UUID) async {
        let parts = pendingParts.sorted()
        pendingParts = []
        for part in parts {
            let revision = state.revision(part)
            defer { if sessionID == token { verification.heard([part], at: .now) } }
            do {
                var loaded = state
                try await read(part, into: &loaded)
                guard sessionID == token else { return }
                // An event touched this part while the request was out: the answer may be
                // older than the event, so ask again instead of overwriting it.
                guard state.revision(part) == revision else { pendingParts.insert(part); continue }
                let before = state
                state.adopt(part, from: loaded)
                if state != before { publishOutputs(); onChange?() }
            } catch {
                guard sessionID == token else { return }
                obsLog.notice("Reading \(String(describing: part), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Reads one part from OBS into `target` (a copy of `state`; only that part is adopted).
    private func read(_ part: OBSState.Part, into target: inout OBSState) async throws {
        switch part {
        case .scenes:
            let data = try await request("GetSceneList")
            target.scenes = (data["scenes"]?.array ?? []).compactMap { $0.object?["sceneName"]?.string }
            target.programScene = data["currentProgramSceneName"]?.string ?? ""
            target.previewScene = data["currentPreviewSceneName"]?.string ?? ""
        case .outputs:
            let record = try await request("GetRecordStatus")
            target.recording = record["outputActive"]?.bool; target.recordPaused = record["outputPaused"]?.bool
            target.recordTime = record["outputTimecode"]?.string ?? ""
            let stream = try await request("GetStreamStatus")
            target.streaming = stream["outputActive"]?.bool; target.streamTime = stream["outputTimecode"]?.string ?? ""
            target.studio = try await request("GetStudioModeEnabled")["studioModeEnabled"]?.bool
            // Unavailable when the replay buffer or virtual camera is not set up.
            target.replayActive = (try? await request("GetReplayBufferStatus"))?["outputActive"]?.bool
            target.virtualCamera = (try? await request("GetVirtualCamStatus"))?["outputActive"]?.bool
        case .inputs:
            let inputs = try await request("GetInputList")
            var muted: [String: Bool] = [:]
            var audio: [String] = []
            // Only inputs with audio answer GetInputMute.
            for name in (inputs["inputs"]?.array ?? []).compactMap({ $0.object?["inputName"]?.string }) {
                if let value = (try? await request("GetInputMute", ["inputName": .string(name)]))?["inputMuted"]?.bool {
                    muted[name] = value; audio.append(name)
                }
            }
            target.inputMute = muted; target.audioInputs = audio
        case .sceneItems:
            var items: [SceneItem] = []
            let wanted = Set([state.programScene] + bindings.filter { $0.action == .sourceVisibility }.map(\.scene)).filter { !$0.isEmpty }
            for scene in wanted.sorted() {
                guard let response = try? await request("GetSceneItemList", ["sceneName": .string(scene)]) else { continue }
                items += (response["sceneItems"]?.array ?? []).compactMap { value in
                    guard let item = value.object, let name = item["sourceName"]?.string,
                          let id = item["sceneItemId"]?.number, let enabled = item["sceneItemEnabled"]?.bool else { return nil }
                    return SceneItem(scene: scene, itemID: Int(id), name: name, enabled: enabled)
                }
            }
            target.sceneItems = items
        case .hotkeys:
            target.hotkeys = (try await request("GetHotkeyList")["hotkeys"]?.array ?? []).compactMap(\.string)
        }
    }

    func sceneName(for binding: OBSBinding) -> String? {
        if !binding.target.isEmpty { return scenes.contains(binding.target) ? binding.target : nil }
        return scenes.indices.contains(binding.automaticIndex) ? scenes[binding.automaticIndex] : nil
    }
    func inputName(for binding: OBSBinding) -> String? {
        if !binding.target.isEmpty { return audioInputs.contains(binding.target) ? binding.target : nil }
        return audioInputs.indices.contains(binding.automaticIndex) ? audioInputs[binding.automaticIndex] : nil
    }
    func item(for binding: OBSBinding) -> SceneItem? {
        let scene = binding.scene.isEmpty ? programScene : binding.scene
        let items = sceneItems.filter { $0.scene == scene }
        if let id = binding.itemID { return items.first { $0.itemID == id && (binding.target.isEmpty || $0.name == binding.target) } }
        return items.indices.contains(binding.automaticIndex) ? items[binding.automaticIndex] : nil
    }

    func command(for binding: OBSBinding) -> OBSCommand? {
        guard connection == .ready else { return nil }
        switch binding.action {
        case .none: return nil
        case .record: return recording == nil ? nil : OBSCommand(type: "ToggleRecord")
        case .pauseRecord: return recording == true ? OBSCommand(type: "ToggleRecordPause") : nil
        case .stream: return streaming == nil ? nil : OBSCommand(type: "ToggleStream")
        case .studio: return studio.map { OBSCommand(type: "SetStudioModeEnabled", data: ["studioModeEnabled": .bool(!$0)]) }
        case .transition: return studio == true ? OBSCommand(type: "TriggerStudioModeTransition") : nil
        case .replayBuffer: return replayActive == nil ? nil : OBSCommand(type: "ToggleReplayBuffer")
        case .saveReplay: return replayActive == true ? OBSCommand(type: "SaveReplayBuffer") : nil
        case .virtualCamera: return virtualCamera == nil ? nil : OBSCommand(type: "ToggleVirtualCam")
        case .scene:
            guard let name = sceneName(for: binding), let studio else { return nil }
            return OBSCommand(type: studio ? "SetCurrentPreviewScene" : "SetCurrentProgramScene", data: ["sceneName": .string(name)])
        case .inputMute:
            guard let name = inputName(for: binding) else { return nil }
            return OBSCommand(type: "ToggleInputMute", data: ["inputName": .string(name)])
        case .sourceVisibility:
            guard let item = item(for: binding) else { return nil }
            return OBSCommand(type: "SetSceneItemEnabled", data: ["sceneName": .string(item.scene), "sceneItemId": .number(Double(item.itemID)), "sceneItemEnabled": .bool(!item.enabled)])
        case .hotkey:
            guard hotkeys.contains(binding.target) else { return nil }
            return OBSCommand(type: "TriggerHotkeyByName", data: ["hotkeyName": .string(binding.target)])
        }
    }

    func perform(slot: Int) {
        guard bindings.indices.contains(slot) else { return }
        guard !busy else {
            obsLog.notice("Ignored key \(slot + 1): previous action still pending")
            return
        }
        guard let command = command(for: bindings[slot]) else {
            obsLog.notice("Ignored key \(slot + 1): action \(self.bindings[slot].action.rawValue, privacy: .public) unavailable, connection=\(self.connection.description, privacy: .public)")
            return
        }
        obsLog.notice("Key \(slot + 1) sending \(command.type, privacy: .public)")
        busy = true; lastActionSlot = slot; actionError = nil; lastSuccessSlot = nil
        onChange?()
        let token = sessionID
        Task {
            defer { busy = false; onChange?() }
            guard sessionID == token else { return }
            do {
                _ = try await request(command.type, command.data)
                guard sessionID == token else { return }
                obsLog.notice("Key \(slot + 1) succeeded: \(command.type, privacy: .public)")
                // The new state arrives as OBS's own event.
                lastSuccessSlot = slot
            } catch {
                if sessionID == token {
                    actionError = error.localizedDescription
                    obsLog.error("Key \(slot + 1) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
