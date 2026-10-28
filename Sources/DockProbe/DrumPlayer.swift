import AVFoundation

/// One drum hit of a scripted pattern, `time` seconds in.
struct DrumHit {
    enum Kind { case kick, snare, hat(accent: Bool), chime(pitch: Double), bass(pitch: Double), pad(pitches: [Double]) }
    let time: Double
    let kind: Kind

    /// A chime's notes: a pentatonic run from about 6.3 to 10.6 kHz, above the mid band's top
    /// (6 kHz), as tiny bells and wind-chime rods ring.
    static let chimeNotes = [7040.0, 7902, 9397, 10548, 11840]
    /// Held chords for a plain mid sound under the rest: C, Am, F, G.
    static let chords: [[Double]] = [[261.6, 329.6, 392], [220, 261.6, 329.6], [174.6, 220, 261.6], [196, 246.9, 293.7]]
}

/// Plays a drum script, synthesised: a kick (a pitch-dropping sine thump), a snare (a short tone
/// under a burst of bright noise) and a hi-hat (a tick of noise above ~7 kHz, as a real one sits,
/// with a 1 ms onset: a raw noise click reaches every band, down to the kick's — 2026-10-28) and
/// a chime (a small bell or wind-chime rod: a high tone and its overtones, ringing out) and a bass
/// note (a held low tone with a little of its octave, half a second). Rendered whole up front
/// and played from time 0, so a light driven by the same script lines up with it.
final class DrumPlayer {
    static let sampleRate = 48_000.0
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer
    /// The whole rendering, for listening to it as it plays.
    let samples: [Float]

    init(script: [DrumHit], duration: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(duration * Self.sampleRate)
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        var noise = SystemRandomNumberGenerator()
        for hit in script {
            let first = Int(hit.time * Self.sampleRate)
            let length = Int(hit.kind.seconds * Self.sampleRate)
            var phase = 0.0, previous = 0.0
            var hatFilter = (HighPass(cutoff: 7000, sampleRate: Self.sampleRate), HighPass(cutoff: 7000, sampleRate: Self.sampleRate))
            for n in 0..<length where first + n < Int(frames) {
                let t = Double(n) / Self.sampleRate
                let white = Double.random(in: -1...1, using: &noise)
                let bright = white - previous   // a first difference: the noise's highs
                previous = white
                var sample = 0.0
                switch hit.kind {
                case .kick:
                    phase += 2 * .pi * (45 + 90 * exp(-t / 0.035)) / Self.sampleRate
                    sample = 0.9 * sin(phase) * exp(-t / 0.22)
                case .snare:
                    phase += 2 * .pi * 190 / Self.sampleRate
                    sample = 0.35 * sin(phase) * exp(-t / 0.07) + 0.35 * bright * exp(-t / 0.11)
                case .pad(let pitches):
                    // A held chord, two seconds, swelling in and out over 0.3 s (no strike).
                    let swell = min(1, t / 0.3, max(0, (2.1 - t) / 0.3))
                    sample = swell * 0.08 * pitches.reduce(0.0) { $0 + sin(2 * .pi * $1 * t) + 0.3 * sin(4 * .pi * $1 * t) }
                case .bass(let pitch):
                    let envelope = min(1, t / 0.01) * (t < 0.45 ? 1 : max(0, 1 - (t - 0.45) / 0.04))
                    sample = envelope * (0.45 * sin(2 * .pi * pitch * t) + 0.15 * sin(4 * .pi * pitch * t))
                case .chime(let pitch):
                    // A free bar's modes (1, 2.76, 5.40) — the overtones above hearing are left out —
                    // struck (0.5 ms onset), the higher ones dying first.
                    let onset = min(1, t / 0.0005)
                    for (ratio, level, ring) in [(1.0, 0.12, 0.35), (2.76, 0.05, 0.12), (5.40, 0.025, 0.05)] where pitch * ratio < 20_000 {
                        sample += level * sin(2 * .pi * pitch * ratio * t) * exp(-t / ring) * onset
                    }
                case .hat(let accent):
                    let hiss = hatFilter.1.next(hatFilter.0.next(white))
                    sample = (accent ? 0.3 : 0.17) * hiss * min(1, t / 0.001) * exp(-t / 0.03)
                }
                out[first + n] += Float(sample)
            }
        }
        samples = Array(UnsafeBufferPointer(start: out, count: Int(frames)))
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
    }

    func play() {
        node.scheduleBuffer(buffer, at: nil)
        node.play()
    }

    func stop() {
        node.stop()
        engine.stop()
    }
}

extension DrumHit.Kind {
    /// How long one rings (the rendering's length per hit).
    var seconds: Double {
        switch self {
        case .chime: 1.2
        case .pad: 2.4
        default: 0.5
        }
    }
}

/// A second-order (Butterworth) high-pass, for the hi-hat's noise.
private struct HighPass {
    private let b0, b1, b2, a1, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(cutoff: Double, sampleRate: Double) {
        let w = 2 * Double.pi * cutoff / sampleRate, alpha = sin(w) / sqrt(2), a0 = 1 + alpha
        b0 = (1 + cos(w)) / 2 / a0
        b1 = -(1 + cos(w)) / a0
        b2 = b0
        a1 = -2 * cos(w) / a0
        a2 = (1 - alpha) / a0
    }

    mutating func next(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        (x2, x1, y2, y1) = (x1, x, y1, y)
        return y
    }
}
