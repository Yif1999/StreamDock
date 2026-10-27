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
/// top `topFraction` of the last `rankWindow` by size, at most one per `gap` (half a beat when
/// the tempo is known) unless a bigger one comes. Strength is the size against the band's big
/// hits of the last minute, 0...1.
struct HeavyHits {
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

/// The draw of the low end — kick and bass together — as a level 0...1 that follows the low
/// band's energy: 0 at its usual floor, 1 at its recent peaks. Measured against the last
/// `window` seconds (floor at the `floorPercentile`, top at the `topPercentile`), with a span
/// of at least `minimumSpan` of the top, so a steady bass drone settles back to 0 and only
/// what rises out of it — a kick, a new bass note — draws.
struct LowDraw {
    static let window = 6.0, floorPercentile = 0.2, topPercentile = 0.95, minimumSpan = 0.35
    private var history = RollingWindow(seconds: window)
    private(set) var value = 0.0

    mutating func push(time: Double, level: Double) {
        history.push(time: time, value: level)
        let floor = history.percentile(Self.floorPercentile)
        let top = history.percentile(Self.topPercentile)
        let span = max(top - floor, Self.minimumSpan * top, 1e-6)
        value = min(1, max(0, (level - floor) / span))
    }
}
