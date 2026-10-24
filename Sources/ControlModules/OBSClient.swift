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
    public private(set) var scenes: [String] = []
    public private(set) var audioInputs: [String] = []
    public private(set) var sceneItems: [SceneItem] = []
    public private(set) var hotkeys: [String] = []
    public private(set) var programScene = ""
    public private(set) var previewScene = ""
    public private(set) var inputMute: [String: Bool] = [:]
    public private(set) var recording: Bool?
    public private(set) var recordPaused: Bool?
    public private(set) var streaming: Bool?
    public private(set) var studio: Bool?
    public private(set) var replayActive: Bool?
    public private(set) var virtualCamera: Bool?
    public private(set) var recordTime = ""
    public private(set) var streamTime = ""
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
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var pending: [String: Pending] = [:]
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var dirty = true
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
        dirty = true
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
                    dirty = true
                    onChange?()
                    refreshTask = Task { [weak self] in
                        var tick = 0
                        while let self, !Task.isCancelled, self.sessionID == token {
                            if self.dirty || tick % 4 == 0 { await self.refresh(token: token) }
                            tick += 1
                            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                        }
                    }
                case 5: dirty = true
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
        refreshTask?.cancel()
        refreshTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        let waiting = pending.values
        pending.removeAll()
        for item in waiting { item.timeout.cancel(); item.continuation.resume(throwing: Failure.unavailable) }
        refreshing = false
        recording = nil; recordPaused = nil; streaming = nil; studio = nil; replayActive = nil; virtualCamera = nil
        inputMute = [:]; sceneItems = []; scenes = []; audioInputs = []; hotkeys = []
        programScene = ""; previewScene = ""; recordTime = ""; streamTime = ""
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

    private func refresh(token: UUID) async {
        guard !refreshing, connection == .ready else { return }
        refreshing = true
        dirty = false
        defer { if sessionID == token { refreshing = false; onChange?() } }
        do {
            let sceneData = try await request("GetSceneList")
            guard sessionID == token else { return }
            scenes = (sceneData["scenes"]?.array ?? []).compactMap { $0.object?["sceneName"]?.string }
            programScene = sceneData["currentProgramSceneName"]?.string ?? ""
            previewScene = sceneData["currentPreviewSceneName"]?.string ?? ""
            let record = try await request("GetRecordStatus")
            guard sessionID == token else { return }
            recording = record["outputActive"]?.bool; recordPaused = record["outputPaused"]?.bool
            recordTime = record["outputTimecode"]?.string ?? ""
            let stream = try await request("GetStreamStatus")
            guard sessionID == token else { return }
            streaming = stream["outputActive"]?.bool; streamTime = stream["outputTimecode"]?.string ?? ""
            publishOutputs()
            let mode = try await request("GetStudioModeEnabled")
            guard sessionID == token else { return }
            studio = mode["studioModeEnabled"]?.bool
            let replay = try? await request("GetReplayBufferStatus")
            guard sessionID == token else { return }
            replayActive = replay?["outputActive"]?.bool
            let camera = try? await request("GetVirtualCamStatus")
            guard sessionID == token else { return }
            virtualCamera = camera?["outputActive"]?.bool
            let inputs = try await request("GetInputList")
            var muted: [String: Bool] = [:]
            var audio: [String] = []
            for name in (inputs["inputs"]?.array ?? []).compactMap({ $0.object?["inputName"]?.string }) {
                if let response = try? await request("GetInputMute", ["inputName": .string(name)]), let value = response["inputMuted"]?.bool {
                    muted[name] = value; audio.append(name)
                }
                guard sessionID == token else { return }
            }
            inputMute = muted; audioInputs = audio
            var items: [SceneItem] = []
            let wantedScenes = Set([programScene] + bindings.filter { $0.action == .sourceVisibility }.map(\.scene)).filter { !$0.isEmpty }
            for scene in wantedScenes {
                guard let response = try? await request("GetSceneItemList", ["sceneName": .string(scene)]) else { continue }
                guard sessionID == token else { return }
                items += (response["sceneItems"]?.array ?? []).compactMap { value in
                    guard let item = value.object, let name = item["sourceName"]?.string,
                          let id = item["sceneItemId"]?.number, let enabled = item["sceneItemEnabled"]?.bool else { return nil }
                    return SceneItem(scene: scene, itemID: Int(id), name: name, enabled: enabled)
                }
            }
            sceneItems = items
            let keys = try? await request("GetHotkeyList")
            guard sessionID == token else { return }
            hotkeys = (keys?["hotkeys"]?.array ?? []).compactMap(\.string)
        } catch {
            if sessionID == token { dirty = true }
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
                lastSuccessSlot = slot
                dirty = true
                await refresh(token: token)
            } catch {
                if sessionID == token {
                    actionError = error.localizedDescription
                    obsLog.error("Key \(slot + 1) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
