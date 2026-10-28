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

@Suite struct LowEndTests {
    /// A bass that keeps playing keeps drawing (the held part); a kick rising out of it draws
    /// fully; a passage with little low end lets go.
    @Test func bassHoldsAndKicksDraw() {
        var draw = LowDraw()
        var time = 0.0
        for _ in 0..<600 { time += 0.01; draw.push(time: time, level: 0.45) }
        #expect(abs(draw.value - LowDraw.heldMost) < 0.02, "bass \(draw.value)")
        #expect(draw.rising < 0.05, "nothing rises out of it \(draw.rising)")
        time += 0.01
        draw.push(time: time, level: 0.95)
        #expect(draw.value > 0.9, "kick \(draw.value)")
        for _ in 0..<300 { time += 0.01; draw.push(time: time, level: 0.05) }
        #expect(draw.held < 0.01, "quiet \(draw.held)")
    }

    /// Kicks over a quiet low end draw on each hit but do not hold it: the median under them
    /// stays low.
    @Test func kicksAloneDoNotHold() {
        var draw = LowDraw()
        var time = 0.0, peaks: [Double] = [], between: [Double] = []
        for frame in 0..<1000 {
            time += 0.01
            let kick = frame % 50 < 5   // a 50 ms kick every half second
            draw.push(time: time, level: kick ? 1 : 0.05)
            if frame > 600 { (kick ? { peaks.append(draw.value) } : { between.append(draw.value) })() }
        }
        #expect(peaks.max()! > 0.9)
        #expect(draw.held < 0.01 && between.max()! < 0.05, "held \(draw.held)")
    }

    /// Dense hi-hats — 16 a second, 32nds at 120 BPM — are each heard, so the glints get as
    /// dense as they are.
    @Test func denseHighHitsAreEachHeard() {
        let hats = Score.steady(bpm: 960, to: 12, band: .high, strength: 6)
        let run = Run(Score(hits: hats.map { (time: $0.0, band: $0.1, strength: $0.2) }, duration: 12).frames())
        let heard = run.events.filter { if case .lift(let time, .high, _, _) = $0.event { time > 4 } else { false } }.count
        let played = hats.filter { $0.0 > 4 && $0.0 < 11.8 }.count
        #expect(Double(heard) >= 0.9 * Double(played), "heard \(heard) of \(played)")
    }

    /// A low band holding next to nothing of the mix — a chord's leak, a chime's spill — does not
    /// draw, however it moves against itself; one holding most of it draws as before.
    @Test func faintLowEndDoesNotDraw() {
        func drawn(lowShare: Double) -> Double {
            var draw = LowDraw()
            var time = 0.0
            for _ in 0..<600 { time += 0.01; draw.push(time: time, level: 0.45, share: lowShare) }
            time += 0.01
            draw.push(time: time, level: 0.95, share: lowShare)
            return draw.value
        }
        #expect(drawn(lowShare: 0.03) < 0.01)
        #expect(drawn(lowShare: 0.9) > 0.9)
    }

    /// A hit counts only as a real part of its band: in no band while it holds next to nothing of
    /// the mix; in the mid, not when it rises by a speck of what the band holds.
    @Test func faintSpillsAreNotHits() {
        var shares = BandShares(frameRate: 93.75)
        let bins = shares.binCounts
        // A steady mix: each band's energy level per bin — low next to nothing, mid 1, high 0.1.
        for _ in 0..<100 { shares.push(Bands(low: 1e-12 * bins.low, mid: bins.mid, high: 0.01 * bins.high)) }
        func hit(_ band: Bands.Band, rise: Double) -> Hit { Hit(time: 1, band: band, strength: 5, magnitude: rise) }
        #expect(!shares.counts(hit(.mid, rise: 0.05)), "a speck of the mid")
        #expect(shares.counts(hit(.mid, rise: 0.8)), "a real mid hit")
        #expect(!shares.counts(hit(.low, rise: 1)), "a band holding nothing")
        #expect(shares.counts(hit(.high, rise: 0.001)), "a high hit in a band that holds something")
    }

