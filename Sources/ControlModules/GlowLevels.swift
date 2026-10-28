import Foundation

/// How MusicGlow spends its brightness, in one place. Every level is *perceived* brightness
/// 0...1 (`LEDOutput` turns it into LED drive with a gamma), and flashes combine by *screen*
/// (1 − (1 − a)(1 − b)), the way overlapping light adds up: never past 1, and a new flash on
/// top of a fading one always shows.
///
/// The picture (after HomePod's Sound Glow, 2026-10-27): a square canvas the size of the base,
/// seen from above; each LED shows it where the LED sits (`LightLayout.position`) — the ring
/// its edge, the short bars two points inside.
/// - ground and blobs (2026-10-27, after Sound Glow's own picture): the ground is white (the
///   cover's, or a white faintly tinted with the main color); the cover's other colors drift on
///   it as soft discs sized by their share (`blobRadius`, never under `blobMin`, so no LED is
///   colored alone); over them one big soft disc of the main color (`main*`) wanders slowly
///   round the middle, so most of the ring takes the main color and its far side the white and
///   the other colors rolling;
/// - draw: the low end (kick and bass) pulls the main blob in — steadily, as far as it draws —
///   small (`mainTight`) onto a place on the edge, uncovering the white and the other colors;
///   the light dims (`sag`) and the colors deepen (`drawDeepen`); letting go, it swells a little
///   past rest — bigger, richer — and settles (`rebound*`). Only the low end moves it;
/// - lift: a mid hit is the "out" — the light brightens from a new place on the edge outward.
///   On a drawn, dimmed ring that brings the colors up to full strength; on a bright one a
///   heavy hit flashes near-white at its peak (`liftWhite`) — but with the low end drawing, a
///   lift lights the colors' own hues at full strength instead (`liftVivid`), never white.
///   Lifts never move the blobs;
/// - glint: a high hit heard on its own — no kick or snare for a while, the bass not drawing —
///   is a short, crisp, whitish point on the edge; under the drums it would only be clutter.
/// Lifts and glints land at places picked by one rule (`MusicGlow.place`).
struct GlowBudget {
    /// Brightness: `calm` with no rhythm, `dip` lower at full intensity (headroom for the
    /// lifts), ± `breath` with loudness.
    static let calm = 0.55, dip = 0.1, breath = 0.08
    /// The short bars: their own, dimmer base; they sag with the draw and light with the lifts.
    static let barCalm = 0.35, barBreath = 0.15

    /// Canvas: the ground counts as `groundWeight` against the blobs' discs (weight `blobPeak`
    /// inside, the soft edge `cover`); a blob covering `share` of the cover has radius
    /// √(`blobArea`·share/π), never under `blobMin`, so no LED is ever colored alone.
    static let groundWeight = 0.45, blobPeak = 2.0, blobArea = 0.7, blobMin = 0.4
    /// The main blob's color is the cover's biggest color with a hue, OKLab chroma ≥ `mainChroma`
    /// — never a white or grey (2026-10-27: a cover mostly white made the main blob white). It
    /// lies over the rest (`cover`), its edge half way at `mainRest` at rest and `mainTight`
    /// fully drawn.
    static let mainRest = 0.6, mainTight = 0.2, mainChroma = 0.06
    /// Every disc's edge fades over the same width however small it is — a logistic of slope
    /// `edge`, ≈ 4.4·`edge` from 90 % to 10 % — so with the LEDs up to 0.2 apart, no two
    /// neighbours differ by more than `ledStep` (OKLab) and a color never hands over from one LED
    /// to the next (2026-10-27: Gaussian discs sharpen with distance and, drawn small, changed
    /// color across a single gap).
    static let edge = 0.35, ledStep = 0.1
    /// On top, each LED takes `ledSpread` of each neighbour's canvas color (a plain OKLab average,
    /// like the light guide's spread), so however colors meet on the canvas — several blending,
    /// one shuffling to the front — neighbours stay within `ledStep` (2026-10-27: four colors
    /// meeting still stepped 0.14 between two LEDs).
    static let ledSpread = 0.25
    /// At rest its centre wanders `mainOffset` (± `mainOffsetBreath`) from the middle — off
    /// centre, so the ring shows a side of it, but never against the edge — turning at up to
    /// `mainTurnCalm` + `mainTurnRhythm`·intensity rad/s, reversing every `mainTurnPeriod` / 2 s.
    /// The draw pulls it out to the place on the edge it faces, so the pull drifts along the edge
    /// with it (2026-10-27: a new place for every low onset looked restless; one place per draw
    /// stuck to one spot).
    static let mainOffset = 0.2, mainOffsetBreath = 0.05
    static let mainTurnCalm = 0.12, mainTurnRhythm = 0.25, mainTurnPeriod = 40.0

