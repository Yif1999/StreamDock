import Foundation

/// Offline study for one measure across the bands (`dock-probe bandstats`): for a recorded
/// song, how much of the mix each band holds, and how big each band's picked hits are —
/// against the band itself and against the whole mix.
public enum BandStats {
    public static func report(_ trace: RhythmTrace) -> String {
        let counts = FeatureExtractor.binCounts(sampleRate: trace.frameRate * Double(FeatureExtractor.hopSize))
        var pickers = Bands.Band.allCases.map { PeakPicker(band: $0, frameRate: trace.frameRate, minimumInterval: RhythmAnalyzer.hitSpacing[$0]!) }
        let length = max(1, Int(0.5 * trace.frameRate))
        var recent: [Bands] = []
        var shares: [Bands.Band: [Double]] = [:], againstBand: [Bands.Band: [Double]] = [:], againstMix: [Bands.Band: [Double]] = [:]
        for frame in trace.frames where frame.energy.low + frame.energy.mid + frame.energy.high > 0 {
            recent.append(frame.energy)
            if recent.count > length { recent.removeFirst() }
            var mean = Bands()
            for energy in recent { for band in Bands.Band.allCases { mean[band] += energy[band] / Double(recent.count) } }
            let mix = mean.low + mean.mid + mean.high
            for band in Bands.Band.allCases { shares[band, default: []].append(mean[band] / mix) }
            for index in pickers.indices {
                let band = pickers[index].band
                guard let hit = pickers[index].push(time: frame.time, value: frame.flux[band], raw: frame.rawFlux[band]) else { continue }
                // Raw rise per bin ÷ the band's energy level per bin (as `BandShares` for the mid), and the rise's energy ÷ the mix's.
                againstBand[band, default: []].append(hit.magnitude / max((mean[band] / counts[band]).squareRoot(), 1e-12))
                againstMix[band, default: []].append(hit.magnitude * hit.magnitude * counts[band] / max(mix, 1e-12))
            }
        }
        func spread(_ values: [Double]?) -> String {
            guard let values, !values.isEmpty else { return "-" }
            let sorted = values.sorted()
            return [0.1, 0.25, 0.5, 0.75, 0.9].map { String(format: "%.3g", sorted[Int(Double(sorted.count - 1) * $0)]) }.joined(separator: " / ")
        }
        return Bands.Band.allCases.map { band in
            "\(band): share \(spread(shares[band])) | \(againstBand[band]?.count ?? 0) hits, rise÷band \(spread(againstBand[band])) | rise÷mix \(spread(againstMix[band]))"
        }.joined(separator: "\n")
    }
}

extension BandStats {
    /// Where the live mid lifts come from (`dock-probe midorigin`): for each, which parts of the
    /// mid band peaked with it (150–400 Hz body, 400–2000, 2–6 kHz wires and crack, within
    /// `BandComparison.together`) and whether a low hit came with it — to see what a kick
    /// sets off in the mid. Needs a trace with detail bands.
    public static func midOrigins(_ trace: RhythmTrace) -> String {
        guard let first = trace.frames.first, first.detail.count == FeatureExtractor.detailEdges.count else { return "no detail bands" }
        let replay = trace.replay()
        var lows: [Double] = [], mids: [(time: Double, heavy: Bool)] = []
        for (_, event) in replay.events {
            switch event {
            case .hit(let hit) where hit.band == .low: lows.append(hit.time)
            case .lift(let time, .mid, _, let heavy): mids.append((time, heavy))
            default: break
            }
        }
        var pickers = (1...3).map { _ in PeakPicker(band: .mid, frameRate: trace.frameRate, minimumInterval: RhythmAnalyzer.hitSpacing[.mid]!) }
        var peaks: [[Double]] = [[], [], []]
        for frame in trace.frames where frame.detail.count == FeatureExtractor.detailEdges.count {
            for index in 0..<3 {
                if let hit = pickers[index].push(time: frame.time, value: frame.detail[index + 1], raw: frame.detailRaw[index + 1]) { peaks[index].append(hit.time) }
            }
        }
        let near = { (time: Double, list: [Double]) in list.contains { abs($0 - time) <= BandComparison.together } }
        var counts: [String: (all: Int, heavy: Int)] = [:]
        for mid in mids {
            let parts = ["body", "middle", "wires"].enumerated().filter { near(mid.time, peaks[$0.offset]) }.map(\.element)
            let key = (near(mid.time, lows) ? "with low hit: " : "no low hit:   ") + (parts.isEmpty ? "none" : parts.joined(separator: "+"))
            counts[key, default: (0, 0)].all += 1
            if mid.heavy { counts[key, default: (0, 0)].heavy += 1 }
        }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.all) (heavy \($0.value.heavy))" }.joined(separator: "\n")
    }
}
