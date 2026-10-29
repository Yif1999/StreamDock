import Foundation

/// The one way things move. Every key animation and every light-strip fade takes its timing from
/// here, so movement reads the same everywhere (docs/design.md, 动画).
///
/// - `Curve`: the one formula, a cubic Bézier (a, 0, 1 − a, 1) — slow away, fast through the
///   middle, slow into place — set by how fast its middle is (`peak`, times the average speed;
///   a = 1 − 1/peak). Smoothstep (3t² − 2t³) is the member with peak 1.5.
/// - `ease` (`keys`, peak 5): anything on the keys that goes from one state to another.
/// - `light` (peak 1.5): light-strip cross-fades; a whole strip changing color reads best gentler.
/// - `settle`: the same arrival with follow-through, overshooting once by about 8 % and springing
///   back. Only where nothing else says "done": artwork springing back up when a long press fires
///   (other keys turn over instead, and a fill has nothing to overshoot into). Never for values,
///   presses or the ring.
/// - `stretch`: squash and stretch from speed, for shapes in flight.
/// - `duration`: how long a move takes, from how far it goes (a shape across the keys, or a value
///   across its range).
/// - `ValueTransitions`: numbers that glide on `ease` instead of jumping.
public enum Motion {
    /// The easing formula: cubic Bézier (a, 0, 1 − a, 1), its middle `peak` times the average speed.
    public struct Curve: Sendable {
        public let peak: Double
        /// The first control point's x; the second is 1 − a.
        let a: Double

        public init(peak: Double) {
            self.peak = peak
            a = 1 - 1 / peak
        }

        /// Progress 0...1 along the curve at time `t` (0...1, clamped).
        public func ease(_ t: Double) -> Double {
            guard t > 0 else { return 0 }
            guard t < 1 else { return 1 }
            return Motion.cubic(parameter(forX: t), 0, 1)
        }

        /// The slope at `t`: speed relative to the average (1 = average, `peak` at the middle).
        public func speed(_ t: Double) -> Double {
            let u = parameter(forX: min(1, max(0, t)))
            let dx = Motion.slope(u, a, 1 - a)
            return dx > 1e-9 ? Motion.slope(u, 0, 1) / dx : 0
        }

        /// The Bézier parameter whose x is `x`: bisection (x rises monotonically), exact to 1e-7.
        private func parameter(forX x: Double) -> Double {
            var low = 0.0, high = 1.0
            for _ in 0..<30 {
                let mid = (low + high) / 2
                if Motion.cubic(mid, a, 1 - a) < x { low = mid } else { high = mid }
            }
            return (low + high) / 2
        }
    }

    /// The keys' curve, Bézier (0.8, 0, 0.2, 1). It began at peak 3.3 (0.7, 0, 0.3, 1); the user
    /// found the middle not fast enough on the quota gauges.
    public static let keys = Curve(peak: 5)
    /// The light strip's curve, Bézier (1/3, 0, 2/3, 1) = smoothstep. Compared on the strip with
    /// the keys' curve and peak 2.5, the user kept this one (2026-10-29).
    public static let light = Curve(peak: 1.5)

    /// `keys.ease`.
    public static func ease(_ t: Double) -> Double { keys.ease(t) }
    /// `keys.speed`.
    public static func speed(_ t: Double) -> Double { keys.speed(t) }
    /// The keys' top speed (at t = 0.5).
    public static var peakSpeed: Double { keys.peak }

    /// Arrival with follow-through at time `t` (0...1): 0 → past 1 by about 8 % → 1. Starts
    /// gently (its clock runs on `light` at first), so it still leaves slowly.
    public static func settle(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        // A damped spring released from rest: 1 − e^(−a·s)(cos b·s + a/b · sin b·s), on a clock s
        // that runs slow at first — overshoot e^(−aπ/b) ≈ 8 %, within 0.1 % at the end.
        let a = 7.5, b = 9.5
        let s = t < 1 ? light.ease(t) * 0.35 + t * 0.65 : 1
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

    fileprivate static func cubic(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
        let v = 1 - u
        return 3 * v * v * u * p1 + 3 * v * u * u * p2 + u * u * u
    }

    fileprivate static func slope(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
        let v = 1 - u
        return 3 * v * v * p1 + 6 * v * u * (p2 - p1) + 3 * u * u * (1 - p2)
    }
}
