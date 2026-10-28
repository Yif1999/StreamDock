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

/// How big a hit is for its own band: its raw (linear) rise against the band's big hits of the
/// song (`TimeScale.song`, `percentile`), so a kick is measured against kicks and a snare
/// against snares — the same measure `SalienceDetector` uses.
struct BandReference {
    static let percentile = 0.9
    private var history = RollingWindow(seconds: TimeScale.song)

    mutating func size(of hit: Hit) -> Double {
        history.push(time: hit.time, value: hit.magnitude)
        return hit.magnitude / max(history.percentile(Self.percentile), 1e-12)
    }
}

/// A band's heaviest hits — the kicks of the low band, the heavy snares of the mid: those
/// `Ranking` puts among the heaviest of the passage, at most one per `Ranking.gap` unless a
/// bigger one comes. Strength is the size against the band's big hits of the song, 0...1.
struct HeavyHits {
    private var recent: [(time: Double, size: Double)] = []
    private var last: (time: Double, size: Double) = (-.infinity, 0)
    var beatPeriod: Double?

    mutating func push(time: Double, size: Double) -> Double? {
        recent.removeAll { $0.time < time - TimeScale.context }
        let others = recent.map(\.size)
        recent.append((time, size))
        guard time - last.time >= Ranking.gap(beatPeriod: beatPeriod) || size > last.size,
              Ranking.isHeavy(size, among: others) else { return nil }
        last = (time, size)
        return min(1, size)
    }
}

/// The draw of the low end — kick and bass together — as a level 0...1, the larger of two parts:
/// - held: how loud the low end is under its hits — the median over `TimeScale.now`, so kicks
///   do not lift it — against the song's own loud low end (`loudness.low` is scaled to its
///   peaks over `TimeScale.song`). From `heldFloor` to `heldFull` it rises smoothly to
///   `heldMost`: a bass that plays keeps the light drawn for as long as it plays, a passage
///   without one lets go (2026-10-27: measured against the last 6 s alone, a bass that kept
///   playing became the floor and the draw fell back to 0.1–0.2 after a few seconds).
/// - rising: what rises out of the passage, `TimeScale.context` (floor at the `floorPercentile`, top at the
///   `topPercentile`, a span of at least `minimumSpan` of the top) — a kick, a new bass note —
///   up to 1, over the held part.
struct LowDraw {
    static let floorPercentile = 0.2, topPercentile = 0.95, minimumSpan = 0.35
    /// The low end counts — its hits, the kicks, the draw — only as far as it is a real part of
    /// the mix (`present`; its hits not at all at 0): from `presentFrom` of the mix's energy to `presentFull` (`BandShares.share`).
    /// A chord's leak holds ~3 %; a bass or kick 10–60 % in the six songs measured, most of it
    /// on its own (2026-10-28).
    static let presentFrom = 0.1, presentFull = 0.3
    static let heldFloor = 0.15, heldFull = 0.4, heldMost = 0.7
    private var history = RollingWindow(seconds: TimeScale.context)
    private var recent = RollingWindow(seconds: TimeScale.now)
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

/// How much each band holds of the whole mix, and whether a hit is a real part of its band —
/// not a faint spill. The rest of the analysis judges a band against itself, so in a band
/// holding next to nothing (a chime's spill into the low and mid, a chord's leak into the low)
/// the faintest rise reads as a hit and a steady trace as a bass (2026-10-28).
/// - `share`: the band's energy over `TimeScale.now` as a part of all three bands'.
/// - every band: a hit counts only while its band holds at least `heldFrom` of the mix (−50 dB,
///   anything audible: a chime's spill into the low and mid holds 1e-6 or less, the quietest
///   real band in six songs 1e-4 and up).
/// - low: as everything the low end drives, only while the low end is a real part of the mix
///   (`LowDraw.present`, applied by the analyzer).
/// - mid: and only when it rises by at least `riseFrom` of what the band holds — raw rise per
///   bin over three frames ÷ the band's energy level per bin (√(energy ÷ bins)): a chime's spill
///   over a chord rises ~0.08 of it, a chord's own beating ~0.1, real mid hits in six songs 0.3
///   and up at the 10th percentile. This measure leans against tonal sounds (one filling a few
///   bins holds a high energy level per bin and rises little per bin), which is what tells a
///   spill and a chord's beating from a hit in the mid — and why it is not used in the high,
///   where a chime is the hit and would read a tenth of its size (2026-10-28: tried in every
///   band, and with energy on both sides, which let a chord's beating through; neither held).
public struct BandShares {
    static let heldFrom = 1e-5, riseFrom = 0.2
    let binCounts: Bands
    private var frames: [Bands] = []
    private var sums = Bands()
    private let length: Int

    public init(frameRate: Double) {
        binCounts = FeatureExtractor.binCounts(sampleRate: frameRate * Double(FeatureExtractor.hopSize))
        length = max(1, Int(TimeScale.now * frameRate))
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
        guard share(hit.band) >= Self.heldFrom else { return false }
        guard hit.band == .mid else { return true }
        let level = (sums[.mid] / Double(frames.count) / binCounts[.mid]).squareRoot()
        return hit.magnitude >= Self.riseFrom * level
    }
}
