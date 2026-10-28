import Foundation

/// The values of the last `window` seconds, kept in order as they come and go, for their
/// percentiles: a new value is put in its place and an expired one taken out (binary search),
/// instead of sorting the whole window for every value — the low end pushes ~94 a second.
/// Times must not go backwards. Same percentiles as sorting the window each time.
struct RollingWindow {
    let window: Double
    private var entries: [(time: Double, value: Double)] = []
    private var head = 0
    private var sorted: [Double] = []

    init(seconds: Double) { window = seconds }

    var isEmpty: Bool { sorted.isEmpty }

    mutating func push(time: Double, value: Double) {
        entries.append((time, value))
        sorted.insert(value, at: Self.firstIndex(notBelow: value, in: sorted))
        while head < entries.count, entries[head].time < time - window {
            sorted.remove(at: Self.firstIndex(notBelow: entries[head].value, in: sorted))
            head += 1
        }
        // Drop the spent front now and then, not on every push.
        if head > 1024 { entries.removeFirst(head); head = 0 }
    }

    /// The value `fraction` of the way up the window (0 the lowest, 1 the highest).
    func percentile(_ fraction: Double) -> Double {
        sorted[Int(Double(sorted.count - 1) * fraction)]
    }

    private static func firstIndex(notBelow value: Double, in sorted: [Double]) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// How big a hit is for its own band: its raw (linear) flux against the band's big hits of the
/// last `window` seconds (`percentile`), so a kick is measured against kicks and a snare
/// against snares — the same measure `SalienceDetector` uses.
struct BandReference {
    static let window = 60.0, percentile = 0.9
    private var history = RollingWindow(seconds: window)

    mutating func size(of hit: Hit) -> Double {
        history.push(time: hit.time, value: hit.magnitude)
        return hit.magnitude / max(history.percentile(Self.percentile), 1e-12)
    }
}

/// A band's heaviest hits — the kicks of the low band, the heavy snares of the mid: hits in the
/// top `topFraction` of the last `rankWindow` by size (hits within `tie` of each other ranked as equals), at most one per `gap` (half a beat when
/// the tempo is known) unless a bigger one comes. Strength is the size against the band's big
/// hits of the last minute, 0...1.
struct HeavyHits {
    static let rankWindow = 8.0, topFraction = 0.3, warmUp = 6, tie = 0.1
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
        // Ranked with near-equal hits (within `tie`) counted as half below, half above — the usual
        // way with ties: a backbeat of equally hard snares ranks together instead of only the few
        // that came out a hair bigger (2026-10-28: a drum loop flashed on 1–2 of its 8 snares),
        // while a run of equal light hits under a few heavy ones still ranks low.
        let below = recent.filter { $0.size * (1 + Self.tie) < size }.count
        let level = recent.filter { abs($0.size - size) <= Self.tie * max($0.size, size) }.count - 1
        let rank = (Double(below) + 0.5 * Double(level)) / Double(recent.count)
        guard rank >= 1 - Self.topFraction else { return nil }
        last = (time, size)
        return min(1, size)
    }
}

/// The draw of the low end — kick and bass together — as a level 0...1, the larger of two parts:
/// - held: how loud the low end is under its hits — the median of the last `heldWindow` s, so
///   kicks do not lift it — against the song's own loud low end (`loudness.low` is scaled to
///   its peaks of the last minute). From `heldFloor` to `heldFull` it rises smoothly to
///   `heldMost`: a bass that plays keeps the light drawn for as long as it plays, a passage
///   without one lets go (2026-10-27: measured against the last 6 s alone, a bass that kept
///   playing became the floor and the draw fell back to 0.1–0.2 after a few seconds).
/// - rising: what rises out of the last `window` s (floor at the `floorPercentile`, top at the
///   `topPercentile`, a span of at least `minimumSpan` of the top) — a kick, a new bass note —
///   up to 1, over the held part.
struct LowDraw {
    static let window = 6.0, floorPercentile = 0.2, topPercentile = 0.95, minimumSpan = 0.35
    /// Both parts count only as far as the low band is a real part of the mix: from
    /// `presentFrom` of its energy to `presentFull` (`BandShares.share`) — a chord's leak or a
    /// chime's spill holds a few percent at most, a bass or kick most of it (2026-10-28).
    static let presentFrom = 0.1, presentFull = 0.3
    static let heldWindow = 1.0, heldFloor = 0.15, heldFull = 0.4, heldMost = 0.7
    private var history = RollingWindow(seconds: window)
    private var recent = RollingWindow(seconds: heldWindow)
    private(set) var held = 0.0, rising = 0.0, present = 1.0
    var value: Double { max(held, rising) * present }

