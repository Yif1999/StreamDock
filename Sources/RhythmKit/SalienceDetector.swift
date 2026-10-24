import Foundation

/// Picks out the hits a listener feels most — what people tap along to when asked for "the
/// strongest drum hits" — whether or not they fall on the beat grid (syncopation, fills).
///
/// One measure for everything, the strike's *size*: each band's hit is its raw (linear,
/// un-normalised) flux against that band's own big hits of the last minute (`bandReference`,
/// 90th percentile), so a kick is compared with kicks and a snare with snares — the bands'
/// raw scales differ tenfold, and a log, mean-normalised flux says how sudden a hit is, not
/// how hard. A low and a mid hit within `mergeWindow` are one strike, size
/// `lowWeight·low + midWeight·mid`.
///
/// Two time scales on that one measure: *whether* a strike is an accent is its rank among the
/// strikes of the last `rankWindow` (top `topFraction`, reported the moment it qualifies);
/// *how strong* it is, its size against the big strikes of the last `magnitudeWindow`. A quiet
/// or busy passage still has accents, but small ones; only the song's real big hits reach full.
///
/// At most one accent per half beat (`gap`, from the tempo when known): a heavy flash marks
/// the strongest hit, and several a beat read as strobing. Inside the gap only a strike
/// bigger than the last accent gets through, so a weaker hit never blocks a stronger one.
struct SalienceDetector {
    /// Kicks weigh a little more: they are what is felt as the heavy beat.
    static let lowWeight = 1.0, midWeight = 0.8
    static let mergeWindow = 0.04
    static let rankWindow = 8.0
    static let topFraction = 0.3
    /// Gap when the tempo is unknown; otherwise half a beat, within `gapRange`.
    static let defaultGap = 0.25
    static let gapRange = 0.2...0.35
    /// Strikes needed before ranking means anything.
    static let warmUp = 6
    /// Band references and accent sizes look back this far.
    static let magnitudeWindow = 60.0
    static let referencePercentile = 0.9

    struct Accent: Equatable {
        let time: Double
        /// Size against the big strikes of the last minute: 1 = as strong as the top 10 %.
        let strength: Double
    }

    /// Raw hit magnitudes of the last minute, per band.
    private var bandHistory: [Bands.Band: [(time: Double, magnitude: Double)]] = [.low: [], .mid: []]
    /// Strike sizes: the last `rankWindow` for ranking, the last minute for sizing.
    private var history: [(time: Double, size: Double)] = []
    private var longHistory: [(time: Double, size: Double)] = []
    private var strike: (time: Double, low: Double, mid: Double, reported: Bool)?
    private var lastAccent: (time: Double, size: Double) = (-.infinity, 0)
    /// Set from the tempo by the analyzer.
    var beatPeriod: Double?

    private var gap: Double {
        guard let beatPeriod else { return Self.defaultGap }
        return min(Self.gapRange.upperBound, max(Self.gapRange.lowerBound, beatPeriod / 2))
    }

    mutating func push(_ hit: Hit) -> Accent? {
        guard hit.band != .high else { return nil }
        let relative = relativeSize(of: hit)
        if var current = strike, hit.time - current.time < Self.mergeWindow {
            if hit.band == .low { current.low = max(current.low, relative) } else { current.mid = max(current.mid, relative) }
            strike = current
        } else {
            if let finished = strike {
                let size = Self.size(finished.low, finished.mid)
                history.append((finished.time, size))
                longHistory.append((finished.time, size))
            }
            strike = (hit.time, hit.band == .low ? relative : 0, hit.band == .low ? 0 : relative, false)
        }
        history.removeAll { $0.time < hit.time - Self.rankWindow }
        longHistory.removeAll { $0.time < hit.time - Self.magnitudeWindow }

        guard var current = strike, !current.reported, history.count >= Self.warmUp else { return nil }
        let size = Self.size(current.low, current.mid)
        guard current.time - lastAccent.time >= gap || size > lastAccent.size else { return nil }
        let rank = Double(history.filter { $0.size < size }.count) / Double(history.count)
        guard rank >= 1 - Self.topFraction else { return nil }
        current.reported = true
        strike = current
        lastAccent = (current.time, size)
        let big = Self.percentile(longHistory.map(\.size) + [size], Self.referencePercentile)
        return Accent(time: current.time, strength: min(1, size / max(big, 1e-9)))
    }

    /// The hit's raw magnitude against its band's big hits of the last minute.
    private mutating func relativeSize(of hit: Hit) -> Double {
        var recent = bandHistory[hit.band, default: []]
        recent.append((hit.time, hit.magnitude))
        recent.removeAll { $0.time < hit.time - Self.magnitudeWindow }
        bandHistory[hit.band] = recent
        let reference = Self.percentile(recent.map(\.magnitude), Self.referencePercentile)
        return hit.magnitude / max(reference, 1e-12)
    }

    private static func size(_ low: Double, _ mid: Double) -> Double {
        lowWeight * low + midWeight * mid
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[Int(Double(sorted.count - 1) * fraction)]
    }
}
