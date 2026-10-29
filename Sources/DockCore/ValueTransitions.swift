import Foundation

/// Values that glide to a new reading on `Motion.ease` instead of jumping, one per `Key`
/// (a quota window, say). A module asks for what to show while it draws a face; when the target
/// differs from the last one, a transition starts from what is on screen now and `redraw` runs
/// every frame (60 Hz, `FrameGrid`) until every value has arrived. Durations follow
/// `Motion.duration(change:)`, values being shares of their range (0...1), unless given.
@MainActor
public final class ValueTransitions<Key: Hashable> {
    private struct Run {
        var from: Double, to: Double, start: ContinuousClock.Instant, seconds: Double
        func value(at now: ContinuousClock.Instant) -> Double {
            from + (to - from) * Motion.ease(KeyHold.seconds(now - start) / seconds)
        }
        func done(at now: ContinuousClock.Instant) -> Bool { KeyHold.seconds(now - start) >= seconds }
    }

    /// Where a value first seen starts from (an empty gauge fills up to its first reading).
    public let initial: Double
    public var redraw: (@MainActor () -> Void)?
    /// Seconds for a change of a given size; `Motion.duration(change:)` unless told otherwise.
    private let duration: (Double) -> Double
    private var runs: [Key: Run] = [:]
    private var task: Task<Void, Never>?

    public init(initial: Double = 0, duration: @escaping (Double) -> Double = Motion.duration(change:),
                redraw: (@MainActor () -> Void)? = nil) {
        self.initial = initial
        self.duration = duration
        self.redraw = redraw
    }

    /// What to show for `key` now, on its way to `target`.
    public func value(_ key: Key, target: Double) -> Double {
        let now = ContinuousClock.now
        let current = runs[key]?.value(at: now) ?? initial
        if runs[key]?.to != target {
            runs[key] = Run(from: current, to: target, start: now, seconds: duration(target - current))
            animate()
        }
        return runs[key]!.value(at: now)
    }

    /// Drops a value that has no reading any more; when one comes back it starts from `initial`.
    public func forget(_ key: Key) { runs[key] = nil }

    public var isAnimating: Bool { task != nil }

    private func animate() {
        guard task == nil else { return }
        task = Task { [weak self] in
            let grid = FrameGrid(framesPerSecond: 60)
            while true {
                do { try await grid.sleep() } catch { return }
                guard let self, !Task.isCancelled else { return }
                let now = ContinuousClock.now
                let moving = self.runs.values.contains { !$0.done(at: now) }
                self.redraw?()
                if !moving { self.task = nil; return }
            }
        }
    }
}
