import DockCore
import Foundation
import RhythmKit

/// A Sound Glow–style light show driven by RhythmKit events (see docs/rhythm.md). It makes no
/// rhythm decisions of its own; it only turns events into light:
///
/// - accent (one of the strongest hits right now, on the grid or not) → a flash that starts
///   at one blob and spreads along the ring — a heavy hit fills the ring, a light one stays
///   local — rising quickly but roundly and fading slowly, its peak lifting toward white;
/// - expected beat of the steady grid → a soft pulse of the whole ring peaking on the beat;
/// - high hit → a spark that fades in and out on one LED;
/// - intensity (how rhythmic the music is right now) and recent accents set how fast the blobs
///   drift — eased, never kicked, never reversed; a calm passage is just a slow drift of the
///   album's colors. Paused, it all settles into a slow, dim breath.
///
/// How bright each layer may get, how layers add up and how fast anything may change is
/// `GlowBudget`'s job alone; colors blend in OKLab (`OKLab`), and `LEDOutput` turns perceived
/// brightness into LED values.
///
/// Blobs move only along the ring (`LightLayout.ring`); the two short bars glow in the
/// album's main color and breathe with the beats.
@MainActor
final class MusicGlow: LightAnimation {
    /// This frame's rhythm input, or nil without live audio (then an idle drift plays).
    var rhythm: () -> (events: [RhythmEvent], snapshot: RhythmSnapshot)? = { nil }
    /// False while Music is paused: the glow eases into a slow breath and back.
    var playing = true
    var isActive: Bool { playing }

    private struct Blob {
        var position: Double
        /// Laps per second at speed factor 1; the sign is its direction, which never changes.
        let drift: Double
    }

    /// One accent's flash, spreading from `origin` (laps) toward `reach`.
    private struct Ripple {
        let origin: Double
        let reach: Double
        var age = 0.0
        var envelope = FlashEnvelope(attack: GlowBudget.accentAttack, decay: GlowBudget.accentDecay)
    }

    private var palette: [OKLab]
    private var previous: [OKLab]?
    private var paletteChanged: TimeInterval?

    private var blobs: [Blob] = [
        Blob(position: 0.00, drift: 0.09),
        Blob(position: 0.33, drift: -0.07),
        Blob(position: 0.66, drift: 0.12),
    ]
    private var lastTime: TimeInterval?
    /// Eased blob speed factor, and the accent surge feeding it.
    private var speed = GlowBudget.flowCalm
    private var surge = 0.0
    private var loudness: Double?
    private var intensity: Double?
    /// 1 while playing, 0 paused, eased between.
    private var presence = 1.0

    private var ripples: [Ripple] = []
    private var rippleCount = 0
    private var groove = FlashEnvelope(attack: GlowBudget.grooveAttack, decay: GlowBudget.grooveDecay)
    /// Expected beats waiting to be triggered so their pulse peaks on the beat.
    private var scheduled: [(peak: TimeInterval, amplitude: Double)] = []
    /// Per ring-slot sparks, each the same kind of envelope as the flashes.
    private var sparks: [FlashEnvelope] = []
    private var lastSpark: TimeInterval = -.infinity

    init(palette: [RGB]) {
        self.palette = palette.map(OKLab.init(srgb:))
    }

    func setPalette(_ newPalette: [RGB]) {
        let colors = newPalette.map(OKLab.init(srgb:))
        guard colors != palette else { return }
        previous = currentColors(at: lastTime ?? 0)
        palette = colors
        paletteChanged = lastTime
    }

    func pixels(at time: TimeInterval, ledCount: Int) -> [LightPixel] {
        frame(at: time, ledCount: ledCount, input: rhythm())
    }

