import Foundation
import Testing
@testable import ControlModules
@testable import DockCore

@MainActor
struct OBSClientTests {
    @Test func protocolAuthenticationMatchesIndependentSHA256Vector() {
        #expect(OBSProtocol.authentication(password: "supersecretpassword", salt: "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=", challenge: "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY=") == "1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=")
    }

    @Test func bindingsPersistWithoutCredentials() throws {
        let suite = "StreamDock.Tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = OBSClient(defaults: defaults)
        var binding = OBSBinding(action: .scene); binding.target = "Desktop"
        client.setBinding(binding, at: 8)
        let restored = OBSClient(defaults: defaults)
        #expect(restored.bindings[8] == binding)
        #expect(restored.bindings.count == 15)
        #expect(defaults.dictionaryRepresentation()["server_password"] == nil)
    }

    @Test func disconnectedControlsAreCenteredInMiddleRow() throws {
        let suite = "StreamDock.Tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let module = OBSModule(client: OBSClient(defaults: defaults))
        let occupied = (0..<15).filter { module.face(forSlot: $0) != .blank }
        #expect(occupied == [6, 7, 8])
        #expect(module.face(forSlot: 6).caption == "Open OBS")
        #expect(module.face(forSlot: 7).title == "OBS")
        #expect(module.face(forSlot: 8).caption == "Retry")
    }

