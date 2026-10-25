import Foundation

/// When the next frame of an animation is due: frames sit on a fixed grid from the animation's
/// start, so a late frame does not push the rest back, and after a stall the next frame is the
/// next slot on the grid (missed ones are skipped, never sent in a burst). Both the key screen
/// and the light strip refresh at 60 Hz (measured, docs/design.md).
public struct FrameGrid: Sendable {
    public let start: ContinuousClock.Instant
    public let interval: Double

    public init(framesPerSecond: Double, start: ContinuousClock.Instant = .now) {
        self.start = start
        interval = 1 / framesPerSecond
    }

    /// The first grid slot after `now`.
    public func next(after now: ContinuousClock.Instant = .now) -> ContinuousClock.Instant {
        let gap = (now - start).components
        let elapsed = Double(gap.seconds) + Double(gap.attoseconds) / 1e18
        return start + .seconds(((elapsed / interval).rounded(.down) + 1) * interval)
    }

    /// Sleeps until the next slot.
    public func sleep() async throws {
        try await Task.sleep(until: next(), clock: .continuous)
    }
}
