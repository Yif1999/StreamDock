import DockKit
import Foundation
import Observation
import os

private let log = Logger(subsystem: "StreamDock", category: "DockCore")

/// Owns the device connection and the scenes; routes key presses and draws the active scene.
@MainActor
@Observable
public final class DockController {
    public enum Connection: Equatable {
        case searching
        case connecting
        case connected(serial: String, firmware: String)
        case failed(String)
    }

    public private(set) var connection: Connection = .searching
    /// Exactly one scene per round key, left to right.
    public let scenes: [DockScene]
    public private(set) var activeSceneIndex = 0
    public let settings: DockSettings
    @ObservationIgnored public let alerts = AlertCenter()

    @ObservationIgnored private var device: M18Device?
    @ObservationIgnored private let light = LightEngine()
    @ObservationIgnored private let monitor = DeviceMonitor()
    @ObservationIgnored private var pressedKeys: Set<Int> = []
    @ObservationIgnored private var shownFaces: [Int: ShownFace] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isConnecting = false
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?

    private struct ShownFace: Equatable {
        let face: KeyFace
        let pressed: Bool
    }

    public var activeScene: DockScene { scenes[activeSceneIndex] }

    public init(scenes: [DockScene], settings: DockSettings = DockSettings()) {
        precondition(scenes.count == M18Layout.roundKeyCount, "One scene per round key")
        self.scenes = scenes
        self.settings = settings
        for scene in scenes { scene.host = self }
        light.sendSolid = { [weak self] color in self?.device?.setLEDColor(red: color.red, green: color.green, blue: color.blue) }
        light.sendFrame = { [weak self] frame in self?.device?.setLEDFrame(frame.map { ($0.red, $0.green, $0.blue) }) }
        alerts.onChange = { [weak self] in self?.updateLight(fade: self?.alerts.color == nil ? 0.6 : 0.18) }
    }

