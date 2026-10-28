import Foundation

/// A recording for offline tuning: feature frames (not audio — nothing that could rebuild the
/// music) plus the times the listener tapped along to the beat.
///
///     # streamdock-rhythm-trace v1 frameRate=93.750
///     F <time> <flux low> <flux mid> <flux high> <loudness low> <loudness mid> <loudness high> [<raw flux low> <raw flux mid> <raw flux high> [<energy low> <energy mid> <energy high>] [<detail flux ×5> <detail raw flux ×5>]]
///     # note <text>   (what was playing, from where — for matching times to the song)
///     T <time>
public struct RhythmTrace: Sendable {
    public var frameRate: Double
    public var frames: [FeatureFrame] = []
    public var taps: [Double] = []

    public init(frameRate: Double) {
        self.frameRate = frameRate
    }

    public var notes: [String] = []

    public static func frameLine(_ frame: FeatureFrame) -> String {
        var line = String(
            format: "F %.4f %.3f %.3f %.3f %.3f %.3f %.3f %.5f %.5f %.5f", frame.time,
            frame.flux.low, frame.flux.mid, frame.flux.high,
            frame.loudness.low, frame.loudness.mid, frame.loudness.high,
            frame.rawFlux.low, frame.rawFlux.mid, frame.rawFlux.high
        )
        line += String(format: " %.4g %.4g %.4g", frame.energy.low, frame.energy.mid, frame.energy.high)
        if frame.detail.count == FeatureExtractor.detailEdges.count, frame.detailRaw.count == frame.detail.count {
            line += frame.detail.map { String(format: " %.3f", $0) }.joined() + frame.detailRaw.map { String(format: " %.6f", $0) }.joined()
        }
        return line
    }

    public static func noteLine(_ text: String) -> String { "# note " + text.replacingOccurrences(of: "\n", with: " ") }

    public static func tapLine(_ time: Double) -> String { String(format: "T %.4f", time) }

    public static func header(frameRate: Double) -> String {
        String(format: "# streamdock-rhythm-trace v1 frameRate=%.3f", frameRate)
    }

    public init?(text: String) {
        var frameRate: Double?
        var frames: [FeatureFrame] = []
        var taps: [Double] = []
        var notes: [String] = []
        let weights = FeatureFrame.onsetWeights
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            switch fields.first {
            case "#":
                if fields.count > 1, fields[1] == "note" { notes.append(fields.dropFirst(2).joined(separator: " ")) }
                if let field = fields.first(where: { $0.hasPrefix("frameRate=") }) {
                    frameRate = Double(field.dropFirst("frameRate=".count))
                }
            case "F":
                var values = fields.dropFirst().compactMap { Double($0) }
                let details = FeatureExtractor.detailEdges.count
                // Energy came later: traces without it have 10 or 10 + details values.
                var energy = Bands()
                if values.count == 13 || values.count == 13 + 2 * details {
                    energy = Bands(low: values[10], mid: values[11], high: values[12])
                    values.removeSubrange(10..<13)
                }
                guard values.count == 7 || values.count == 10 || values.count == 10 + 2 * details else { continue }
                let flux = Bands(low: values[1], mid: values[2], high: values[3])
                let raw = values.count >= 10 ? Bands(low: values[7], mid: values[8], high: values[9]) : nil
                var frame = FeatureFrame(
                    time: values[0], flux: flux, rawFlux: raw,
                    onset: weights.low * flux.low + weights.mid * flux.mid + weights.high * flux.high,
                    loudness: Bands(low: values[4], mid: values[5], high: values[6])
                )
                frame.energy = energy
                if values.count == 10 + 2 * details {
                    frame.detail = Array(values[10..<(10 + details)])
                    frame.detailRaw = Array(values[(10 + details)...])
                }
                frames.append(frame)
            case "T":
                if fields.count > 1, let time = Double(fields[1]) { taps.append(time) }
            default:
                continue
            }
        }
        guard let frameRate else { return nil }
        self.frameRate = frameRate
        self.frames = frames
        self.taps = taps
        self.notes = notes
    }

    /// Runs the analyzer over the frames: the beat grid (expected beats while locked), the
    /// accents, and every event and snapshot for closer inspection.
    public func replay() -> (beats: [Double], accents: [Double], events: [(Double, RhythmEvent)], snapshots: [(Double, RhythmSnapshot)]) {
        let analyzer = RhythmAnalyzer(frameRate: frameRate)
        var beats: [Double] = [], accents: [Double] = []
        var events: [(Double, RhythmEvent)] = []
        var snapshots: [(Double, RhythmSnapshot)] = []
        for frame in frames {
            for event in analyzer.process(frame) {
                events.append((frame.time, event))
                switch event {
                case .expectedBeat(let time): beats.append(time)
                case .accent(let time, _): accents.append(time)
                case .hit, .kick, .lift: break
                }
            }
            snapshots.append((frame.time, analyzer.snapshot))
        }
        return (beats.sorted(), accents.sorted(), events, snapshots)
    }
}

/// Accuracy of event times (beats or accents) against tapped times, MIREX-style.
public struct RhythmEvaluation: Sendable {
    /// Constant offset between taps and the system's beats (people tap a little early or late).
    public let tapOffset: Double
    /// F-measure with ±70 ms tolerance after removing the offset.
    public let fMeasure: Double
    public let precision: Double
    public let recall: Double
    /// F-measure if the system ran at double or half the tapped tempo.
    public let fMeasureDouble: Double
    public let fMeasureHalf: Double

    public static let tolerance = 0.07

    public init(beats: [Double], taps: [Double]) {
        let span = (taps.first ?? 0)...(taps.last ?? 0)
        let beatsInSpan = beats.filter { $0 >= span.lowerBound - Self.tolerance && $0 <= span.upperBound + Self.tolerance }

        // Offset: median of (beat − nearest tap) for beats within a third of a beat of a tap.
        let interval = taps.count > 1 ? (taps.last! - taps.first!) / Double(taps.count - 1) : 0.5
        let differences = beatsInSpan.compactMap { beat -> Double? in
            guard let nearest = taps.min(by: { abs($0 - beat) < abs($1 - beat) }), abs(nearest - beat) < interval / 3 else { return nil }
            return beat - nearest
        }.sorted()
        let offset = differences.isEmpty ? 0 : differences[differences.count / 2]
        tapOffset = offset
        let shifted = taps.map { $0 + offset }

        (fMeasure, precision, recall) = Self.score(beats: beatsInSpan, references: shifted)
        let doubled = shifted + zip(shifted, shifted.dropFirst()).map { ($0 + $1) / 2 }
        fMeasureDouble = Self.score(beats: beatsInSpan, references: doubled.sorted()).f
        let halved = shifted.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        fMeasureHalf = Self.score(beats: beatsInSpan, references: halved).f
    }

    /// Greedy one-to-one matching within the tolerance.
    static func score(beats: [Double], references: [Double]) -> (f: Double, precision: Double, recall: Double) {
        guard !beats.isEmpty, !references.isEmpty else { return (0, 0, 0) }
        var used = Set<Int>()
        var matched = 0
        for beat in beats {
            if let index = references.indices.filter({ !used.contains($0) && abs(references[$0] - beat) <= tolerance })
                .min(by: { abs(references[$0] - beat) < abs(references[$1] - beat) }) {
                used.insert(index)
                matched += 1
            }
        }
        let precision = Double(matched) / Double(beats.count)
        let recall = Double(matched) / Double(references.count)
        let f = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
        return (f, precision, recall)
    }
}
