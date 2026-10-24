import Foundation

/// How MusicGlow spends its brightness, in one place. Every level is *perceived* brightness
/// 0...1 (`LEDOutput` turns it into LED drive with a gamma), and layers combine by *screen*
/// (1 − (1 − a)(1 − b)), the way overlapping light adds up: the result never exceeds 1, and
/// adding a layer always brightens — a new flash on top of a fading one is always visible.
///
///     brightness = base + (1 − base) · screen(accent, groove)     (per LED)
///
/// - base: the steady glow the music sits on — calm level, a little lower the more rhythmic
///   the passage (so flashes stand out), breathing with loudness;
/// - accent: flashes of the strongest hits, sized by RhythmKit (strength 1 → full brightness).
///   Each starts at one point of the ring and spreads: a heavy hit fills the whole ring, a
///   light one stays a local swell;
/// - groove: soft pulses on the expected beats of a steady grid, whole ring.
///
/// Color: blobs blend in OKLab; at a flash's peak the color lifts toward white (`bloom`), like
/// light spilling over. Paused, everything eases into a slow, dim breath (`pause*`).
///
/// Motion and texture have budgets too: the blobs' speed only ever eases (`flowEase`) toward
/// a target set by how rhythmic and how busy the music is, never kicked; loudness and
/// intensity are smoothed before they touch anything; sparks are the same envelope as the
/// flashes (`sparkAttack`, `sparkDecay`), spaced (`sparkSpacing`) and never next to a lit one.
struct GlowBudget {
    /// Base glow: `calm` with no rhythm, `dip` lower at full intensity, ± `breath` with loudness.
    static let calm = 0.6, dip = 0.15, breath = 0.1
    /// Accent flash size for strength s: (`accentFloor` + (1 − `accentFloor`)·s^`accentCurve`)·intensity.
    static let accentFloor = 0.15, accentCurve = 1.5
    /// Grid pulse size at full intensity.
    static let groove = 0.3
    /// The short bars: their own, dimmer base; accents light them by how far they spread.
    static let barCalm = 0.35, barBreath = 0.15

    /// Blob profile across the ring: perceived brightness from `blobFloor` between blobs to 1
    /// at a blob's center, `blobWidth` laps wide (growing with loudness and flashes).
    static let blobFloor = 0.2, blobCurve = 0.75, blobWidth = 0.12
    /// How much of the chroma an OKLab average loses between two hues is put back.
    static let keepChroma = 0.6
    /// At a flash's peak the color moves this far toward white.
    static let bloom = 0.35

    /// Accent spread: a strength-s accent reaches `reachMin` + `reachRange`·s^`reachCurve` laps
    /// (0.5 = the far side of the ring; a flat-topped profile, so ≥ 0.7 fills the whole ring),
    /// getting there with time constant `spread` seconds.
    static let reachMin = 0.1, reachRange = 0.65, reachCurve = 2.0, spread = 0.18

    /// Flash shapes (seconds): accents rise in ≈0.1 s and halve in ≈0.6 s; grid pulses softer.
    static let accentAttack = 0.035, accentDecay = 0.55
    static let grooveAttack = 0.07, grooveDecay = 0.45
    /// Blob speed factor: `flowCalm` with no rhythm, up to `flowCalm + flowRhythm` at full
    /// intensity, plus `flowSurge` per unit of recent accents; eased with time constant `flowEase`.
    static let flowCalm = 0.6, flowRhythm = 0.4, flowSurge = 0.5, flowEase = 1.2
    /// Recent-accent surge: each accent adds its strength · `surgeGain`, decaying over `surgeDecay`.
    static let surgeGain = 0.35, surgeDecay = 1.5
    static let loudnessEase = 0.35, intensityEase = 0.6
    /// Sparks: envelope shape (fade in ≈0.3 s, out over ≈0.5 s), least time between two, peak size,
    /// and how far toward white they lift the color.
    static let sparkAttack = 0.08, sparkDecay = 0.45, sparkSpacing = 0.12, sparkSize = 0.65, sparkWhite = 0.45
    /// Paused: a breath around the lowest base the music ever plays at (`playingFloor`, and
    /// `barCalm` for the bars) — the light stays, only the music's movement stops —
    /// ± `pauseBreath` every `pausePeriod` s, blobs at `pauseFlow` speed; eased in over
    /// `pauseEase` s and back out over `resumeEase` s.
    static let pauseBreath = 0.04, pausePeriod = 6.0, pauseFlow = 0.12
    static let pauseEase = 0.8, resumeEase = 0.4
    /// A new album's colors blend in over this long.
    static let paletteFade = 2.5