    @Test func authenticatedConnectionActionsErrorsAndReconnect() async throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        let port = fixture.port
        let suite = "StreamDock.Tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = OBSClient(defaults: defaults, configuration: {
            OBSLocalConfiguration(server_enabled: true, server_port: port, auth_required: true, server_password: "fixture-password")
        })
        let lights = LightActivityCenter()
        let monitor = OBSLightMonitor(center: lights, client: client)
        defer { monitor.stop() }
        monitor.start()
        try await wait { client.audioInputs.count == 2 && client.sceneItems.count == 2 && !client.hotkeys.isEmpty }
        #expect(client.connection == .ready)
        #expect(client.recording == false)
        #expect(lights.leading == nil)
        #expect(client.command(for: .init(action: .pauseRecord)) == nil)
        #expect(client.command(for: .init(action: .saveReplay)) == nil)
        let module = OBSModule(client: client)
        try await Task.sleep(for: .milliseconds(300))
        let before = fixture.requests.count
        module.keyDown(slot: 0)
        try await wait { client.recording == true && !client.busy }
        #expect((lights.leading as? OBSStatusLight)?.state.recording == true)
        // The new state came from the event alone: nothing was read back from OBS.
        try await Task.sleep(for: .milliseconds(300))
        #expect(Array(fixture.requests.dropFirst(before)) == ["ToggleRecord"])
        module.keyDown(slot: 0)
        try await wait { client.recording == false && !client.busy }
        #expect(lights.leading == nil)
        // Recording → paused goes straight to paused, never through "stopped".
        module.keyDown(slot: 0)
        try await wait { client.recording == true && !client.busy }
        var seen: [OBSOutputState] = []
        for paused in [true, false] {
            client.perform(slot: 1)
            let deadline = ContinuousClock.now + .seconds(5)
            while !(client.recordPaused == paused && !client.busy), ContinuousClock.now < deadline {
                seen.append(client.outputState)
                try await Task.sleep(for: .milliseconds(5))
            }
            seen.append(client.outputState)
        }
        #expect(client.recording == true && client.recordPaused == false)
        let stopped = seen.filter { !$0.recording }
        #expect(stopped.isEmpty, "states seen: \(stopped)")
        client.perform(slot: 1)
        try await wait { client.recordPaused == true && !client.busy }
        module.keyDown(slot: 0)
        try await wait { client.recording == false && client.recordPaused == false && !client.busy }
        client.perform(slot: 10)
        try await wait { client.inputMute["Mic"] == true && !client.busy }
        client.perform(slot: 12)
        try await wait { client.sceneItems.first?.enabled == false && !client.busy }
        client.perform(slot: 3)
        try await wait { client.studio == true && !client.busy }
        let sceneCommand = try #require(client.command(for: OBSBinding(action: .scene, automaticIndex: 1)))
        #expect(sceneCommand.type == "SetCurrentPreviewScene")
        client.perform(slot: 6)
        try await wait { !client.busy }
        #expect(client.programScene == "Camera")
        client.perform(slot: 4)
        try await wait { client.programScene == "Desktop" && !client.busy }
        var missing = OBSBinding(action: .scene); missing.target = "Deleted scene"
        #expect(client.command(for: missing) == nil)
        var hotkey = OBSBinding(action: .hotkey); hotkey.target = "fixture-hotkey"
        client.setBinding(hotkey, at: 14); client.perform(slot: 14)
        try await wait { client.actionError != nil && !client.busy }
        client.reconnect()
        #expect(client.recording == nil && client.scenes.isEmpty)
        try await wait { client.audioInputs.count == 2 && client.recording == false }
        client.perform(slot: 0)
        try await wait { client.recording == true && !client.busy }
        #expect(lights.leading != nil)
        client.disconnect()
        #expect(client.command(for: .init(action: .record)) == nil)
        #expect(client.inputMute.isEmpty)
        #expect(lights.leading == nil)
    }

    /// A response that left OBS before an event, but arrives after it, must not undo the event.
    @Test func staleResponseNeverOverwritesANewerEvent() async throws {
        let fixture = try Fixture(arguments: ["--stale-record"])
        defer { fixture.stop() }
        let suite = "StreamDock.Tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let port = fixture.port
        let client = OBSClient(defaults: defaults, configuration: {
            OBSLocalConfiguration(server_enabled: true, server_port: port, auth_required: true, server_password: "fixture-password")
        })
        client.start()
        defer { client.disconnect() }
        try await wait { client.audioInputs.count == 2 && client.recording != nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(client.recording == true)
        // The stale answer was dropped and the status read again.
        #expect(fixture.requests.filter { $0 == "GetRecordStatus" }.count == 2)
    }

    @Test func eventsCarryingValuesNeedNoReload() {
        var state = OBSState()
        state.inputMute = ["Mic": false]
        state.sceneItems = [.init(scene: "Camera", itemID: 7, name: "Camera Source", enabled: true)]
        let recordRevision = state.revision(.outputs)
        #expect(state.apply(event: "RecordStateChanged", data: ["outputActive": .bool(true), "outputState": .string("OBS_WEBSOCKET_OUTPUT_STARTED")]).isEmpty)
        #expect(state.recording == true && state.recordPaused == false)
        #expect(state.revision(.outputs) == recordRevision + 1)
        // As OBS sends it: outputActive is false while paused, but the recording goes on.
        #expect(state.apply(event: "RecordStateChanged", data: ["outputActive": .bool(false), "outputState": .string("OBS_WEBSOCKET_OUTPUT_PAUSED")]).isEmpty)
        #expect(state.recording == true && state.recordPaused == true)
        #expect(state.apply(event: "RecordStateChanged", data: ["outputActive": .bool(true), "outputState": .string("OBS_WEBSOCKET_OUTPUT_RESUMED")]).isEmpty)
        #expect(state.recording == true && state.recordPaused == false)
        _ = state.apply(event: "RecordStateChanged", data: ["outputActive": .bool(false), "outputState": .string("OBS_WEBSOCKET_OUTPUT_PAUSED")])
        // Stopping is a transition; only STOPPED ends the recording (and the pause).
        _ = state.apply(event: "RecordStateChanged", data: ["outputActive": .bool(false), "outputState": .string("OBS_WEBSOCKET_OUTPUT_STOPPING")])
        #expect(state.recording == true && state.recordPaused == true)
        _ = state.apply(event: "RecordStateChanged", data: ["outputActive": .bool(false), "outputState": .string("OBS_WEBSOCKET_OUTPUT_STOPPED")])
        #expect(state.recording == false && state.recordPaused == false)
        // A reconnecting stream is still a stream.
        _ = state.apply(event: "StreamStateChanged", data: ["outputActive": .bool(true), "outputState": .string("OBS_WEBSOCKET_OUTPUT_STARTED")])
        _ = state.apply(event: "StreamStateChanged", data: ["outputActive": .bool(false), "outputState": .string("OBS_WEBSOCKET_OUTPUT_RECONNECTING")])
        #expect(state.streaming == true)
        #expect(state.apply(event: "RecordStateChanged", data: ["outputState": .string("SOMETHING_NEW")]) == [.outputs])
        #expect(state.apply(event: "InputMuteStateChanged", data: ["inputName": .string("Mic"), "inputMuted": .bool(true)]).isEmpty)
        #expect(state.inputMute["Mic"] == true)
        #expect(state.apply(event: "SceneItemEnableStateChanged", data: ["sceneName": .string("Camera"), "sceneItemId": .number(7), "sceneItemEnabled": .bool(false)]).isEmpty)
        #expect(state.sceneItems.first?.enabled == false)
        #expect(state.apply(event: "CurrentProgramSceneChanged", data: ["sceneName": .string("Desktop")]) == [.sceneItems])
        #expect(state.programScene == "Desktop")
        #expect(state.apply(event: "StudioModeStateChanged", data: ["studioModeEnabled": .bool(false)]).isEmpty)
        #expect(state.studio == false && state.previewScene.isEmpty)
    }

    /// Read-back only for parts without recent news: a read right after an event can only bring
    /// back the state from before it (seen with a busy OBS: "still recording" after the stop).
    @Test func onlyQuietPartsAreReadBack() {
        let start = ContinuousClock.now
        var verification = OBSVerification(quiet: .seconds(10))
        #expect(verification.due(at: start) == Set(OBSState.Part.allCases))
        verification.heard(OBSState.Part.allCases, at: start)
        #expect(verification.due(at: start + .seconds(9)).isEmpty)
        // An event about the outputs at 5 s keeps them from being read back until 15 s.
        verification.heard([.outputs], at: start + .seconds(5))
        #expect(verification.due(at: start + .seconds(10)) == Set(OBSState.Part.allCases).subtracting([.outputs]))
        verification.heard(Set(OBSState.Part.allCases).subtracting([.outputs]), at: start + .seconds(10))
        #expect(verification.due(at: start + .seconds(14.9)).isEmpty)
        #expect(verification.due(at: start + .seconds(15)) == [.outputs])
    }

    @Test func eventsAboutListsReloadOnlyThatPart() {
        var state = OBSState()
        #expect(state.apply(event: "InputMuteStateChanged", data: ["inputName": .string("New Mic"), "inputMuted": .bool(true)]) == [.inputs])
        #expect(state.apply(event: "SceneCreated", data: ["sceneName": .string("New")]) == [.scenes, .sceneItems])
        #expect(state.apply(event: "InputCreated", data: [:]) == [.inputs, .sceneItems])
        #expect(state.apply(event: "StudioModeStateChanged", data: ["studioModeEnabled": .bool(true)]) == [.scenes])
        #expect(state.apply(event: "CurrentSceneCollectionChanged", data: [:]) == Set(OBSState.Part.allCases))
        #expect(state.apply(event: "MediaInputPlaybackStarted", data: [:]).isEmpty)
    }

    /// The local obs-websocket stand-in (OBSFixture.py) and the request types it has received.
    private final class Fixture: @unchecked Sendable {
        let process = Process()
        let port: Int
        private let lock = NSLock()
        private var received: [String] = []
        private var buffer = Data()
        var requests: [String] { lock.withLock { received } }

        init(arguments: [String] = []) throws {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("OBSFixture.py").path] + arguments
            let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            var line = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte == Data([10]) { break }
                line.append(byte)
            }
            guard let port = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
                process.terminate(); throw OBSClient.Failure.unavailable
            }
            self.port = port
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.collect(handle.availableData) }
        }

        private func collect(_ data: Data) {
            lock.withLock {
                buffer.append(data)
                while let end = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...end)
                    if line.hasPrefix("REQ ") { received.append(String(line.dropFirst(4))) }
                }
            }
        }

        func stop() { process.terminate() }
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(condition())
        if !condition() { throw OBSClient.Failure.timeout }
    }
}
