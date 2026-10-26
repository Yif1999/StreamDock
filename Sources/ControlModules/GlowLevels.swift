import Foundation

/// How MusicGlow spends its brightness, in one place. Every level is *perceived* brightness
/// 0...1 (`LEDOutput` turns it into LED drive with a gamma), and flashes combine by *screen*
/// (1 − (1 − a)(1 − b)), the way overlapping light adds up: never past 1, and a new flash on
/// top of a fading one always shows.
///
/// The picture (after HomePod's Sound Glow, 2026-10-27): a square canvas the size of the base,
/// seen from above; each LED shows it where the LED sits (`LightLayout.position`) — the ring
/// its edge, the short bars two points inside.
/// - ground and blobs: the main color fills the canvas; soft discs of every cover color and a
///   white drift about on it, each sized by its share (`blobRadius`). Where a blob nears the
///   edge, that stretch of the ring takes its color; nothing turns round the ring as a whole,
///   and a blob is never small enough to color a single LED alone (`blobMin`);
/// - kick: a heavy kick sends the blob nearest a new place on the edge toward it (`kickSpeed`)
///   — the colors move to the beat, damped (`damping`) between;
/// - draw: the low end (kick and bass) is the "in" — the blobs shrink back (`drawShrink`), the
///   light dims (`sag`) and the color deepens (`drawDeepen`); letting go, they swell a little
///   past rest — bigger, richer — and settle (`rebound*`);
/// - lift: a mid hit (snare, a vocal attack — not the click of a kick, see `RhythmEvent.lift`)
///   is the "out" — the light brightens from a new place on the edge outward, and the blob
///   nearest it swells (`swellGrow`); a heavy one flashes near-white at its peak (`liftWhite`);
///   snares come first (`liftHoldsDraw`);
/// - glint: a high hit heard on its own — no kick or snare for a while, the bass not drawing —
///   is a short, crisp, whitish point on the edge; under the drums it would only be clutter.
/// Kicks, lifts and glints all land at places picked by one rule (`MusicGlow.place`).
struct GlowBudget {
    /// Brightness: `calm` with no rhythm, `dip` lower at full intensity (headroom for the
    /// lifts), ± `breath` with loudness.
    static let calm = 0.55, dip = 0.1, breath = 0.08
    /// The short bars: their own, dimmer base; they sag with the draw and light with the lifts.
    static let barCalm = 0.35, barBreath = 0.15

    /// Canvas: the ground counts as `groundWeight` against the blobs' discs (weight 1 at a
    /// center, Gaussian); a blob covering `share` of the cover has radius √(`blobArea`·share/π),
    /// never under `blobMin` (its soft edge spans about five LEDs, so no LED is ever colored alone). The white takes `companionShare` unless
    /// the cover has its own.
    static let groundWeight = 0.45, blobArea = 0.7, blobMin = 0.3
    /// Blobs are feathered: their Gaussian runs `feather` × the radius, so a blob's color fades
    /// in and out over several LEDs as it moves. On top, no LED's color may change faster than
    /// `colorRate` (OKLab distance per second): however fast a blob is kicked, each LED blends
    /// over to its new color (2026-10-27: hard-edged blobs made single LEDs switch at once).
    static let feather = 1.4, colorRate = 1.2
    static let companionShare = 0.15
    /// Motion: each blob is pushed along a heading turning at `turnRate` rad/s, by `wanderCalm`
    /// + `wanderRhythm`·intensity; blobs closer than `apart` repel (`repel`); soft walls
    /// (`wallSpring`) start `wallMargin` in from the edge, so a blob can reach the edge but not
    /// leave — its center never comes closer than `blobInset` to the edge (past a corner it would
    /// color the corner LED alone); speed is damped with time constant `damping` and capped at `maxSpeed`. A heavy
    /// kick of strength s adds `kickSpeed`·s toward its target. Paused, blobs drift as at
    /// intensity `pauseDrift`.
    static let turnRate = 0.4, wanderCalm = 0.08, wanderRhythm = 0.12
    static let apart = 0.35, repel = 0.02, wallSpring = 6.0, wallMargin = 0.12
    static let damping = 0.9, maxSpeed = 1.5, kickSpeed = 0.9, pauseDrift = 0.0, blobInset = 0.04
    /// No lone LED: one whose neighbours are within `loneAlike` of each other (OKLab distance)
    /// while it is more than `loneApart` from both.
    static let loneAlike = 0.05, loneApart = 0.1
    /// How much of the chroma an OKLab average loses between two hues is put back.
    static let keepChroma = 0.6

    /// Draw: the blobs shrink by up to `drawShrink`, the light sags by `sag`, the color deepens
    /// by up to `drawDeepen`. Depth (`drawCalm` + `drawRhythm`·intensity) × `drawGain`, up to 1;
    /// followed through two low-passes, like the flashes: `drawAttack` in and `drawRelease` out,
    /// then `drawSmooth` both ways, so it gathers roundly and lets go slowly, never flicking.
    static let drawShrink = 0.5, sag = 0.3
    static let drawCalm = 0.35, drawRhythm = 0.65, drawGain = 1.6
    static let drawAttack = 0.08, drawRelease = 0.45, drawSmooth = 0.1
    /// Snares come first: a lift holds the draw back by up to `liftHoldsDraw` of its level, so
    /// a snare landing with a kick reads as the release, not as both cancelling.
    static let liftHoldsDraw = 0.8
    /// Color: chroma × `restChroma` at rest. Deepening moves a color toward its most vivid form
    /// on the LEDs (`MusicGlow.vivid`: same hue, its white taken out), so a pale cover color
    /// visibly deepens too; a color nearer white than `hueless` deepens toward the main color's
    /// vivid form. The draw deepens by up to `drawDeepen`, the rebound by `reboundDeepen`.
    static let restChroma = 0.85, drawDeepen = 0.7, reboundDeepen = 0.4, hueless = 0.15
    /// Every band places its triggers the same way: new random places on the edge, kept
    /// `placeGap` laps from the band's lit ones, a set nudged up to `placeJitter` of its spacing.
    static let placeGap = 0.15, placeJitter = 0.4

