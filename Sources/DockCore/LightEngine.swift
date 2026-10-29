import DockKit
import Foundation
import os

private let log = Logger(subsystem: "StreamDock", category: "Light")

/// Paints the light strip over time. Modules provide one through `ModuleContext.setLight`.
@MainActor
public protocol LightAnimation: AnyObject {
    /// One uncorrected color/brightness pixel per LED; only the engine applies gamma.
    /// `time` is in seconds on a steady clock.
    func pixels(at time: TimeInterval, ledCount: Int) -> [LightPixel]
    var isActive: Bool { get }
}

public extension LightAnimation { var isActive: Bool { true } }

/// Where the LEDs physically are, for animations that move along the ring.
public enum LightLayout {
    /// The light engine's frame rate: 60 Hz like the key screen, by choice — the strip itself
    /// shows every frame up to at least 240 Hz (2026-10-25, `dock-probe ledwalk` + `ledscan`).
    /// Frames go out on a fixed grid at this rate.
    public static let framesPerSecond = 60.0
    /// The ring around the base, in physical order; it closes from the last back to the first.
    public static let ring = M18Layout.ringLEDs
    /// The two short bars beside the round keys (not part of the ring).
    public static let leftBar = M18Layout.leftBarLED
    public static let rightBar = M18Layout.rightBarLED
    /// Where an LED sits seen from above, in a unit square (see `M18Layout.position(ofLED:)`).
    public static func position(_ led: Int) -> (x: Double, y: Double) { M18Layout.position(ofLED: led) }
    /// How long the short bars are, level strips across the base (same square).
    public static let barLength = M18Layout.barLength
    /// The point `lap` of the way round the ring's edge, in the same square.
    public static func edgePoint(lap: Double) -> (x: Double, y: Double) { M18Layout.edgePoint(lap: lap) }
}

/// Drives the light strip: a steady color, or an animation at `LightLayout.framesPerSecond`, with cross-fades
/// between whatever was showing and whatever comes next. Idle while showing a steady color.
///
/// Every change is eased — nothing on the strip ever switches instantly. Callers pick the
/// fade length; anything shorter than `minimumFade` is stretched to it.
@MainActor
final class LightEngine {
    enum Source {
        case solid(RGB, active: Bool = false)
        case animation(LightAnimation)
        @MainActor var isActive: Bool {
            switch self {
            case .solid(_, let active): active
            case .animation(let animation): animation.isActive
            }
        }
    }

    /// Hardware master stays at 100%; user/activity gain is mapped once in each output pixel.
    var sendBrightness: ((Int) -> Void)?
    /// Whole-strip color (applied immediately by the device).
    var sendSolid: ((RGB) -> Void)?
    /// Per-LED animation frame (may be dropped if the device is busy).
    var sendFrame: (([RGB]) -> Void)?

    static let minimumFade: TimeInterval = 0.15

    let ledCount = Int(M18Layout.ledCount)
    private var source: Source = .solid(.black)
    private var output = LEDOutput()
    private var suspended = false
    private var shown: [LightPixel]
    private var fadeFrom: [LightPixel]?
    private var fadeStart: TimeInterval = 0
    private var fadeDuration: TimeInterval = 0
    private var ticker: Task<Void, Never>?
    private var framesSent = 0
    private var lastReport: TimeInterval = 0
    private var brightness = LightBrightness()
    private var brightnessSetting = 100
    private var lastSentBrightness: Int?
    private var shownGain = 0.5
    private let clock: () -> TimeInterval
    private let automaticTicks: Bool

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, automaticTicks: Bool = true) {
        self.clock = clock
        self.automaticTicks = automaticTicks
        shown = Array(repeating: .black, count: ledCount)
    }

    func show(_ newSource: Source, fade: TimeInterval) {
        switch newSource {
        case .solid(let color, _): log.notice("Show solid \(color.hex, privacy: .public) fade=\(fade)")
        case .animation(let animation): log.notice("Show animation \(String(describing: type(of: animation)), privacy: .public) fade=\(fade)")
        }
        source = newSource
        guard !suspended else { return }
        beginFade(from: shown, duration: fade)
    }

    func setBrightness(_ percent: Int) {
        brightnessSetting = min(100, max(0, percent))
        render()
        startTicking()
    }

    func suspend() { suspended = true; stop() }
    func resume() { suspended = false; fadeInFromBlack() }

    /// After the device (re)connects: fade the current state in from dark.
    func fadeInFromBlack(duration: TimeInterval = 0.8) {
        lastSentBrightness = nil
        beginFade(from: Array(repeating: .black, count: ledCount), duration: duration)
    }

    /// Blocking fade to dark, for quitting (the run loop will not get another chance).
    func fadeOutNow(duration: TimeInterval = 0.4) {
        stop()
        let from = shown
        let start = clock()
        var progress = 0.0
        while progress < 1 {
            progress = min(1, (clock() - start) / duration)
            let eased = Motion.light.ease(progress)
            sendFrame?(output.render(from.map { $0.mixed(with: .black, amount: eased) }, gain: shownGain))
            Thread.sleep(forTimeInterval: 1 / LightLayout.framesPerSecond)
        }
        // Per-LED frames show one frame late on the M18; settle on black with a solid command.
        sendSolid?(.black)
        shown = Array(repeating: .black, count: ledCount)
    }

    private func beginFade(from start: [LightPixel], duration: TimeInterval) {
        fadeFrom = start
        fadeStart = clock()
        fadeDuration = max(duration, Self.minimumFade)
        render()
        startTicking()
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    private var needsTicking: Bool {
        if fadeFrom != nil || brightness.isAnimating(at: clock()) { return true }
        if case .animation = source { return true }
        return false
    }

    private func startTicking() {
        guard !suspended, automaticTicks, ticker == nil else { return }
        ticker = Task { [weak self] in
            let grid = FrameGrid(framesPerSecond: LightLayout.framesPerSecond)
            while true {
                do { try await grid.sleep() } catch { return }
                guard let self else { return }
                self.render()
                if !self.needsTicking {
                    self.ticker = nil
                    return
                }
            }
        }
    }

    func render() {
        guard !suspended else { return }
        let now = clock()
        let target = Double(brightnessSetting) * (source.isActive ? 1 : 0.5)
        if target != brightness.target {
            log.notice("Perceived brightness target=\(target)% setting=\(self.brightnessSetting)% active=\(self.source.isActive)")
        }
        brightness.setTarget(target, at: now)
        shownGain = min(Double(brightnessSetting), max(0, brightness.level(at: now))) / 100
        if lastSentBrightness != 100 {
            sendBrightness?(100)
            lastSentBrightness = 100
        }
        var frame: [LightPixel]
        switch source {
        case .solid(let color, _): frame = Array(repeating: LightPixel(color), count: ledCount)
        case .animation(let animation): frame = animation.pixels(at: now, ledCount: ledCount)
        }
        if let from = fadeFrom {
            let progress = min(1, (now - fadeStart) / fadeDuration)
            let eased = Motion.light.ease(progress)
            frame = zip(from, frame).map { $0.mixed(with: $1, amount: eased) }
            if progress >= 1 { fadeFrom = nil }
        }
        shown = frame

        let rendered = output.render(frame, gain: shownGain)
        if fadeFrom == nil, case .solid = source {
            sendSolid?(rendered[0])
        } else {
            sendFrame?(rendered)
            framesSent += 1
            if now - lastReport > 5 {
                log.notice("Sent \(self.framesSent) frames, first LED \(rendered[0].hex, privacy: .public)")
                framesSent = 0
                lastReport = now
            }
        }
    }

}
