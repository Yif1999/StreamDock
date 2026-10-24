import Foundation
import Testing
@testable import ControlModules

private final class MemoryHATokens: HATokenStore {
    var values: [String: String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func save(_ token: String, account: String) throws { values[account] = token }
    func delete(account: String) throws { values.removeValue(forKey: account) }
}

@MainActor struct HAClientTests {
    @Test func endpointsNormalizeAndRejectEmbeddedCredentials() throws {
        #expect(try HAEndpoint("192.168.1.20:8123/").websocket.absoluteString == "ws://192.168.1.20:8123/api/websocket")
        #expect(try HAEndpoint("https://home.example/ha/").websocket.absoluteString == "wss://home.example/ha/api/websocket")
        for value in ["", "ftp://home.local", "http://user:secret@home.local", "http://home.local/?token=secret"] {
            #expect(throws: (any Error).self) { try HAEndpoint(value) }
        }
    }
    @Test func configurationPersistsBindingsButKeepsTokensOutOfDefaults() throws {
        let suite = "StreamDock.HATests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = MemoryHATokens()
        let client = HAClient(defaults: defaults, tokens: tokens)
        defer { client.disconnect() }
        #expect(client.configure(address: "http://127.0.0.1:1", token: "test-secret"))
        client.disconnect()
        let binding = HABinding(action: .toggle, entityID: "light.desk", label: "书桌灯")
        client.setBinding(binding, at: 3)
        let restored = HAClient(defaults: defaults, tokens: tokens)
        #expect(restored.bindings[3] == binding)
        #expect(!defaults.persistentDomain(forName: suite)!.description.contains("test-secret"))
        #expect(!client.configure(address: "http://127.0.0.1:2", token: ""))
        #expect(client.address == "http://127.0.0.1:1")
        client.removeToken()
        #expect(tokens.values.isEmpty)
    }
    @Test func offlineControlsAreHorizontalAndCentered() throws {
        let suite = "StreamDock.HATests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let module = HAModule(client: HAClient(defaults: defaults, tokens: MemoryHATokens()))
        #expect((0..<15).filter { module.face(forSlot: $0) != .blank } == [6, 7, 8])
    }
    @Test func authenticatedSnapshotEventsCommandsReconnectAndInvalidToken() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("HAFixture.py").path]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.standardError
        try process.run()
        defer { process.terminate() }
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }; line.append(byte)
        }
        let port = try #require(Int(String(decoding: line, as: UTF8.self)))
        let suite = "StreamDock.HATests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Short timeout and hold so the test does not wait out the real ones (6 s, 1 s).
        let client = HAClient(defaults: defaults, tokens: MemoryHATokens(), requestTimeout: .milliseconds(500))
        defer { client.disconnect() }
        let address = "http://127.0.0.1:\(port)"
        #expect(client.configure(address: address, token: "fixture-token"))
        try await wait { client.connection == .ready }
        #expect(client.entities.first { $0.id == "input_boolean.race" }?.state == "on")
        #expect(client.entities.first { $0.id == "sensor.temperature" }?.displayState == "22°C")
        #expect(client.command(for: HABinding(action: .toggle, entityID: "light.offline")) == nil)
        #expect(client.command(for: HABinding(action: .status, entityID: "sensor.temperature")) == nil)
        #expect(client.command(for: HABinding(action: .scene, entityID: "scene.work"))?.service == "turn_on")
        #expect(client.command(for: HABinding(action: .stopCover, entityID: "cover.blinds"))?.service == "stop_cover")
        client.setBinding(HABinding(action: .toggle, entityID: "light.desk"), at: 0)
        let module = HAModule(client: client, hold: .milliseconds(150))
        #expect(module.face(forSlot: 0).symbol == "power" && module.face(forSlot: 0).title == nil)
        module.keyDown(slot: 0)
        try await wait { client.busySlot == nil && client.entities.first { $0.id == "light.desk" }?.state == "on" }
        #expect(module.face(forSlot: 0).title == "50%")
        let brighter = HABinding(action: .brighter, entityID: "light.desk")
        #expect(client.command(for: brighter)?.data["brightness_step_pct"] == .number(10))
        client.setBinding(brighter, at: 1)
        #expect(module.face(forSlot: 1).title == nil && module.face(forSlot: 1).symbol == "sun.max.fill")
        client.perform(slot: 1)
        try await wait { client.busySlot == nil && client.entities.first { $0.id == "light.desk" }?.displayState == "60%" }
        client.setBinding(HABinding(action: .script, entityID: "script.fail"), at: 2)
        client.perform(slot: 2)
        try await wait { client.busySlot == nil && client.errorMessage != nil }
        #expect(module.face(forSlot: 2).caption == "Failed" && module.face(forSlot: 2).tone == .normal)
        client.reconnect()
        #expect(client.entities.isEmpty)
        try await wait { client.connection == .ready }
        #expect(client.entities.first { $0.id == "sensor.calls" }?.state == "2") // No replay.
        // Only the local fixture switch: never a user's real outlet.
        client.setBinding(HABinding(action: .safePower, entityID: "switch.plug"), at: 3)
        client.perform(slot: 3) // Direct calls cannot bypass the hold confirmation.
        #expect(client.busySlot == nil)
        module.keyDown(slot: 3); module.keyUp(slot: 3)
        try await Task.sleep(for: .milliseconds(250))
        #expect(client.entities.first { $0.id == "switch.plug" }?.state == "on")
        module.keyDown(slot: 3); module.sceneDidDeactivate()
        try await Task.sleep(for: .milliseconds(250))
        #expect(client.entities.first { $0.id == "switch.plug" }?.state == "on")
        module.keyDown(slot: 3)
        try await wait { client.entities.first { $0.id == "switch.plug" }?.state == "off" && client.busySlot == nil }
        module.keyUp(slot: 3)
        client.setBinding(HABinding(action: .script, entityID: "script.timeout"), at: 3)
        client.perform(slot: 3)
        try await wait { client.busySlot == nil && client.errorMessage?.contains("超时") == true }
        #expect(client.configure(address: address, token: "bad-token"))
        try await wait { client.connection.description.contains("令牌无效") }
        #expect(client.entities.isEmpty)
        #expect(client.command(for: brighter) == nil)
    }
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
        #expect(condition())
        if !condition() { throw HAFailure.timeout }
    }
}
