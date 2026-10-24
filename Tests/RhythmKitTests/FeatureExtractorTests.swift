import Foundation
import Testing
@testable import RhythmKit

@Suite struct FeatureExtractorTests {
    /// 60 Hz bursts every 0.5 s over quiet noise: low-band hits land on the bursts.
    @Test func findsLowBandHitsOnKickLikeBursts() {
        let sampleRate = 48_000.0
        let duration = 8.0
        var generator = SystemRandomNumberGenerator()
        var samples = (0..<Int(sampleRate * duration)).map { _ in Float.random(in: -0.002...0.002, using: &generator) }
        let bursts = stride(from: 1.0, to: duration, by: 0.5).map { $0 }
        for start in bursts {
            let first = Int(start * sampleRate)
            for index in first..<min(samples.count, first + Int(0.15 * sampleRate)) {
                let t = Double(index - first) / sampleRate
                samples[index] += Float(0.8 * exp(-t * 25) * sin(2 * .pi * 60 * t))
            }
        }

        let extractor = FeatureExtractor(sampleRate: sampleRate)
        var frames: [FeatureFrame] = []
        // Feed in 512-sample chunks like the audio tap does; time = end of each chunk.
        for start in stride(from: 0, to: samples.count, by: 512) {
            let chunk = Array(samples[start..<min(samples.count, start + 512)])
            let endTime = Double(start + chunk.count) / sampleRate
            frames += chunk.withUnsafeBufferPointer { extractor.process($0, endTime: endTime) }
        }

        var picker = PeakPicker(band: .low, frameRate: extractor.frameRate, minimumInterval: 0.08)
        let hits = frames.compactMap { picker.push(time: $0.time, value: $0.flux.low) }.map(\.time)
        // Skip the first second while the scales settle.
        let expected = bursts.filter { $0 >= 2 }
        let found = hits.filter { $0 >= 1.9 }
        #expect(found.count >= expected.count - 1, "found \(found.count) of \(expected.count)")
        for burst in expected {
            let nearest = found.map { abs($0 - burst) }.min() ?? .infinity
            // A frame ends ~11–21 ms after its burst begins; allow two hops.
            #expect(nearest < 0.03, "burst at \(burst): nearest hit \(nearest)")
        }
    }
}

@Suite struct StartupTests {
    /// Playback starting from silence must not flood the first seconds with accents.
    @Test func noAccentFloodWhenPlaybackStarts() {
        let sampleRate = 48_000.0
        let duration = 12.0
        var generator = SystemRandomNumberGenerator()
        // Music-like bed (noise) from t = 0, plus a kick every 0.5 s.
        var samples = (0..<Int(sampleRate * duration)).map { _ in Float.random(in: -0.05...0.05, using: &generator) }
        for start in stride(from: 0.25, to: duration, by: 0.5) {
            let first = Int(start * sampleRate)
            for index in first..<min(samples.count, first + Int(0.15 * sampleRate)) {
                let t = Double(index - first) / sampleRate
                samples[index] += Float(0.8 * exp(-t * 25) * sin(2 * .pi * 60 * t))
            }
        }
        let extractor = FeatureExtractor(sampleRate: sampleRate)
        let analyzer = RhythmAnalyzer(frameRate: extractor.frameRate)
        var accents: [Double] = []
        for start in stride(from: 0, to: samples.count, by: 512) {
            let chunk = Array(samples[start..<min(samples.count, start + 512)])
            let frames = chunk.withUnsafeBufferPointer { extractor.process($0, endTime: Double(start + chunk.count) / sampleRate) }
            for frame in frames {
                for event in analyzer.process(frame) {
                    if case .accent(let time, _) = event { accents.append(time) }
                }
            }
        }
        // 2 kicks per second, top 30 % → about 0.6 accents per second; allow up to 1.2.
        let early = accents.filter { $0 < 6 }
        #expect(early.count <= 7, "accents in the first 6 s: \(early.count) at \(early.map { String(format: "%.2f", $0) })")
        // And they should be on the kicks.
        let offKick = accents.filter { time in abs((time - 0.25) / 0.5 - ((time - 0.25) / 0.5).rounded()) * 0.5 > 0.04 }
        #expect(offKick.count <= 1, "accents off the kicks: \(offKick.map { String(format: "%.2f", $0) })")
    }
}