    mutating func push(time: Double, level: Double, share: Double = 1) {
        present = RhythmAnalyzer.smoothstep((share - Self.presentFrom) / (Self.presentFull - Self.presentFrom))
        history.push(time: time, value: level)
        recent.push(time: time, value: level)
        let floor = history.percentile(Self.floorPercentile)
        let top = history.percentile(Self.topPercentile)
        let span = max(top - floor, Self.minimumSpan * top, 1e-6)
        rising = min(1, max(0, (level - floor) / span))
        let under = recent.percentile(0.5)
        held = Self.heldMost * RhythmAnalyzer.smoothstep((under - Self.heldFloor) / (Self.heldFull - Self.heldFloor))
    }
}

/// How much each band holds of the whole mix, and whether a low or mid hit is a real part of
/// its band — not a faint spill. Every other measure judges a band against itself, so in a band
/// holding next to nothing (a chime's spill into the low and mid, a chord's leak into the low)
/// the faintest rise reads as a hit and a steady trace as a bass (2026-10-28).
/// - `share`: the band's energy over the last `window` s as a part of all three bands'.
/// - a low hit counts when the low band holds at least `lowFrom` of the mix (where the draw
///   starts, `LowDraw.presentFrom`): a chord's leak holds ~3 %, a bass or kick most of it. Its
///   rise is not judged: under a loud bass a kick rises little against the band and still is
///   one (a song lost 4 of 42 kicks that way, 2026-10-28).
/// - a mid hit counts when the mid band holds at least `midFrom` of the mix and the hit rises
///   by at least `riseFrom` of what the band holds (raw rise per bin ÷ the band's level per
///   bin): a chime's spill over a chord rises ~0.08 of it, a snare ~1.
/// The high band is left as it is: its spills into the others are what this keeps out.
public struct BandShares {
    static let window = 0.5, lowFrom = LowDraw.presentFrom, midFrom = 0.01, riseFrom = 0.2
    let binCounts: Bands
    private var frames: [Bands] = []
    private var sums = Bands()
    private let length: Int

    public init(frameRate: Double) {
        binCounts = FeatureExtractor.binCounts(sampleRate: frameRate * Double(FeatureExtractor.hopSize))
        length = max(1, Int(Self.window * frameRate))
    }

    public mutating func push(_ energy: Bands) {
        frames.append(energy)
        for band in Bands.Band.allCases { sums[band] += energy[band] }
        if frames.count > length {
            let gone = frames.removeFirst()
            for band in Bands.Band.allCases { sums[band] = max(0, sums[band] - gone[band]) }
        }
    }

    public func share(_ band: Bands.Band) -> Double {
        let total = sums.low + sums.mid + sums.high
        return total > 0 ? sums[band] / total : 0
    }

    func counts(_ hit: Hit) -> Bool {
        guard !frames.isEmpty else { return true }
        switch hit.band {
        case .low: return share(.low) >= Self.lowFrom
        case .mid:
            let level = (sums[.mid] / Double(frames.count) / binCounts[.mid]).squareRoot()
            return share(.mid) >= Self.midFrom && hit.magnitude >= Self.riseFrom * level
        case .high: return true
        }
    }
}
