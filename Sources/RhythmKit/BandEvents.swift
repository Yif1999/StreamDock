import Foundation

/// How big a hit is for its own band: its raw (linear) flux against the band's big hits of the
/// last `window` seconds (`percentile`), so a kick is measured against kicks and a snare
/// against snares — the same measure `SalienceDetector` uses.
struct BandReference {
    static let window = 60.0, percentile = 0.9
    private var history: [(time: Double, magnitude: Double)] = []

    mutating func size(of hit: Hit) -> Double {
        history.append((hit.time, hit.magnitude))
        history.removeAll { $0.time < hit.time - Self.window }
        let sorted = history.map(\.magnitude).sorted()
        let reference = sorted[Int(Double(sorted.count - 1) * Self.percentile)]
        return hit.magnitude / max(reference, 1e-12)
    }
}

/// The heaviest kicks: strikes told apart as kicks (`StrikeSorter`), in the top `topFraction` of
/// the last `rankWindow` by low-band size, at most one per `gap` (half a beat when the tempo is
/// known) unless a bigger one comes. Strength is the size against the low band's big hits of
/// the last minute, 0...1.
struct KickDetector {
    static let rankWindow = 8.0, topFraction = 0.3, warmUp = 6
    static let defaultGap = 0.25, gapRange = 0.2...0.35

    private var recent: [(time: Double, size: Double)] = []
    private var last: (time: Double, size: Double) = (-.infinity, 0)
    var beatPeriod: Double?

    mutating func push(time: Double, size: Double) -> Double? {
        recent.append((time, size))
        recent.removeAll { $0.time < time - Self.rankWindow }
        guard recent.count >= Self.warmUp else { return nil }
        let gap = beatPeriod.map { min(Self.gapRange.upperBound, max(Self.gapRange.lowerBound, $0 / 2)) } ?? Self.defaultGap
        guard time - last.time >= gap || size > last.size else { return nil }
        let rank = Double(recent.filter { $0.size < size }.count) / Double(recent.count)
        guard rank >= 1 - Self.topFraction else { return nil }
        last = (time, size)
        return min(1, size)
    }
}

/// Tells a drum strike's kind by where it stands out. A strike is the low and mid hits within
/// `window` of its first; each hit is sized against its own band's big hits of the last minute
/// (`BandReference`), so the measure adapts to every song and needs no tuning to one. A kick
/// stands out in the low band — its click is ordinary for the mid band; a snare stands out in
/// the mid band — what it leaks into the low band is ordinary there. So: whichever band the
/// strike is bigger for wins; a tie (kick and snare struck together) goes to the snare, the
/// accent. A strike with one band only is that band's. Decided `window` after it starts.
struct StrikeSorter {
    static let window = 0.04
    enum Kind: Equatable { case kick(size: Double), snare(size: Double) }

    private var references: [Bands.Band: BandReference] = [.low: BandReference(), .mid: BandReference()]
    private var open: (time: Double, low: Double?, mid: Double?)?

    /// Takes a low or mid hit; returns the strike it closed, if it starts a new one.
    mutating func push(_ hit: Hit) -> (time: Double, kind: Kind)? {
        guard hit.band != .high, let size = references[hit.band]?.size(of: hit) else { return nil }
        var closed: (time: Double, kind: Kind)?
        if let strike = open, hit.time - strike.time >= Self.window {
            closed = Self.sort(strike)
            open = nil
        }
        var strike = open ?? (hit.time, nil, nil)
        if hit.band == .low { strike.low = max(strike.low ?? 0, size) } else { strike.mid = max(strike.mid ?? 0, size) }
        open = strike
        return closed
    }

    /// Closes the open strike once `window` has passed.
    mutating func flush(at time: Double) -> (time: Double, kind: Kind)? {
        guard let strike = open, time - strike.time >= Self.window else { return nil }
        open = nil
        return Self.sort(strike)
    }

    private static func sort(_ strike: (time: Double, low: Double?, mid: Double?)) -> (time: Double, kind: Kind) {
        switch (strike.low, strike.mid) {
        case (let low?, let mid?): (strike.time, mid >= low ? .snare(size: mid) : .kick(size: low))
        case (let low?, nil): (strike.time, .kick(size: low))
        case (nil, let mid?): (strike.time, .snare(size: mid))
        case (nil, nil): (strike.time, .kick(size: 0))
        }
    }
}

/// The draw of the low end — kick and bass together — as a level 0...1 that follows the low
/// band's energy: 0 at its usual floor, 1 at its recent peaks. Measured against the last
/// `window` seconds (floor at the `floorPercentile`, top at the `topPercentile`), with a span
/// of at least `minimumSpan` of the top, so a steady bass drone settles back to 0 and only
/// what rises out of it — a kick, a new bass note — draws.
struct LowDraw {
    static let window = 6.0, floorPercentile = 0.2, topPercentile = 0.95, minimumSpan = 0.35
    private var history: [(time: Double, level: Double)] = []
    private(set) var value = 0.0

    mutating func push(time: Double, level: Double) {
        history.append((time, level))
        history.removeAll { $0.time < time - Self.window }
        let sorted = history.map(\.level).sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * Self.floorPercentile)]
        let top = sorted[Int(Double(sorted.count - 1) * Self.topPercentile)]
        let span = max(top - floor, Self.minimumSpan * top, 1e-6)
        value = min(1, max(0, (level - floor) / span))
    }
}