    public func start() {
        guard !started else { return }
        started = true
        activeScene.activate()
        updateLight(fade: 0.5)
        monitor.onArrival = { [weak self] path in self?.deviceArrived(path) }
        monitor.onRemoval = { [weak self] path in self?.deviceRemoved(path) }
        monitor.start()
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.reconcile()
            }
        }
    }

    /// Restores the light strip, tells the device we are leaving and releases it.
    public func shutdown() {
        alerts.cancel()
        light.stop()
        reconcileTask?.cancel()
        monitor.stop()
        activeScene.deactivate()
        guard let device else { return }
        light.fadeOutNow()
        device.resetLEDEffect()
        device.close(notifyDevice: true)
        self.device = nil
        connection = .searching
    }

    // MARK: - Scenes and settings

    public func activateScene(at index: Int) {
        guard scenes.indices.contains(index), index != activeSceneIndex else { return }
        releasePressedKeys()
        activeScene.deactivate()
        activeSceneIndex = index
        activeScene.activate()
        updateLight(fade: 0.5)
        redrawAll()
    }

    public func ledColor(for scene: DockScene) -> RGB {
        settings.ledColorOverrides[scene.id] ?? scene.defaultLEDColor
    }

    public func setLEDColor(_ color: RGB?, for scene: DockScene) {
        settings.ledColorOverrides[scene.id] = color
        if scene === activeScene { updateLight(fade: 0.4) }
    }

    public func setScreenBrightness(_ percent: Int) {
        settings.screenBrightness = percent
        device?.setScreenBrightness(percent)
    }

    public func setLEDBrightness(_ percent: Int) {
        settings.ledBrightness = percent
        device?.setLEDBrightness(percent)
    }

    // MARK: - Device lifecycle

    private func deviceArrived(_ path: String) {
        log.notice("Device arrived: \(path, privacy: .public)")
        // A replug can deliver the new arrival before the old removal; drop the stale handle first.
        if let device, device.identity.path != path,
           !M18Device.attached().contains(where: { $0.path == device.identity.path }) {
            deviceRemoved(device.identity.path)
        }
        guard device == nil, !isConnecting else { return }
        isConnecting = true
        connection = .connecting
        Task {
            await connect(path: path)
            isConnecting = false
        }
    }

    /// Hotplug notifications can be lost or reordered (e.g. when the monitor's USB hub
    /// resets on an HDR switch), so periodically compare against what is really attached.
    private func reconcile() {
        guard !isConnecting else { return }
        let attached = M18Device.attached()
        if let device, !attached.contains(where: { $0.path == device.identity.path }) {
            log.notice("Reconcile: \(device.identity.path, privacy: .public) is gone")
            deviceRemoved(device.identity.path)
        }
        if device == nil, let first = attached.first {
            log.notice("Reconcile: found unconnected \(first.path, privacy: .public)")
            deviceArrived(first.path)
        }
    }

    private func connect(path: String, attempt: Int = 1) async {
        // Give the firmware a moment after enumeration before talking to it.
        try? await Task.sleep(for: .milliseconds(attempt == 1 ? 300 : 1000))
        guard device == nil else { return }
        guard let identity = M18Device.attached().first(where: { $0.path == path }) else {
            log.notice("Device \(path, privacy: .public) vanished before opening")
            connection = .searching
            return
        }
        let onInput: @Sendable (DockInputEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        do {
            let opened = try await Task.detached {
                try M18Device(opening: identity, onInput: onInput)
            }.value
            device = opened
            connection = .connected(serial: identity.serialNumber, firmware: opened.firmwareVersion)
            log.notice("Connected \(identity.path, privacy: .public) fw=\(opened.firmwareVersion, privacy: .public)")
            opened.setScreenBrightness(settings.screenBrightness)
            opened.setLEDBrightness(settings.ledBrightness)
            light.fadeInFromBlack()
            shownFaces.removeAll()
            redrawAll()
        } catch {
            log.error("Open failed (attempt \(attempt)): \(String(describing: error), privacy: .public)")
            if attempt < 3 {
                await connect(path: path, attempt: attempt + 1)
            } else {
                connection = .failed(String(describing: error))
            }
        }
    }

    private func deviceRemoved(_ path: String) {
        guard let device, device.identity.path == path else { return }
        log.notice("Device removed: \(path, privacy: .public)")
        releasePressedKeys()
        device.close(notifyDevice: false)
        self.device = nil
        shownFaces.removeAll()
        connection = .searching
    }

    // MARK: - Input

    private func handle(_ event: DockInputEvent) {
        guard device != nil else { return }
        switch event.key {
        case .round(let number):
            if event.pressed { activateScene(at: number - 1) }
        case .lcd(let key):
            if event.pressed {
                pressedKeys.insert(key)
                activeScene.keyDown(key)
            } else {
                guard pressedKeys.remove(key) != nil else { return }
                activeScene.keyUp(key)
            }
            redraw(keys: [key])
        }
    }

    /// Modules must never see a down without an up, even across scene switches or unplugging.
    private func releasePressedKeys() {
        let keys = pressedKeys
        pressedKeys.removeAll()
        for key in keys.sorted() { activeScene.keyUp(key) }
    }

    // MARK: - Drawing

    /// Alert > the active scene's animation > the active scene's color.
    private func updateLight(fade: TimeInterval) {
        if let color = alerts.color {
            light.show(.solid(color), fade: fade)
        } else if let animation = activeScene.light {
            light.show(.animation(animation), fade: fade)
        } else {
            light.show(.solid(ledColor(for: activeScene)), fade: fade)
        }
    }

    private func redrawAll() {
        redraw(keys: Array(1...M18Layout.lcdKeyCount))
    }
}

extension DockController: SceneHost {
    func lightDidChange(in scene: DockScene) {
        if scene === activeScene { updateLight(fade: 1.5) }
    }

    func redraw(keys: [Int]) {
        guard let device else { return }
        var images: [Int: Data] = [:]
        for key in keys {
            let shown = ShownFace(
                face: activeScene.face(forKey: key),
                pressed: pressedKeys.contains(key) && activeScene.hasModule(onKey: key)
            )
            guard shownFaces[key] != shown, let jpeg = KeyRenderer.jpeg(for: shown.face, pressed: shown.pressed) else { continue }
            shownFaces[key] = shown
            images[key] = jpeg
        }
        device.setKeyImages(images)
    }
}
