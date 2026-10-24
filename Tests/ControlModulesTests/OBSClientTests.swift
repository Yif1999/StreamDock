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
        #expect(module.face(forSlot: 6).caption == "打开 OBS")
        #expect(module.face(forSlot: 7).title == "OBS")
        #expect(module.face(forSlot: 8).caption == "重连")
    }

    @Test func authenticatedConnectionActionsErrorsAndReconnect() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("OBSFixture.py").path]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            line.append(byte)
        }
        let port = try #require(Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
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
        module.keyDown(slot: 0)
        try await wait { client.recording == true && !client.busy }
        #expect((lights.leading as? OBSStatusLight)?.state.recording == true)
        module.keyDown(slot: 0)
        try await wait { client.recording == false && !client.busy }
        #expect(lights.leading == nil)
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

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(condition())
        if !condition() { throw OBSClient.Failure.timeout }
    }
}