    func frame(at time: TimeInterval, ledCount: Int, input: (events: [RhythmEvent], snapshot: RhythmSnapshot)?) -> [LightPixel] {
        let dt = min(0.1, max(0, time - (lastTime ?? time)))
        lastTime = time
        if paletteChanged == nil, previous != nil { paletteChanged = time }
        let ring = LightLayout.ring.filter { $0 < ledCount }
        if sparks.count != ring.count {
            sparks = Array(repeating: FlashEnvelope(attack: GlowBudget.sparkAttack, decay: GlowBudget.sparkDecay), count: ring.count)
        }

        presence = Self.ease(presence, toward: playing ? 1 : 0, dt: dt, over: playing ? GlowBudget.resumeEase : GlowBudget.pauseEase)
        let rawIntensity = (input?.snapshot.intensity ?? 0.3) * (playing ? 1 : 0)
        let intensity = Self.ease(self.intensity ?? rawIntensity, toward: rawIntensity, dt: dt, over: GlowBudget.intensityEase)
        self.intensity = intensity
        let rawLoudness = input?.snapshot.loudness.low ?? 0.3 + 0.15 * sin(2 * .pi * time / 3)
        let loudness = Self.ease(self.loudness ?? rawLoudness, toward: rawLoudness, dt: dt, over: GlowBudget.loudnessEase)
        self.loudness = loudness

        for event in input?.events ?? [] where playing {
            switch event {
            case .expectedBeat(let peak):
                scheduled.append((peak, GlowBudget.groove * intensity))
            case .accent(_, let strength):
                addRipple(size: GlowBudget.accent(strength: strength, intensity: intensity), strength: strength)
                surge += GlowBudget.surgeGain * strength * intensity
            case .hit(let hit) where hit.band == .high:
                addSpark(size: min(1, hit.strength / 6) * intensity, at: time, intensity: intensity)
            case .hit:
                break
            }
        }
        // Grid pulses are triggered early by the envelope's own delay, so they peak on the beat.
        for beat in scheduled where time >= beat.peak - groove.peakDelay {
            groove.trigger(beat.amplitude)
        }
        scheduled.removeAll { time >= $0.peak - groove.peakDelay }
        groove.advance(dt: dt)
        for index in ripples.indices {
            ripples[index].age += dt
            ripples[index].envelope.advance(dt: dt)
        }
        ripples.removeAll { $0.age > 0.5 && $0.envelope.level < 0.003 }
        for index in sparks.indices { sparks[index].advance(dt: dt) }

        // Flow: the speed eases toward what the music asks for; blobs keep their directions.
        surge *= exp(-dt / GlowBudget.surgeDecay)
        let active = GlowBudget.flowCalm + GlowBudget.flowRhythm * intensity + GlowBudget.flowSurge * min(1, surge)
        let wanted = GlowBudget.pauseFlow + (active - GlowBudget.pauseFlow) * presence
        speed = Self.ease(speed, toward: wanted, dt: dt, over: GlowBudget.flowEase)
        for index in blobs.indices {
            blobs[index].position += blobs[index].drift * speed * dt
            blobs[index].position -= floor(blobs[index].position)
        }

        let blobColors = currentColors(at: time)
        let anyAccent = ripples.reduce(0.0) { GlowBudget.screen($0, $1.envelope.level) }
        let base = GlowBudget.base(loudness: loudness, intensity: intensity)
        let pause = GlowBudget.pauseBrightness(at: time)
        let width = GlowBudget.blobWidth * (1 + 0.4 * loudness + 0.4 * anyAccent)

        var pixels = Array(repeating: LightPixel.black, count: ledCount)
        for (slot, led) in ring.enumerated() {
            let position = Double(slot) / Double(ring.count)
            let weights = blobs.map { blob -> Double in
                let distance = Self.ringDistance(position, blob.position) / width
                return exp(-distance * distance)
            }
            let shape = GlowBudget.blobProfile(weights.max() ?? 0)
            var color = OKLab.blend(blobColors, weights: weights.map { $0 + 1e-6 }, keepChroma: GlowBudget.keepChroma)

            let accent = ripples.reduce(0.0) { level, ripple in
                let reached = GlowBudget.spreadProfile(distance: Self.ringDistance(position, ripple.origin), reach: ripple.reach, age: ripple.age)
                return GlowBudget.screen(level, ripple.envelope.level * reached)
            }
            let playingLevel = GlowBudget.brightness(base: base, accent: accent, groove: groove.level)
            var level = (pause + (playingLevel - pause) * presence) * shape
            color = color.mixed(with: .white, amount: GlowBudget.bloom * accent * accent)

            // Sparks: neighbours at half strength, lifted toward white, screened on top.
            let spark = max(sparks[slot].level, 0.5 * sparks[(slot + 1) % ring.count].level, 0.5 * sparks[(slot + ring.count - 1) % ring.count].level)
            if spark > 0.005 {
                color = color.mixed(with: .white, amount: GlowBudget.sparkWhite * spark)
                level = GlowBudget.screen(level, GlowBudget.sparkSize * spark)
            }
            pixels[led] = LightPixel(channels: color.ledChannels, level: level)
        }

        // Short bars: the main album color; accents light them by how far they spread.
        let barAccent = ripples.reduce(0.0) { GlowBudget.screen($0, $1.envelope.level * min(1, $1.reach / 0.5)) }
        let barPlaying = GlowBudget.brightness(base: GlowBudget.barBase(loudness: loudness, intensity: intensity), accent: barAccent, groove: groove.level)
        let barLevel = pause * 0.8 + (barPlaying - pause * 0.8) * presence
        let barColor = blobColors[0].mixed(with: .white, amount: GlowBudget.bloom * barAccent * barAccent)
        for bar in [LightLayout.leftBar, LightLayout.rightBar] where bar < ledCount {
            pixels[bar] = LightPixel(channels: barColor.ledChannels, level: barLevel)
        }
        return pixels
    }

