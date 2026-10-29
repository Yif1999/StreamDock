import Foundation

/// The one way things move on the keys. Every key animation takes its timing from here, so
/// movement reads the same everywhere (docs/design.md, 动画).
///
/// - `ease`: the curve for anything that goes from one state to another. Slow away, fast through
///   the middle (5× the average speed), slow into place — cubic Bézier (0.8, 0, 0.2, 1).
/// - `settle`: the same arrival with follow-through, overshooting once by about 8 % and springing
///   back. Only where nothing else says "done": artwork springing back up when a long press fires
///   (other keys turn over instead, and a fill has nothing to overshoot into). Never for values,
///   presses or the ring.
/// - `stretch`: squash and stretch from speed, for shapes in flight.
/// - `duration`: how long a move takes, from how far it goes (a shape across the keys, or a value
///   across its range).
/// - `ValueTransitions`: numbers that glide on `ease` instead of jumping.
public enum Motion {
    /// Control points of the curve (x1, y1, x2, y2); the ends are (0, 0) and (1, 1).
    static let bezier = (x1: 0.8, y1: 0.0, x2: 0.2, y2: 1.0)

    /// Progress 0...1 along the curve at time `t` (0...1, clamped).
    public static func ease(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        return cubic(parameter(forX: t), bezier.y1, bezier.y2)
    }

    /// The curve's slope at `t`: speed relative to the average (1 = average, 5 at the middle).
    public static func speed(_ t: Double) -> Double {
        let u = parameter(forX: min(1, max(0, t)))
        let dx = slope(u, bezier.x1, bezier.x2)
        return dx > 1e-9 ? slope(u, bezier.y1, bezier.y2) / dx : 0
    }

    /// The curve's top speed (at t = 0.5).
    public static let peakSpeed = speed(0.5)

    /// Arrival with follow-through at time `t` (0...1): 0 → past 1 by about 8 % → 1. Starts
    /// with `ease`'s slow first third, so it still leaves gently.
    public static func settle(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        // A damped spring released from rest: 1 − e^(−a·s)(cos b·s + a/b · sin b·s), on a clock s
        // that runs slow at first (ease's start) — overshoot e^(−aπ/b) ≈ 8 %, within 0.1 % at the end.
        let a = 7.5, b = 9.5
        let s = t < 1 ? t * t * (3 - 2 * t) * 0.35 + t * 0.65 : 1
        let value = 1 - exp(-a * s) * (cos(b * s) + a / b * sin(b * s))
        return t >= 1 ? 1 : value
    }

    /// Squash and stretch for a shape moving at `speed` (relative, as `speed(_:)` gives): its
    /// length along the motion and its width across it, keeping the area. At top speed it is
    /// `amount` longer (default 30 %).
    public static func stretch(speed: Double, amount: Double = 0.3) -> (along: Double, across: Double) {
        let along = 1 + amount * min(1, max(0, speed / peakSpeed))
        return (along, 1 / along)
    }

    /// How long a move of `distance` key-field pixels takes: a quarter second for a key's width,
    /// growing with the square root of the distance (far moves get faster, not just longer),
    /// never under 0.18 s or over 0.6 s.
    public static func duration(distance: Double) -> Double {
        min(0.6, max(0.18, 0.25 * (abs(distance) / 64).squareRoot()))
    }

    /// How long a value takes to move by `change` (a share of its whole range, 0...1): long
    /// enough to be read as a change, 0.35 s for a nudge up to 0.7 s across the whole range.
    public static func duration(change: Double) -> Double {
        0.35 + 0.35 * min(1, abs(change)).squareRoot()
    }

    // MARK: - Bézier

    private static func cubic(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
        let v = 1 - u
        return 3 * v * v * u * p1 + 3 * v * u * u * p2 + u * u * u
    }

    private static func slope(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
        let v = 1 - u
        return 3 * v * v * p1 + 6 * v * u * (p2 - p1) + 3 * u * u * (1 - p2)
    }

    /// The Bézier parameter whose x is `x`: bisection (x rises monotonically), exact to 1e-7.
    private static func parameter(forX x: Double) -> Double {
        var low = 0.0, high = 1.0
        for _ in 0..<30 {
            let mid = (low + high) / 2
            if cubic(mid, bezier.x1, bezier.x2) < x { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }
}
