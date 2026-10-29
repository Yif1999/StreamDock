import CoreGraphics
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
    public private(set) var activePageIndex = 0
    public var activePageTitle: String { activeScene.pageTitles[activePageIndex] }
    public private(set) var displaysSleeping = false
    @ObservationIgnored public var requestDisplayWake: (() -> Void)?
    @ObservationIgnored private var wakeGate = WakeKeyGate()
    public let settings: DockSettings

    @ObservationIgnored private var device: M18Device?
    @ObservationIgnored private let light = LightEngine()
    @ObservationIgnored private let monitor = DeviceMonitor()
    @ObservationIgnored private var pressedKeys: Set<Int> = []
    /// Held keys whose long press has fired: they turn back up at once, though still held, and
    /// stay up until let go (docs/design.md, 按下与长按).
    @ObservationIgnored private var firedKeys: Set<Int> = []
    /// A page turn in progress (`slidePage`); ordinary redraws wait for it.
    @ObservationIgnored private var pageTurn: Task<Void, Never>?
    @ObservationIgnored private var shownFaces: [Int: ShownFace] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isConnecting = false
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?

    private struct ShownFace: Equatable {
        let face: KeyFace
        let press: Double
    }
    /// How far each key is turned over by a press (`KeyDesign.pressTime`), keyed by key.
    @ObservationIgnored private lazy var presses = ValueTransitions<Int>(
        duration: { change in KeyDesign.pressTime * abs(change) },
        redraw: { [weak self] in self?.redrawAll() }
    )

    public var activeScene: DockScene { scenes[activeSceneIndex] }

    public init(scenes: [DockScene], settings: DockSettings = DockSettings()) {
        precondition(scenes.count == M18Layout.roundKeyCount, "One scene per round key")
        self.scenes = scenes
        self.settings = settings
        for scene in scenes { scene.host = self }
        light.sendBrightness = { [weak self] percent in
            guard let self, let device = self.device else { return }
            log.notice("LED hardware master=\(percent)% (perceptual brightness applied in frames)")
            device.setLEDBrightness(percent)
        }
        light.setBrightness(settings.ledBrightness)
        light.sendSolid = { [weak self] color in self?.device?.setLEDColor(red: color.red, green: color.green, blue: color.blue) }
        light.sendFrame = { [weak self] frame in self?.device?.setLEDFrame(frame.map { ($0.red, $0.green, $0.blue) }) }
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
        for scene in scenes { scene.alerts.cancel() }
        light.stop()
        reconcileTask?.cancel()
        monitor.stop()
        activeScene.deactivate()
        guard let device else { return }
        if !displaysSleeping {
            light.fadeOutNow()
            device.resetLEDEffect()
        }
        device.close(notifyDevice: !displaysSleeping)
        self.device = nil
        connection = .searching
    }

    // MARK: - Scenes and settings

    public func activateScene(at index: Int) {
        guard scenes.indices.contains(index) else { return }
        releasePressedKeys()
        if index == activeSceneIndex {
            let leaving = pageImages(), page = activeScene.currentPageIndex
            activeScene.advancePage()
            activePageIndex = activeScene.currentPageIndex
            updateLight(fade: 0.5)
            // A one-page scene has nowhere to turn to.
            if activePageIndex == page { redrawAll() } else { slide(from: leaving, toward: (0, 1)) }
            return
        }
        let leaving = pageImages()
        let rightward = index > activeSceneIndex
        activeScene.deactivate()
        activeSceneIndex = index
        activePageIndex = activeScene.currentPageIndex
        activeScene.activate()
        updateLight(fade: 0.5)
        slide(from: leaving, toward: (rightward ? 1 : -1, 0))
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
        if !displaysSleeping { device?.setScreenBrightness(percent) }
    }

    public func setLEDBrightness(_ percent: Int) {
        settings.ledBrightness = percent
        light.setBrightness(percent)
    }

    /// Suspend output and held actions; keep network state alive for a current redraw on wake.
    public func setDisplaysSleeping(_ sleeping: Bool) {
        guard displaysSleeping != sleeping else { return }
        displaysSleeping = sleeping
        log.notice("Display sleep=\(sleeping)")
        if sleeping {
            wakeGate.suppress(pressedKeys.map(DockKey.lcd))
            releasePressedKeys()
            light.suspend()
            blankDevice()
        } else {
            wakeGate.screenDidWake()
            device?.wakeScreen()
            device?.setScreenBrightness(settings.screenBrightness)
            shownFaces.removeAll()
            redrawAll()
            light.resume()
        }
    }

    private func blankDevice() {
        device?.setScreenBrightness(0)
        device?.setLEDBrightness(0)
        device?.setLEDColor(red: 0, green: 0, blue: 0)
        device?.sleepScreen()
        device?.waitUntilIdle()
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
            let awake = !displaysSleeping
            let opened = try await Task.detached {
                try M18Device(opening: identity, displayAwake: awake, onInput: onInput)
            }.value
            device = opened
            connection = .connected(serial: identity.serialNumber, firmware: opened.firmwareVersion)
            log.notice("Connected \(identity.path, privacy: .public) fw=\(opened.firmwareVersion, privacy: .public)")
            if displaysSleeping { blankDevice() }
            else {
                opened.wakeScreen()
                opened.setScreenBrightness(settings.screenBrightness)
                light.fadeInFromBlack()
                shownFaces.removeAll()
                redrawAll()
            }
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
        wakeGate.reset()
        device.close(notifyDevice: false)
        self.device = nil
        shownFaces.removeAll()
        connection = .searching
    }

    // MARK: - Input

    private func handle(_ event: DockInputEvent) {
        guard device != nil else { return }
        let route = wakeGate.route(event, asleep: displaysSleeping)
        if route.consume {
            log.notice("Wake gate key=\(String(describing: event.key), privacy: .public) pressed=\(event.pressed) asleep=\(self.displaysSleeping) requestWake=\(route.wake) handlerAvailable=\(self.requestDisplayWake != nil)")
            if route.wake { requestDisplayWake?() }
            return
        }
        switch event.key {
        case .round(let number):
            if event.pressed { activateScene(at: number - 1) }
        case .lcd(let key):
            if event.pressed {
                log.notice("Key \(key) down scene=\(self.activeScene.id, privacy: .public) page=\(self.activePageIndex + 1)")
                pressedKeys.insert(key)
                activeScene.keyDown(key)
            } else {
                guard pressedKeys.remove(key) != nil else { return }
                firedKeys.remove(key)
                activeScene.keyUp(key)
            }
            redraw(keys: [key])
        }
    }

    /// Modules must never see a down without an up, even across scene switches or unplugging.
    private func releasePressedKeys() {
        let keys = pressedKeys
        pressedKeys.removeAll()
        firedKeys.removeAll()
        for key in keys.sorted() { activeScene.keyUp(key) }
    }

    // MARK: - Drawing

    /// Only the scene on screen lights the strip: its alert > its activity (OBS) > its page's
    /// animation (music) > its color.
    private func updateLight(fade: TimeInterval) {
        let scene = activeScene
        light.show(scene.activities.source(alert: scene.alerts.color, sceneAnimation: scene.light,
                                           sceneColor: ledColor(for: scene)), fade: fade)
    }

    private func redrawAll() {
        redraw(keys: Array(1...M18Layout.lcdKeyCount))
    }

    // MARK: - Page turn

    /// Every key of the page on screen, as drawn now (nil when nothing is shown).
    private func pageImages() -> [Int: CGImage]? {
        guard !displaysSleeping, device != nil else { return nil }
        var images: [Int: CGImage] = [:]
        for key in 1...M18Layout.lcdKeyCount {
            images[key] = KeyRenderer.image(for: activeScene.face(forKey: key))
        }
        return images
    }

    /// Slides the page on screen away for the one now there (`PageSlide`). Ordinary redraws wait
    /// until it lands; a new change mid-way starts over from the old page's picture.
    private func slide(from leaving: [Int: CGImage]?, toward: (x: Double, y: Double)) {
        pageTurn?.cancel()
        pageTurn = nil
        guard let leaving, let arriving = pageImages() else { return redrawAll() }
        let slide = PageSlide(leaving: leaving, arriving: arriving, toward: toward)
        let start = ContinuousClock.now
        pageTurn = Task { [weak self] in
            let grid = FrameGrid(framesPerSecond: PageSlide.framesPerSecond, start: start)
            var sent: [Int: Data] = [:]
            while true {
                guard let self, !Task.isCancelled, let device = self.device, !self.displaysSleeping else { return }
                let t = min(1, KeyHold.seconds(ContinuousClock.now - start) / PageSlide.seconds)
                if t >= 1 {
                    // The landed page, at full quality.
                    self.pageTurn = nil
                    self.shownFaces = [:]
                    self.redrawAll()
                    return
                }
                var images: [Int: Data] = [:]
                for (key, image) in slide.frame(at: t) {
                    guard let jpeg = KeyRenderer.jpeg(image, quality: KeyRenderer.motionQuality), sent[key] != jpeg else { continue }
                    images[key] = jpeg
                    sent[key] = jpeg
                }
                device.setKeyImages(images)
                do { try await grid.sleep() } catch { return }
            }
        }
    }
}

extension DockController: SceneHost {
    func lightDidChange(in scene: DockScene, fade: TimeInterval) {
        if scene === activeScene { updateLight(fade: fade) }
    }

    func redraw(keys: [Int]) {
        guard !displaysSleeping, pageTurn == nil, let device else { return }
        var images: [Int: Data] = [:]
        for key in keys {
            let face = activeScene.face(forKey: key)
            if case .confirmed = face.hold, pressedKeys.contains(key) { firedKeys.insert(key) }
            let down = pressedKeys.contains(key) && !firedKeys.contains(key) && activeScene.hasModule(onKey: key)
            let shown = ShownFace(face: face, press: presses.value(key, target: down ? 1 : 0))
            guard shownFaces[key] != shown, let jpeg = KeyRenderer.jpeg(for: shown.face, press: shown.press) else { continue }
            shownFaces[key] = shown
            images[key] = jpeg
        }
        device.setKeyImages(images)
    }
}