    /// How much a disc whose edge is half way at `radius` covers a point `distance` from its centre.
    static func cover(distance: Double, radius: Double) -> Double {
        1 / (1 + exp((distance - radius) / edge))
    }
    /// On top of the soft edges, no LED's color may change faster than
    /// `colorRate` (OKLab distance per second): however fast a blob is kicked, each LED blends
    /// over to its new color (2026-10-27: hard-edged blobs made single LEDs switch at once).
    static let colorRate = 1.2
    /// Motion — a glide, never a bounce: each blob travels at `wanderCalm` + `wanderRhythm`·
    /// intensity along a heading that meanders (turning at up to `turnCalm` + `turnRhythm`·
    /// intensity rad/s, the turn itself swaying over `meanderPeriod` s, so it curves one way and
    /// then the other) — about five times as fast in a busy passage as in a calm one (2026-10-27:
    /// 0.08 → 0.2 with a fixed turn did not visibly follow the music). It is steered, not pushed:
    /// the heading bends toward the middle as the blob gets further out (`steer`·distance², as
    /// fast as it travels) and away from a blob nearby (`apartSteer` fading over `apart`), never
    /// turning faster than `maxTurn` rad/s; it travels where it heads, its speed easing over
    /// `glide` s, so it curves round in arcs (2026-10-27:
    /// soft walls and a clamp read as bumping into the sides and bouncing back). Its centre never
    /// comes closer than `blobInset` to the edge (past a corner it would color the corner LED
    /// alone). Paused, blobs drift as at intensity `pauseDrift`.
    static let turnCalm = 0.2, turnRhythm = 0.6, wanderCalm = 0.03, wanderRhythm = 0.12
    static let meanderPeriod = 11.0, steer = 60.0, apartSteer = 0.5, apart = 0.25, glide = 0.8, maxTurn = 2.5
    /// The shuffle — what makes them roll: the other colors overlap and take turns coming to the
    /// front, like cards shuffled, each going round its depth (sine) at `shuffleCalm` +
    /// `shuffleRhythm`·intensity cycles/s, evenly out of step, so one rises in front as another
    /// sinks behind. In front a blob weighs e^`depthWeight` and is `depthGrow` bigger; behind,
    /// e^−`depthWeight` and smaller, nearly hidden (2026-10-27: gliding alone read as circling,
    /// not rolling; Sound Glow's colors trade places front to back).
    static let shuffleCalm = 0.08, shuffleRhythm = 0.4, depthWeight = 1.5, depthGrow = 0.25
    static let pauseDrift = 0.0, blobInset = 0.04
    /// No lone LED: one whose neighbours are within `loneAlike` of each other (OKLab distance)
    /// while it is more than `loneApart` from both.
    static let loneAlike = 0.05, loneApart = 0.1
    /// How much of the chroma an OKLab average loses between two hues is put back.
    static let keepChroma = 0.6

    /// Draw: pulls the main blob in (`main*`), the light sags by `sag`, the color deepens by up
    /// to `drawDeepen`. Depth (`drawCalm` + `drawRhythm`·intensity) × `drawGain`, up to 1;
    /// followed through two low-passes, like the flashes: `drawAttack` in and `drawRelease` out,
    /// then `drawSmooth` both ways, so it gathers roundly and lets go slowly, never flicking.
    /// Its onset, like a lift's, comes in a little gently (2026-10-27: 0.08 s read as a jolt).
    static let sag = 0.5
    static let drawCalm = 0.35, drawRhythm = 0.65, drawGain = 1.6
    static let drawAttack = 0.12, drawRelease = 0.45, drawSmooth = 0.1
    /// Color: chroma × `restChroma` at rest. Deepening moves a color toward its most vivid form
    /// on the LEDs (`MusicGlow.vivid`: same hue, its white taken out), so a pale cover color
    /// visibly deepens too; a white has no hue to deepen and stays.
    /// The draw deepens by up to `drawDeepen`, the rebound by `reboundDeepen`.
    static let restChroma = 0.85, drawDeepen = 0.7, reboundDeepen = 0.4
    /// How much a color deepens grows smoothly with how much hue it has — (highest − lowest) /
    /// highest channel, none under `hueFrom`, fully from `hueFull` (2026-10-27: a hard line at
    /// 0.15 turned one LED of a near-white pink cover pure pink beside one that stayed pale).
    static let hueFrom = 0.05, hueFull = 0.3
    /// Nothing the music light sends out is more saturated than `maxSaturation` — (highest −
    /// lowest) / highest channel; past it a little white goes back in, the hue and brightness
    /// kept. Every deepening and lift is held under it, whatever the cover (2026-10-27: chosen
    /// on the strip with `dock-probe satsteps`; the hue with no white at all read as harsh).
    static let maxSaturation = 0.85
    /// Every band places its triggers the same way: new random places on the edge, kept
    /// `placeGap` laps from the band's lit ones, a set nudged up to `placeJitter` of its spacing.
    static let placeGap = 0.15, placeJitter = 0.4

