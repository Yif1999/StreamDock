import DockKit
import Foundation
import os

private let log = Logger(subsystem: "StreamDock", category: "Light")

/// Paints the light strip over time. Modules provide one through `ModuleContext.setLight`.
@MainActor
public protocol LightAnimation: AnyObject {
    /// One color per LED (indexed as on the device; see `LightLayout`) for the given moment.
    /// `time` is in seconds on a steady clock.
    func colors(at time: TimeInterval, ledCount: Int) -> [RGB]
}

/// Where the LEDs physically are, for animations that move along the ring.
public enum LightLayout {
    /// The ring around the base, in physical order; it closes from the last back to the first.
    public static let ring = M18Layout.ringLEDs
    /// The two short bars beside the round keys (not part of the ring).
    public static let leftBar = M18Layout.leftBarLED
    public static let rightBar = M18Layout.rightBarLED
}

/// Drives the light strip: a steady color, or an animation at ~30 fps, with cross-fades
/// between whatever was showing and whatever comes next. Idle while showing a steady color.
///
/// Every change is eased — nothing on the strip ever switches instantly. Callers pick the
/// fade length; anything shorter than `minimumFade` is stretched to it.
@MainActor
final class LightEngine {
    enum Source {
        case solid(RGB)
        case animation(LightAnimation)
    }

    /// Whole-strip color (applied immediately by the device).
    var sendSolid: ((RGB) -> Void)?
    /// Per-LED animation frame (may be dropped if the device is busy).
    var sendFrame: (([RGB]) -> Void)?

    static let minimumFade: TimeInterval = 0.15

    let ledCount = Int(M18Layout.ledCount)
    private var source: Source = .solid(.black)
    private var shown: [RGB]
    private var fadeFrom: [RGB]?
    private var fadeStart: TimeInterval = 0
    private var fadeDuration: TimeInterval = 0
    private var ticker: Task<Void, Never>?
    private var framesSent = 0
    private var lastReport: TimeInterval = 0

    init() {
        shown = Array(repeating: .black, count: ledCount)
    }

    func show(_ newSource: Source, fade: TimeInterval) {
        switch newSource {
        case .solid(let color): log.notice("Show solid \(color.hex, privacy: .public) fade=\(fade)")
        case .animation(let animation): log.notice("Show animation \(String(describing: type(of: animation)), privacy: .public) fade=\(fade)")
        }
        source = newSource
        beginFade(from: shown, duration: fade)
    }

    /// After the device (re)connects: fade the current state in from dark.
    func fadeInFromBlack(duration: TimeInterval = 0.8) {
        beginFade(from: Array(repeating: .black, count: ledCount), duration: duration)
    }

    /// Blocking fade to dark, for quitting (the run loop will not get another chance).
    func fadeOutNow(duration: TimeInterval = 0.4) {
        stop()
        let from = shown
        let start = Self.now
        var progress = 0.0
        while progress < 1 {
            progress = min(1, (Self.now - start) / duration)
            let eased = Self.ease(progress)
            sendFrame?(from.map { $0.mixed(with: .black, amount: eased) })
            Thread.sleep(forTimeInterval: 1.0 / 30)
        }
        // Per-LED frames show one frame late on the M18; settle on black with a solid command.
        sendSolid?(.black)
        shown = Array(repeating: .black, count: ledCount)
    }

    private func beginFade(from start: [RGB], duration: TimeInterval) {
        fadeFrom = start
        fadeStart = Self.now
        fadeDuration = max(duration, Self.minimumFade)
        render()
        startTicking()
    }

    private static func ease(_ progress: Double) -> Double {
        progress * progress * (3 - 2 * progress)
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    private var needsTicking: Bool {
        if fadeFrom != nil { return true }
        if case .animation = source { return true }
        return false
    }

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { return }
                self.render()
                if !self.needsTicking {
                    self.ticker = nil
                    return
                }
            }
        }
    }

    private func render() {
        let now = Self.now
        var frame: [RGB]
        switch source {
        case .solid(let color): frame = Array(repeating: color, count: ledCount)
        case .animation(let animation): frame = animation.colors(at: now, ledCount: ledCount)
        }
        if let from = fadeFrom {
            let progress = min(1, (now - fadeStart) / fadeDuration)
            let eased = Self.ease(progress)
            frame = zip(from, frame).map { $0.mixed(with: $1, amount: eased) }
            if progress >= 1 { fadeFrom = nil }
        }
        shown = frame

        if fadeFrom == nil, case .solid(let color) = source {
            sendSolid?(color)
        } else {
            sendFrame?(frame)
            framesSent += 1
            if now - lastReport > 5 {
                log.notice("Sent \(self.framesSent) frames, first LED \(frame[0].hex, privacy: .public)")
                framesSent = 0
                lastReport = now
            }
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
