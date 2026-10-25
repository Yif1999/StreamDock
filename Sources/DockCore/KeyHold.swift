import Foundation

/// The one press-and-hold confirmation every long-press key uses. While the key is held,
/// `progress` runs 0 → 1 over `duration` and the key redraws each frame (`KeyFace.hold`, drawn
/// by `KeyDesign` as a line tracing the key's edge); the action fires only if the hold is
/// never cancelled. Cancel on release, on leaving the scene, and whenever the action no
/// longer applies.
@MainActor
public final class KeyHold {
    public static let duration: Duration = .seconds(1)
    /// Redraw rate of the tracing line: the key screen's own refresh rate (measured at 60 Hz),
    /// so every frame is on screen for exactly one refresh.
    static let framesPerSecond = 60.0

    public private(set) var progress: Double?
    public var isRunning: Bool { task != nil }
    private let duration: Duration
    private var task: Task<Void, Never>?

    public init(duration: Duration = KeyHold.duration) { self.duration = duration }

    /// Starts over; `redraw` runs on every frame (and once at the end), `fire` once if the
    /// hold completes.
    public func begin(redraw: @escaping @MainActor () -> Void, fire: @escaping @MainActor () -> Void) {
        task?.cancel()
        let start = ContinuousClock.now
        let total = Self.seconds(duration)
        progress = 0
        redraw()
        task = Task { [weak self] in
            for frame in 1... {
                // Frames are due on a fixed grid from the start, so a late frame does not push the rest back.
                let due = start + .seconds(Double(frame) / Self.framesPerSecond)
                do { try await Task.sleep(until: due, clock: .continuous) } catch { return }
                guard let self, !Task.isCancelled else { return }
                let elapsed = Self.seconds(ContinuousClock.now - start)
                guard elapsed < total else {
                    self.task = nil
                    self.progress = nil
                    fire()
                    redraw()
                    return
                }
                self.progress = elapsed / total
                redraw()
            }
        }
    }

    /// Stops without firing. Returns whether a hold was running (so the caller can redraw).
    @discardableResult public func cancel() -> Bool {
        guard let task else { return false }
        task.cancel()
        self.task = nil
        progress = nil
        return true
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