    /// Only the heaviest kicks of the last seconds count, sized against the big ones.
    @Test func onlyHeavyKicksBurn() {
        var kicks = HeavyHits()
        var fired: [(beat: Int, strength: Double)] = []
        for beat in 0..<40 {
            let heavy = beat % 4 == 0
            if let strength = kicks.push(time: Double(beat) * 0.5, size: heavy ? 1.0 : 0.3) { fired.append((beat, strength)) }
        }
        // Every heavy kick once ranking has enough history (8 s), never a light one.
        #expect(fired.count >= 5, "fired at \(fired.map(\.beat))")
        #expect(fired.allSatisfy { $0.beat % 4 == 0 && $0.strength > 0.9 }, "\(fired)")
    }

    /// Near-equal hits rank together: a backbeat of snares a few percent apart over lighter hits
    /// is heavy throughout, not only where one came out a hair bigger.
    @Test func equalHitsRankTogether() {
        var hits = HeavyHits()
        var heavy = 0, snares = 0
        for beat in 0..<40 {
            let time = Double(beat) * 0.5
            let snare = beat % 2 == 1
            let size = snare ? 0.95 + 0.05 * Double(beat % 3) / 2 : 0.4
            if hits.push(time: time, size: size) != nil, time > 8 { heavy += snare ? 1 : 100 }
            if snare, time > 8 { snares += 1 }
        }
        #expect(heavy >= snares - 1 && heavy < 100, "heavy snares \(heavy % 100) of \(snares), light ones \(heavy / 100)")
    }

    /// Each band stands on its own: a snare landing with a kick lifts, and the kick under it
    /// still counts as a kick — nothing is held back to tell one from the other.
    @Test func bandsStandOnTheirOwn() {
        // Kicks every beat, every eighth heavy (only the heaviest count as kicks).
        let kicks = Score.steady(bpm: 60, to: 30, band: .low, strength: 3) + Score.steady(bpm: 7.5, to: 30, band: .low, strength: 9)
        let snares = Score.steady(bpm: 60, to: 30, band: .mid, strength: 6)   // with every kick
        let run = Run(Score(hits: (kicks + snares).map { (time: $0.0, band: $0.1, strength: $0.2) }, duration: 30).frames())
        var lifts = 0, kicked = 0
        for (_, event) in run.events {
            switch event {
            case .lift(let time, .mid, _, _) where time > 8: lifts += 1
            case .kick(let time, _) where time > 8: kicked += 1
            default: break
            }
        }
        #expect(lifts >= 20, "snares lifted: \(lifts) of 22")
        #expect(kicked >= 2, "heavy kicks under them: \(kicked) of 3")
    }

    /// The rolling window gives exactly the percentiles of sorting its values each time.
    @Test func rollingWindowMatchesSorting() {
        var generator = SeededGenerator(seed: 7)
        var window = RollingWindow(seconds: 6)
        var plain: [(time: Double, value: Double)] = []
        for step in 0..<3000 {
            let time = Double(step) / 94
            let value = Double(Int.random(in: 0..<50, using: &generator)) / 10   // with repeats
            window.push(time: time, value: value)
            plain.append((time, value))
            plain.removeAll { $0.time < time - 6 }
            let sorted = plain.map(\.value).sorted()
            for fraction in [0, 0.2, 0.5, 0.9, 0.95, 1] {
                #expect(window.percentile(fraction) == sorted[Int(Double(sorted.count - 1) * fraction)])
            }
        }
    }

    /// Detail bands and the note survive the trace format.
    @Test func detailBandsRoundTrip() {
        var frame = FeatureFrame(time: 1.5, flux: Bands(low: 1, mid: 2, high: 3), onset: 0, loudness: Bands())
        frame.detail = [1, 2, 3, 4, 5]
        frame.detailRaw = [0.1, 0.2, 0.3, 0.4, 0.5]
        let text = [RhythmTrace.header(frameRate: 93.75), RhythmTrace.noteLine("Song – Artist | at uptime 10.000 the track was 3.00 s in"), RhythmTrace.frameLine(frame)].joined(separator: "\n")
        let trace = RhythmTrace(text: text)!
        #expect(trace.frames.first?.detail == [1, 2, 3, 4, 5] && trace.frames.first?.detailRaw == [0.1, 0.2, 0.3, 0.4, 0.5])
        #expect(trace.notes == ["Song – Artist | at uptime 10.000 the track was 3.00 s in"])
    }
}
