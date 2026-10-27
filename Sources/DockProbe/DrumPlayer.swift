import AVFoundation

/// One drum hit of a scripted pattern, `time` seconds in.
struct DrumHit {
    enum Kind { case kick, snare, hat(accent: Bool) }
    let time: Double
    let kind: Kind
}

/// Plays a drum script, synthesised: a kick (a pitch-dropping sine thump), a snare (a short tone
/// under a burst of bright noise) and a hi-hat (a tick of high noise). Rendered whole up front
/// and played from time 0, so a light driven by the same script lines up with it.
final class DrumPlayer {
    static let sampleRate = 48_000.0
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer

    init(script: [DrumHit], duration: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(duration * Self.sampleRate)
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        var noise = SystemRandomNumberGenerator()
        for hit in script {
            let first = Int(hit.time * Self.sampleRate)
            let length = Int(0.5 * Self.sampleRate)
            var phase = 0.0, previous = 0.0
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
                case .hat(let accent):
                    sample = (accent ? 0.22 : 0.12) * bright * exp(-t / 0.03)
                }
                out[first + n] += Float(sample)
            }
        }
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
