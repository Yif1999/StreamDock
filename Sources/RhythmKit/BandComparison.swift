import Foundation

/// Offline study (`dock-probe bandcompare`): how the current split of the spectrum and a
/// proposed one tell kick, snare and cymbals apart in a recorded trace with detail bands
/// (`FeatureExtractor.detailEdges`).
///
/// - current: the live analyzer's events — kicks, mid lifts (taken as the snare), high lifts;
/// - proposed: kick = a hit at 30–150 Hz; snare = a hit at 2–6 kHz (wires, crack) with one at
///   150–400 Hz (body) within `together`; cymbals = a hit at 6–16 kHz with no snare at the time.
public enum BandComparison {
    public static let together = 0.035

    public struct Stream: Sendable {
        public let name: String
        public let times: [Double]
    }

    public struct Result: Sendable {
        public let current: (kick: Stream, snare: Stream, cymbal: Stream)
        public let proposed: (kick: Stream, snare: Stream, cymbal: Stream)
        /// The tempo the analyzer settled on (median while locked), if any.
        public let bpm: Double?
        public let start: Double, end: Double
    }

    public static func run(_ trace: RhythmTrace) -> Result? {
        guard let first = trace.frames.first, first.detail.count == FeatureExtractor.detailEdges.count else { return nil }
        let replay = trace.replay()
        var kicks: [Double] = [], mids: [Double] = [], highs: [Double] = []
        for (_, event) in replay.events {
            switch event {
            case .kick(let time, _): kicks.append(time)
            case .lift(let time, .mid, _, _): mids.append(time)
            case .lift(let time, _, _, _): highs.append(time)
            default: break
            }
        }
        let locked = replay.snapshots.compactMap { $0.1.state == .locked ? $0.1.bpm : nil }.sorted()
        let bpm = locked.isEmpty ? nil : locked[locked.count / 2]

        // Proposed: peaks in the detail bands, with the live picker's settings.
        var pickers = [
            PeakPicker(band: .low, frameRate: trace.frameRate, minimumInterval: RhythmAnalyzer.hitSpacing[.low]!),    // 30–150
            PeakPicker(band: .mid, frameRate: trace.frameRate, minimumInterval: RhythmAnalyzer.hitSpacing[.mid]!),    // 150–400 body
            PeakPicker(band: .mid, frameRate: trace.frameRate, minimumInterval: RhythmAnalyzer.hitSpacing[.mid]!),    // 2–6 k wires
            PeakPicker(band: .high, frameRate: trace.frameRate, minimumInterval: RhythmAnalyzer.hitSpacing[.high]!),  // 6–16 k cymbals
        ]
        let columns = [0, 1, 3, 4]
        var peaks: [[Double]] = [[], [], [], []]
        for frame in trace.frames where frame.detail.count == FeatureExtractor.detailEdges.count {
            for index in pickers.indices {
                let column = columns[index]
                if let hit = pickers[index].push(time: frame.time, value: frame.detail[column], raw: frame.detailRaw[column]) {
                    peaks[index].append(hit.time)
                }
            }
        }
        let near = { (time: Double, list: [Double]) in list.contains { abs($0 - time) <= together } }
        let snares = peaks[2].filter { near($0, peaks[1]) }
        let cymbals = peaks[3].filter { !near($0, snares) }
        return Result(
            current: (Stream(name: "kick (current)", times: kicks), Stream(name: "snare = mid lift (current)", times: mids), Stream(name: "high lift (current)", times: highs)),
            proposed: (Stream(name: "kick 30–150", times: peaks[0]), Stream(name: "snare = 2–6k with 150–400", times: snares), Stream(name: "cymbal 6–16k", times: cymbals)),
            bpm: bpm, start: first.time, end: trace.frames.last!.time
        )
    }

    /// Share of a stream's events with another stream's event within `window` s.
    public static func matched(_ a: [Double], in b: [Double], window: Double = 0.05) -> Double {
        guard !a.isEmpty else { return 0 }
        return Double(a.filter { t in b.contains { abs($0 - t) <= window } }.count) / Double(a.count)
    }

    /// How tightly a stream keeps one place in a cycle of `beats` beats at `bpm` (vector strength:
    /// 1 = every event at the same phase, 0 = scattered), and that phase (0..<1). Snares on 2 and
    /// 4 sit at one phase of a two-beat cycle; vocal and instrument onsets scatter.
    public static func locking(_ times: [Double], bpm: Double, beats: Double) -> (strength: Double, phase: Double) {
        guard !times.isEmpty else { return (0, 0) }
        let period = 60 / bpm * beats
        var x = 0.0, y = 0.0
        for t in times { x += cos(2 * .pi * t / period); y += sin(2 * .pi * t / period) }
        let n = Double(times.count)
        let phase = (atan2(y, x) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
        return ((x * x + y * y).squareRoot() / n, phase)
    }

    /// The tempo, refined: the analyzer's estimate is coarse (whole analysis frames per beat), and
    /// over minutes a fraction of a BPM drifts a whole beat. Searches ±4 % in 0.01 BPM steps for
    /// the tempo `times` (a periodic stream, the kicks) lock to best, one beat a cycle.
    public static func refined(_ bpm: Double, by times: [Double]) -> Double {
        stride(from: bpm * 0.96, through: bpm * 1.04, by: 0.01).max { locking(times, bpm: $0, beats: 1).strength < locking(times, bpm: $1, beats: 1).strength } ?? bpm
    }

    /// Share of the events within ±`window` of the stream's main phase in a `beats`-beat cycle.
    public static func onPhase(_ times: [Double], bpm: Double, beats: Double, window: Double = 0.06) -> Double {
        guard !times.isEmpty else { return 0 }
        let period = 60 / bpm * beats
        let phase = locking(times, bpm: bpm, beats: beats).phase
        return Double(times.filter { t in
            let p = (t / period - phase).truncatingRemainder(dividingBy: 1)
            let d = min(abs(p), 1 - abs(p)) * period
            return d <= window
        }.count) / Double(times.count)
    }

    /// Share of consecutive intervals within ±`tolerance` of `beats` beats at `bpm` — how much a
    /// stream keeps a backbeat (snares on 2 and 4 are two beats apart).
    public static func regular(_ times: [Double], bpm: Double, beats: Double, tolerance: Double = 0.12) -> Double {
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        guard !gaps.isEmpty else { return 0 }
        let period = 60 / bpm * beats
        return Double(gaps.filter { abs($0 - period) <= tolerance * period }.count) / Double(gaps.count)
    }
}