    /// A flash starting at the next blob in turn, so the light comes from the colors themselves.
    private func addRipple(size: Double, strength: Double) {
        guard size > 0.001 else { return }
        var ripple = Ripple(origin: blobs[rippleCount % blobs.count].position, reach: GlowBudget.reach(strength: strength))
        ripple.envelope.trigger(size)
        rippleCount += 1
        ripples.append(ripple)
        if ripples.count > 8 { ripples.removeFirst() }
    }

    /// A spark on a quiet LED, at most one per `sparkSpacing`, never right next to a lit one.
    private func addSpark(size: Double, at time: TimeInterval, intensity: Double) {
        guard intensity > 0.3, size > 0.05, time - lastSpark >= GlowBudget.sparkSpacing else { return }
        let count = sparks.count
        let quiet = sparks.indices.filter { slot in
            (-1...1).allSatisfy { sparks[(slot + $0 + count) % count].level < 0.15 }
        }
        guard let slot = quiet.randomElement() else { return }
        sparks[slot].trigger(size)
        lastSpark = time
    }

    /// Each blob's color, blending (in OKLab) from the previous album's during a change.
    private func currentColors(at time: TimeInterval) -> [OKLab] {
        let current = blobs.indices.map { palette[$0 % palette.count] }
        guard let previous, let start = paletteChanged else { return current }
        let fade = Self.smoothstep((time - start) / GlowBudget.paletteFade)
        if fade >= 1 {
            self.previous = nil
            return current
        }
        return blobs.indices.map { previous[$0 % previous.count].mixed(with: current[$0], amount: fade) }
    }

    /// One step of a one-pole low-pass with time constant `seconds`.
    private static func ease(_ value: Double, toward target: Double, dt: Double, over seconds: Double) -> Double {
        value + (target - value) * (1 - exp(-dt / seconds))
    }

    private static func ringDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    private static func smoothstep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }
}

/// Debug tooling: replays a rhythm trace through RhythmKit and this animation, so the light
/// show can be inspected offline (`dock-probe glowsim`).
@MainActor
public enum GlowReplay {
    /// Returns one line per rendered frame: "<time> <state> <accent 0/1> <#RRGGBB × ledCount>".
    public static func replay(trace: RhythmTrace, palette: [RGB], ledCount: Int = 24) -> [String] {
        let analyzer = RhythmAnalyzer(frameRate: trace.frameRate)
        let glow = MusicGlow(palette: palette)
        var output = LEDOutput()
        var lines: [String] = []
        var pending: [RhythmEvent] = []
        var nextRender = trace.frames.first?.time ?? 0
        for frame in trace.frames {
            pending += analyzer.process(frame)
            // Render at 30 fps like the app, handing over the events gathered since last time.
            guard frame.time >= nextRender else { continue }
            nextRender += 1.0 / 30
            let beat = pending.contains { event in
                if case .accent = event { return true }
                return false
            }
            let colors = output.render(glow.frame(at: frame.time, ledCount: ledCount, input: (pending, analyzer.snapshot)))
            pending.removeAll()
            lines.append(String(format: "%.3f %@ %d ", frame.time, analyzer.snapshot.state.rawValue, beat ? 1 : 0) + colors.map(\.hex).joined(separator: " "))
        }
        return lines
    }
}