    /// Lift: a mid hit of strength s is (`liftFloor` + (1 − `liftFloor`)·s^`liftCurve`)·intensity,
    /// reaching `reachMin` + `reachRange`·s^`reachCurve` laps round the edge (0.5 = the far side;
    /// flat-topped, so ≥ 0.7 fills the ring) with time constant `spread`; the blob nearest swells
    /// by up to `swellGrow`; the color gains `liftChroma`·lift. Above `whiteFrom` the light goes
    /// toward white, up to `liftWhite` at a full lift: a heavy snare flashes a restrained, bright
    /// near-white — low in color, high in light — while ordinary ones stay their color
    /// (2026-10-27: lifts that never whitened had lost the flash's class).
    static let liftFloor = 0.25, liftCurve = 1.0
    static let whiteFrom = 0.5, liftWhite = 0.7
    static let reachMin = 0.1, reachRange = 0.65, reachCurve = 2.0, spread = 0.18
    static let swellGrow = 0.6, liftChroma = 0.2
    static let liftAttack = 0.035, liftDecay = 0.55
    /// Glint: size (`glintFloor` + (1 − `glintFloor`)·s)·intensity, `glintWidth` laps wide,
    /// `glintWhite` of the way to the white, quick (`glintAttack`, `glintDecay`), at most one per
    /// `glintSpacing` s, never within `glintGap` laps of another lit glint, and only `glintQuiet`
    /// s after the last kick or mid lift with the draw under `glintQuietDraw`.
    static let glintFloor = 0.5, glintWidth = 0.03, glintWhite = 0.5
    static let glintAttack = 0.025, glintDecay = 0.18, glintSpacing = 0.09, glintGap = 0.12
    static let glintQuiet = 0.6, glintQuietDraw = 0.15

    /// Rebound after the draw: a follower that keeps the draw's peaks and lets go over
    /// `reboundFollow` s; how far it stands above the draw (×`reboundGain`, up to 1) grows the
    /// blobs by `reboundGrow`, deepens the colors (`reboundDeepen`) and brightens by `reboundLift`.
    static let reboundFollow = 0.7, reboundGain = 2.5
    static let reboundGrow = 0.3, reboundLift = 0.12

    static let loudnessEase = 0.35, intensityEase = 0.6
    /// Paused: a breath around the lowest base the music ever plays at (`playingFloor`, and
    /// `barCalm` for the bars) ± `pauseBreath` every `pausePeriod` s; eased in over `pauseEase`
    /// s and back out over `resumeEase` s.
    static let pauseBreath = 0.04, pausePeriod = 6.0
    static let pauseEase = 0.8, resumeEase = 0.4
    /// A new album's colors take over the canvas over about this long.
    static let paletteFade = 2.5

    static func blobRadius(share: Double) -> Double {
        max(blobMin, (blobArea * share / .pi).squareRoot())
    }

    static func base(loudness: Double, intensity: Double) -> Double {
        calm - dip * intensity + breath * (loudness - 0.5)
    }

    static func barBase(loudness: Double, intensity: Double) -> Double {
        barCalm + barBreath * loudness * intensity
    }

    static func lift(strength: Double, intensity: Double) -> Double {
        (liftFloor + (1 - liftFloor) * pow(min(1, max(0, strength)), liftCurve)) * intensity
    }

    static func glint(strength: Double, intensity: Double) -> Double {
        (glintFloor + (1 - glintFloor) * min(1, max(0, strength))) * intensity
    }

    static func reach(strength: Double) -> Double {
        reachMin + reachRange * pow(min(1, max(0, strength)), reachCurve)
    }

    static func drawDepth(intensity: Double) -> Double {
        drawCalm + drawRhythm * intensity
    }

    /// How much of a lift reaches a point `distance` laps from where it started, `age` s in.
    static func spreadProfile(distance: Double, reach: Double, age: Double) -> Double {
        let width = 0.04 + reach * (1 - exp(-age / spread))
        let x = distance / width
        return exp(-x * x * x * x)
    }

    /// The lowest base while playing: full intensity, silence.
    static let playingFloor = base(loudness: 0, intensity: 1)

    static func pauseBrightness(at time: Double) -> Double {
        playingFloor + pauseBreath * sin(2 * .pi * time / pausePeriod)
    }

    static func barPauseBrightness(at time: Double) -> Double {
        barCalm + pauseBreath * sin(2 * .pi * time / pausePeriod)
    }

    /// A level with flashes screened on top: never below the level, never past 1.
    static func brightness(base: Double, flash: Double) -> Double {
        min(1, max(0, base + (1 - base) * min(1, max(0, flash))))
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
