import Foundation
import Testing
@testable import RhythmKit

/// Synthetic feature frames: per-band flux with hits at given times over a noise floor.
private struct Score {
    var frameRate = 48_000.0 / 512
    var hits: [(time: Double, band: Bands.Band, strength: Double)] = []
    var duration: Double
    var noise = 0.6

    func frames(seed: UInt64 = 1) -> [FeatureFrame] {
        var generator = SeededGenerator(seed: seed)
        let count = Int(duration * frameRate)
        var flux = [Bands](repeating: Bands(), count: count)
        for index in 0..<count {
            flux[index] = Bands(
                low: noise * Double.random(in: 0.5...1.5, using: &generator),
                mid: noise * Double.random(in: 0.5...1.5, using: &generator),
                high: noise * Double.random(in: 0.5...1.5, using: &generator)
            )
        }
        for hit in hits {
            let index = Int((hit.time * frameRate).rounded())
            guard index < count else { continue }
            // A short attack + decay, peaking at the hit.
            for (offset, scale) in [(0, 1.0), (1, 0.45), (2, 0.2)] where index + offset < count {
                flux[index + offset][hit.band] += hit.strength * scale
            }
        }
        let weights = FeatureFrame.onsetWeights
        return flux.enumerated().map { index, bands in
            FeatureFrame(
                time: Double(index) / frameRate,
                flux: bands,
                onset: weights.low * bands.low + weights.mid * bands.mid + weights.high * bands.high,
                loudness: Bands(low: 0.5, mid: 0.5, high: 0.5)
            )
        }
    }

