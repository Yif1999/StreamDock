import Foundation

/// The one press-and-hold confirmation every long-press key uses. While the key is held,
/// `phase` runs `.holding` 0 → 1 over `duration` and the key redraws each frame (`KeyFace.hold`,
/// drawn by `KeyDesign` as a ring that draws itself round the key's edge); the action fires only
/// if the hold is never cancelled, and then `phase` runs `.confirmed` 0 → 1 over
/// `confirmDuration`, the response. Cancel on release, on leaving the scene, and whenever the
/// action no longer applies: the ring then slips back out (`.released`, `releaseDuration`).
@MainActor
public final class KeyHold {
    public static let duration: Duration = .seconds(1)
    /// The response after firing: the key turns back up by itself while the ring fades.
    public static let confirmDuration = 0.35
    /// The ring slipping back out after a hold is let go: as long as it took to close in.
    public static let releaseDuration = KeyDesign.pressTime
    /// Redraw rate: the key screen's own refresh rate (measured at 60 Hz), so every frame is on
    /// screen for exactly one refresh.
    static let framesPerSecond = 60.0

    public private(set) var phase: HoldPhase?
    /// Hold progress 0...1 while held (nil otherwise, including during the response).
    public var progress: Double? {
        if case .holding(let value) = phase { value } else { nil }
    }
    public var isRunning: Bool { progress != nil }
    private let duration: Duration
    private var task: Task<Void, Never>?
    private var redraw: (@MainActor () -> Void)?

    public init(duration: Duration = KeyHold.duration) { self.duration = duration }

    /// Starts over; `redraw` runs on every frame (and once at the end), `fire` once if the
    /// hold completes, returning whether the action went ahead (the response plays only then).
    public func begin(redraw: @escaping @MainActor () -> Void, fire: @escaping @MainActor () -> Bool) {
        task?.cancel()
        self.redraw = redraw
        let start = ContinuousClock.now
        let total = Self.seconds(duration)
        phase = .holding(0)
        redraw()
        task = Task { [weak self] in
            let grid = FrameGrid(framesPerSecond: Self.framesPerSecond, start: start)
            var fired = false
            while true {
                do { try await grid.sleep() } catch { return }
                guard let self, !Task.isCancelled else { return }
                let elapsed = Self.seconds(ContinuousClock.now - start)
                if elapsed < total {
                    self.phase = .holding(elapsed / total)
                } else if !fired {
                    fired = true
                    self.phase = .confirmed(0)
                    if !fire() { self.task = nil; self.phase = nil; redraw(); return }
                } else if elapsed < total + Self.confirmDuration {
                    self.phase = .confirmed((elapsed - total) / Self.confirmDuration)
                } else {
                    self.task = nil
                    self.phase = nil
                    redraw()
                    return
                }
                redraw()
            }
        }
    }

    /// Stops a hold without firing; the ring slips back out, redrawn through `redraw` as it was
    /// given to `begin`. Returns whether a hold was running (so the caller can redraw).
    /// A response already playing runs on: letting go just after the hold fired is normal.
    @discardableResult public func cancel() -> Bool {
        guard let task, let from = progress, let redraw else { return false }
        task.cancel()
        phase = .released(from: from, 0)
        let start = ContinuousClock.now
        self.task = Task { [weak self] in
            let grid = FrameGrid(framesPerSecond: Self.framesPerSecond, start: start)
            while true {
                do { try await grid.sleep() } catch { return }
                guard let self, !Task.isCancelled else { return }
                let t = Self.seconds(ContinuousClock.now - start) / Self.releaseDuration
                if t < 1 {
                    self.phase = .released(from: from, t)
                } else {
                    self.task = nil
                    self.phase = nil
                }
                redraw()
                if t >= 1 { return }
            }
        }
        return true
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