    /// Lift: a mid hit of strength s is (`liftFloor` + (1 − `liftFloor`)·s^`liftCurve`)·intensity,
    /// reaching `reachMin` + `reachRange`·s^`reachCurve` laps round the edge (0.5 = the far side;
    /// flat-topped, so ≥ 0.7 fills the ring) with time constant `spread`; the color gains
    /// `liftChroma`·lift. Above `whiteFrom` the light goes
    /// toward white, up to `liftWhite` at a full lift: a heavy snare flashes a restrained, bright
    /// near-white — low in color, high in light — while ordinary ones stay their color
    /// (2026-10-27: lifts that never whitened had lost the flash's class).
    static let liftFloor = 0.25, liftCurve = 1.0
    static let whiteFrom = 0.65, liftWhite = 0.3
    /// Under the draw a lift goes `liftVivid`·lift·draw of the way to its color's most vivid
    /// form, and its white flash fades out by (1 − draw): with a kick or bass going, the lifts
    /// read as color; on their own, as light (2026-10-27).
    static let liftVivid = 1.0
    /// Only the heavy mid hits (`RhythmEvent.lift` heavy, the top of the band like the kicks)
    /// lift and flash as above; the rest only glow: (`softSize`·s)·intensity, `softReach` laps
    /// round, their color `softVivid`·glow of the way to its most vivid form — never white
    /// (2026-10-27: every mid onset lifting at least a quarter kept the ring lit and hid the
    /// draw's dimming).
    static let softSize = 0.3, softReach = 0.12, softVivid = 1.0

    static func softLift(strength: Double, intensity: Double) -> Double {
        softSize * min(1, max(0, strength)) * intensity
    }
    static let reachMin = 0.1, reachRange = 0.65, reachCurve = 2.0, spread = 0.18
    static let liftChroma = 0.2
    /// A lift brightens over `liftAttack` (two cascaded stages, peak ≈ 0.14 s) — a little gentle,
    /// not a snap (2026-10-27: 0.035 s, peak ≈ 0.1 s, lit too suddenly) — while it spreads round
    /// the edge as fast as before (`spread`, by age, not by the envelope).
    static let liftAttack = 0.05, liftDecay = 0.55
    /// Glint: `glintCount` points per high hit — how many picked at random each time, 2 on
    /// average — about evenly round the edge (2026-10-28: one point per hit looked too sparse,
    /// always two too regular; still on the hits, never between them), each
    /// size `glintFloor` + (1 − `glintFloor`)·s — the high band's own strength alone, not the
    /// intensity, which counts only the low and mid hits and so fell to 0 a couple of seconds
    /// into a passage of cymbals on their own, just where glints belong (2026-10-28) —
    /// `glintWidth` laps wide,
    /// `glintWhite` of the way to the white, quick (`glintAttack`, `glintDecay`), at most one per
    /// `glintSpacing` s, never within `glintGap` laps of another lit glint, and only `glintQuiet`
    /// s after the last kick or mid lift with the draw under `glintQuietDraw`.
    static let glintCount = 1...3, glintFloor = 0.5, glintWidth = 0.03, glintWhite = 0.5
    static let glintAttack = 0.025, glintDecay = 0.18, glintSpacing = 0.04, glintGap = 0.12
    static let glintQuiet = 0.6, glintQuietDraw = 0.15

    /// Rebound after the draw: a follower that keeps the draw's peaks and lets go over
    /// `reboundFollow` s; how far it stands above the draw (×`reboundGain`, up to 1) grows the
    /// main blob by `reboundGrow`, deepens the colors (`reboundDeepen`) and brightens by `reboundLift`.
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

    static func glint(strength: Double) -> Double {
        glintFloor + (1 - glintFloor) * min(1, max(0, strength))
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