    static func steady(bpm: Double, from start: Double = 0, to end: Double, band: Bands.Band = .low, strength: Double = 6) -> [(Double, Bands.Band, Double)] {
        stride(from: start, to: end, by: 60 / bpm).map { ($0, band, strength) }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

private struct Run {
    var events: [(frameTime: Double, event: RhythmEvent)] = []
    var snapshots: [(time: Double, snapshot: RhythmSnapshot)] = []

    init(_ frames: [FeatureFrame]) {
        let analyzer = RhythmAnalyzer(frameRate: 48_000.0 / 512)
        for frame in frames {
            for event in analyzer.process(frame) { events.append((frame.time, event)) }
            snapshots.append((frame.time, analyzer.snapshot))
        }
    }

    func snapshot(at time: Double) -> RhythmSnapshot {
        snapshots.last { $0.time <= time }!.snapshot
    }

    func expectedBeats(after start: Double, before end: Double = .infinity) -> [Double] {
        events.compactMap {
            if case .expectedBeat(let time) = $0.event, time >= start, time < end { return time }
            return nil
        }
    }
}

/// Distance from each time to the nearest of `targets`.
private func errors(_ times: [Double], to targets: [Double]) -> [Double] {
    times.map { time in targets.map { abs($0 - time) }.min() ?? .infinity }
}

@Suite struct RhythmAnalyzerTests {
    @Test func locksOntoSteadyBeat() {
        let beats = Score.steady(bpm: 120, to: 30)
        let run = Run(Score(hits: beats, duration: 30).frames())
        let late = run.snapshot(at: 29)
        #expect(late.state == .locked)
        #expect(abs((late.bpm ?? 0) - 120) < 2.4, "bpm \(late.bpm ?? 0)")

        // Only where real beats exist (the last hit is at 29.5 s).
        let predicted = run.expectedBeats(after: 15, before: 29.6)
        #expect(predicted.count >= 25)
        let worst = errors(predicted, to: beats.map(\.0)).max() ?? .infinity
        #expect(worst < 0.035, "worst beat error \(worst)")
    }

    @Test func prefersTheBeatOverTheBar() {
        // Kick on 1 and 3, snare on 2 and 4 at 120 BPM: the beat is 0.5 s, not 1 s.
        let kicks = stride(from: 0.0, to: 30, by: 1.0).map { ($0, Bands.Band.low, 6.0) }
        let snares = stride(from: 0.5, to: 30, by: 1.0).map { ($0, Bands.Band.mid, 5.0) }
        let run = Run(Score(hits: kicks + snares, duration: 30).frames())
        let bpm = run.snapshot(at: 29).bpm ?? 0
        #expect(abs(bpm - 120) < 2.4, "bpm \(bpm)")
    }

    @Test func followsATempoChange() {
        let first = Score.steady(bpm: 120, to: 20)
        let second = Score.steady(bpm: 90, from: 20, to: 45)
        let run = Run(Score(hits: first + second, duration: 45).frames())
        let late = run.snapshot(at: 44)
        #expect(late.state == .locked)
        #expect(abs((late.bpm ?? 0) - 90) < 1.8, "bpm \(late.bpm ?? 0)")
        let worst = errors(run.expectedBeats(after: 35, before: 44.9), to: second.map(\.0)).max() ?? .infinity
        #expect(worst < 0.04, "worst beat error \(worst)")
    }

    @Test func standsDownInACalmPassage() {
        // 20 s of beats, 20 s of smooth sound, 15 s of beats again.
        let hits = Score.steady(bpm: 120, to: 20) + Score.steady(bpm: 120, from: 40, to: 55)
        let run = Run(Score(hits: hits, duration: 55).frames())
        #expect(run.snapshot(at: 19).state == .locked)

        let calm = run.snapshot(at: 30)
        #expect(calm.state == .calm)
        #expect(calm.intensity < 0.1, "intensity \(calm.intensity)")
        #expect(run.expectedBeats(after: 26, before: 40).isEmpty)

        let back = run.snapshot(at: 54)
        #expect(back.state != .calm)
        #expect(back.intensity > 0.6, "intensity \(back.intensity)")
    }

    @Test func accentsAreTheStrongestHitsOnOrOffTheGrid() {
        // Light kicks on every beat, heavy kicks on every 4th, and a strong syncopated snare
        // a quarter-beat after every 3rd bar line — off the grid.
        var hits: [(Double, Bands.Band, Double)] = []
        var heavy: [Double] = [], light: [Double] = [], syncopated: [Double] = []
        for (index, time) in stride(from: 0.0, to: 40, by: 0.5).enumerated() {
            if index.isMultiple(of: 4) {
                hits.append((time, .low, 9)); heavy.append(time)
            } else {
                hits.append((time, .low, 3)); light.append(time)
            }
            if index % 12 == 6 {
                hits.append((time + 0.125, .mid, 10)); syncopated.append(time + 0.125)
            }
        }
        let run = Run(Score(hits: hits, duration: 40).frames())
        let accents = run.events.compactMap { entry -> Double? in
            if case .accent(let time, _) = entry.event, time > 10 { return time }
            return nil
        }
        let near = { (targets: [Double]) in accents.filter { a in targets.contains { abs($0 - a) < 0.03 } }.count }
        let strong = heavy.filter { $0 > 10 } + syncopated.filter { $0 > 10 }
        #expect(Double(near(heavy + syncopated)) >= 0.9 * Double(strong.count), "accents on strong hits: \(near(heavy + syncopated)) of \(strong.count)")
        #expect(near(syncopated) >= syncopated.filter { $0 > 10 }.count - 1, "syncopated accents: \(near(syncopated))")
        #expect(Double(near(light)) <= 0.1 * Double(light.filter { $0 > 10 }.count), "accents on light kicks: \(near(light))")
    }

    @Test func kickAndSnareTogetherAreOneAccent() {
        // Every beat: a kick, and 20 ms later a snare — one strike, not two.
        let beats = stride(from: 0.0, to: 30, by: 0.5)
        let hits = beats.flatMap { [($0, Bands.Band.low, 6.0), ($0 + 0.02, Bands.Band.mid, 6.0)] }
            + stride(from: 0.25, to: 30, by: 0.5).map { ($0, Bands.Band.low, 2.5) }
        let run = Run(Score(hits: hits, duration: 30).frames())
        let accents = run.events.compactMap { entry -> Double? in
            if case .accent(let time, _) = entry.event, time > 10 { return time }
            return nil
        }
        let gaps = zip(accents, accents.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 >= 0.15 }, "accents closer than 150 ms: \(gaps.filter { $0 < 0.15 })")
    }
}

@Suite struct RhythmEvaluationTests {
    @Test func scoresPerfectAndOffsetTapsAsPerfect() {
        let beats = stride(from: 0.0, to: 20, by: 0.5).map { $0 }
        #expect(RhythmEvaluation(beats: beats, taps: beats).fMeasure == 1)
        // Someone tapping 40 ms late is still perfectly in time once the offset is removed.
        let late = RhythmEvaluation(beats: beats, taps: beats.map { $0 + 0.04 })
        #expect(abs(late.tapOffset + 0.04) < 1e-9)
        #expect(late.fMeasure == 1)
    }

    @Test func reportsDoubleTempo() {
        let taps = stride(from: 0.0, to: 20, by: 1.0).map { $0 }
        let beats = stride(from: 0.0, to: 20, by: 0.5).map { $0 }
        let evaluation = RhythmEvaluation(beats: beats, taps: taps)
        #expect(evaluation.fMeasure < 0.8)
        #expect(evaluation.fMeasureDouble > 0.95)
    }

    @Test func roundTripsThroughText() {
        var trace = RhythmTrace(frameRate: 93.75)
        let frame = FeatureFrame(time: 12.3456, flux: Bands(low: 1.5, mid: 0.25, high: 2), onset: 0, loudness: Bands(low: 0.5, mid: 0.4, high: 0.3))
        let text = [RhythmTrace.header(frameRate: 93.75), RhythmTrace.frameLine(frame), RhythmTrace.tapLine(12.5)].joined(separator: "\n")
        trace = RhythmTrace(text: text)!
        #expect(trace.frames.count == 1)
        #expect(trace.taps == [12.5])
        #expect(abs(trace.frames[0].onset - (1.5 + 0.8 * 0.25 + 0.5 * 2)) < 1e-9)
    }
}