@Suite struct AdaptiveScaleTests {
    /// From the very first samples the mean tracks the data instead of creeping up from zero.
    @Test func meanIsUnbiasedFromTheStart() {
        var scale = AdaptiveScale(.mean, seconds: 10, floor: 1e-3)
        var normalized: [Double] = []
        for index in 0..<200 {   // ~2 s at 94 Hz
            normalized.append(scale.normalize(index.isMultiple(of: 2) ? 1.5 : 0.5, dt: 0.0107))
        }
        let late = normalized.suffix(100)
        let mean = late.reduce(0, +) / Double(late.count)
        #expect(abs(mean - 1) < 0.1, "mean normalised value \(mean)")
        #expect(normalized.max()! < 3, "largest normalised value \(normalized.max()!)")
    }
}

@Suite struct LoudnessTests {
    /// Through the real feature pipeline: a quiet passage's accents must come out smaller
    /// than a loud passage's, even after the per-band flux scales have adapted to it.
    @Test func quietPassageAccentsAreSmallerThroughTheWholePipeline() {
        let sampleRate = 48_000.0
        let duration = 50.0
        var generator = SystemRandomNumberGenerator()
        var samples = [Float](repeating: 0, count: Int(sampleRate * duration))
        for index in samples.indices {
            let loud = Double(index) / sampleRate < 25
            samples[index] = Float.random(in: -0.02...0.02, using: &generator) * (loud ? 1 : 0.3)
        }
        for (count, start) in stride(from: 0.25, to: duration, by: 0.5).enumerated() {
            let loud = start < 25
            let amplitude = (count.isMultiple(of: 4) ? 0.9 : 0.5) * (loud ? 1 : 0.3)
            let first = Int(start * sampleRate)
            for index in first..<min(samples.count, first + Int(0.15 * sampleRate)) {
                let t = Double(index - first) / sampleRate
                samples[index] += Float(amplitude * exp(-t * 25) * sin(2 * .pi * 60 * t))
            }
        }
        let extractor = FeatureExtractor(sampleRate: sampleRate)
        let analyzer = RhythmAnalyzer(frameRate: extractor.frameRate)
        var accents: [(time: Double, strength: Double)] = []
        for start in stride(from: 0, to: samples.count, by: 512) {
            let chunk = Array(samples[start..<min(samples.count, start + 512)])
            let frames = chunk.withUnsafeBufferPointer { extractor.process($0, endTime: Double(start + chunk.count) / sampleRate) }
            for frame in frames {
                for event in analyzer.process(frame) {
                    if case .accent(let time, let strength) = event { accents.append((time, strength)) }
                }
            }
        }
        let loud = accents.filter { $0.time > 10 && $0.time < 25 }.map(\.strength)
        let quiet = accents.filter { $0.time > 37 }.map(\.strength)
        #expect(!loud.isEmpty && !quiet.isEmpty)
        let loudMean = loud.reduce(0, +) / Double(max(1, loud.count))
        let quietMean = quiet.reduce(0, +) / Double(max(1, quiet.count))
        #expect(quietMean < 0.6 * loudMean, "loud \(loudMean) quiet \(quietMean)")
    }
}

@Suite struct KickTests {
    /// The pattern behind kicks reading as light beats (from a real song): over a bass line the
    /// kick's log flux is only moderate, a snare's is high, yet the kick is ten times harder.
    /// Accents must follow how hard a hit is, measured per band against that band's big hits.
    @Test func kicksAreAccentsNotLightBeats() {
        var salience = SalienceDetector()
        var kickAccents = 0, snareAccents = 0, otherAccents = 0
        var kickStrengths: [Double] = []
        for beat in 0..<80 {
            let t = Double(beat) * 0.5
            let isKick = beat.isMultiple(of: 2)
            let hits = [
                isKick ? Hit(time: t, band: .low, strength: 8, magnitude: 0.03)
                       : Hit(time: t, band: .mid, strength: 11, magnitude: 0.003),
                Hit(time: t + 0.25, band: .low, strength: 4, magnitude: 0.015),   // bass note
            ]
            for hit in hits {
                guard let accent = salience.push(hit), t >= 8 else { continue }
                if hit.magnitude == 0.03 {
                    kickAccents += 1
                    kickStrengths.append(accent.strength)
                } else if hit.magnitude == 0.003 {
                    snareAccents += 1
                } else {
                    otherAccents += 1
                }
            }
        }
        // 32 kicks after 8 s.
        #expect(kickAccents >= 28, "kick accents \(kickAccents), snare \(snareAccents), other \(otherAccents)")
        #expect(snareAccents + otherAccents <= 2, "kick accents \(kickAccents), snare \(snareAccents), other \(otherAccents)")
        #expect(kickStrengths.allSatisfy { $0 > 0.9 }, "kick strengths \(kickStrengths)")
    }
}