    static func base(loudness: Double, intensity: Double) -> Double {
        calm - dip * intensity + breath * (loudness - 0.5)
    }

    static func barBase(loudness: Double, intensity: Double) -> Double {
        barCalm + barBreath * loudness * intensity
    }

    static func accent(strength: Double, intensity: Double) -> Double {
        (accentFloor + (1 - accentFloor) * pow(min(1, max(0, strength)), accentCurve)) * intensity
    }

    static func reach(strength: Double) -> Double {
        reachMin + reachRange * pow(min(1, max(0, strength)), reachCurve)
    }

    /// How much of an accent reaches a point `distance` laps from where it started, `age` s in.
    static func spreadProfile(distance: Double, reach: Double, age: Double) -> Double {
        let width = 0.04 + reach * (1 - exp(-age / spread))
        let x = distance / width
        return exp(-x * x * x * x)
    }

    static func blobProfile(_ weight: Double) -> Double {
        blobFloor + (1 - blobFloor) * pow(weight, blobCurve)
    }

    /// The lowest base while playing: full intensity, silence.
    static let playingFloor = base(loudness: 0, intensity: 1)

    static func pauseBrightness(at time: Double) -> Double {
        playingFloor + pauseBreath * sin(2 * .pi * time / pausePeriod)
    }

    static func barPauseBrightness(at time: Double) -> Double {
        barCalm + pauseBreath * sin(2 * .pi * time / pausePeriod)
    }

    static func brightness(base: Double, accent: Double, groove: Double) -> Double {
        let flashes = screen(accent, groove)
        return min(1, max(0, base + (1 - base) * flashes))
    }

    static func screen(_ a: Double, _ b: Double) -> Double {
        1 - (1 - a) * (1 - b)
    }
}

/// One flash layer, shaped so it never has a corner: each trigger lifts a *target* at once —
/// to screen of the target and the trigger's size, so no trigger is ever swallowed — the
/// target decays exponentially (`decay`), and the light follows it through two cascaded
/// one-pole low-passes (`attack` each), i.e. a critically damped response: a quick but rounded
/// rise, a soft peak and a long, smooth fall. Output is scaled so a lone trigger peaks at its
/// size (`peakDelay` after the trigger).
struct FlashEnvelope {
    let attack: Double, decay: Double
    /// Time from a trigger to its peak, and the gain that makes that peak equal the size.
    let peakDelay: Double
    private let gain: Double
    private var target = 0.0, first = 0.0, second = 0.0

    var level: Double { min(1, gain * second) }

    init(attack: Double, decay: Double) {
        self.attack = attack
        self.decay = decay
        // Measure one trigger's response once.
        var probe = (target: 1.0, first: 0.0, second: 0.0)
        var peak = (time: 0.0, value: 0.0), time = 0.0
        let dt = 1.0 / 1000
        while time < 4 * decay + 10 * attack {
            time += dt
            Self.step(&probe.target, &probe.first, &probe.second, dt: dt, attack: attack, decay: decay)
            if probe.second > peak.value { peak = (time, probe.second) }
        }
        peakDelay = peak.time
        gain = 1 / peak.value
    }

    mutating func trigger(_ size: Double) {
        guard size > 0.001 else { return }
        target = GlowBudget.screen(target, min(1, size))
    }

    mutating func advance(dt: Double) {
        Self.step(&target, &first, &second, dt: dt, attack: attack, decay: decay)
    }

    private static func step(_ target: inout Double, _ first: inout Double, _ second: inout Double, dt: Double, attack: Double, decay: Double) {
        let follow = 1 - exp(-dt / attack)
        first += (target - first) * follow
        second += (first - second) * follow
        target *= exp(-dt / decay)
    }
}
