import DockCore
import Foundation
import RhythmKit

/// Which parts of the music light show play — all of them, or one alone (tests check each
/// effect on its own; 律动可视化 previews each on the strip). The blobs always drift; `flow` is
/// that alone, `draw` adds the low end's pull, `lift` the mid lifts, `high` the glints.
public enum MusicGlowLayer: String, CaseIterable, Sendable {
    case all, flow, draw, lift, high
}

/// A Sound Glow–style light show driven by RhythmKit (see docs/rhythm.md), drawn on a square
/// canvas the size of the base, seen from above: a white ground, the cover's other colors as
/// soft blobs drifting on it, and over them one big soft blob of the main color; each LED shows
/// the canvas where it sits (`LightLayout.position`) — the ring its edge, the short bars two
/// points inside. It makes no rhythm decisions of its own; it turns what the audio side reports
/// into light:
///
/// - calm, the main blob is big and wanders slowly round the middle, so most of the ring takes
///   its color and the far side shows the white and the other colors rolling;
/// - low draw (kick and bass) pulls the main blob in: it shrinks and is drawn onto a place on
///   the edge, steadily, as long as the low end draws, uncovering the white and the other
///   colors; the light dims and the colors deepen; letting go, it swells back and returns;
/// - mid hit: the light brightens from a new place on the edge outward — with the low end
///   drawing, in the colors' own hues at full strength; with it quiet, a heavy hit flashes
///   near-white.
///   Mids never move the blobs; only the low end does;
/// - high hit with the low and mid quiet → a crisp whitish glint on the edge.
/// Paused, it settles into a slow, dim breath, the main color over the ground again and its
/// blob down to its share, so every cover color shows.
///
/// How bright each part may get and how fast anything may change is `GlowBudget`'s job alone;
/// colors blend in OKLab (`OKLab`), and `LEDOutput` turns perceived brightness into LED values.
@MainActor
final class MusicGlow: LightAnimation {
    /// This frame's rhythm input, or nil without live audio (then an idle drift plays).
    var rhythm: () -> (events: [RhythmEvent], snapshot: RhythmSnapshot)? = { nil }
    /// False while Music is paused: the glow eases into a slow breath and back. Paused is
    /// still an active light (it is showing the music), so `isActive` stays true.
    var playing = true
    /// Which effects play (all, unless previewing one in 律动可视化 or testing); read each frame.
    var layer: () -> MusicGlowLayer = { GlowScope.shared.layer }

    /// A soft disc of one of the other cover colors on the canvas, drifting.
    struct Blob {
        var color: OKLab
        var share: Double
        var x: Double, y: Double
        var vx = 0.0, vy = 0.0
        /// Where its idle wandering heads, turning slowly (radians).
        var heading: Double
        /// Where it is in the shuffle (radians): its depth is the sine — in front at the top,
        /// behind the others at the bottom.
        var shuffle: Double
        var depth: Double { sin(shuffle) }
    }

    /// The main color's blob: at rest big, wandering round the middle (`angle`, `offset` from
    /// the centre); the low end pulls it small onto `edge`, the place on the edge it faces —
    /// which drifts along the edge as the blob wanders.
    struct Main {
        var color: OKLab
        var share: Double
        var angle = 0.0
        var edge = (x: 0.0, y: 0.5)
        var x = 0.5, y = 0.5, radius = 0.5
    }

    /// One lift, spreading round the edge toward `reach` from where it landed (laps).
    private struct Ripple {
        let origin: Double
        let reach: Double
        /// A heavy hit's lift (flashes); the rest only glow, more saturated.
        let heavy: Bool
        var age = 0.0
        var envelope = FlashEnvelope(attack: GlowBudget.liftAttack, decay: GlowBudget.liftDecay)
    }

    private var swatches: [(color: OKLab, share: Double)]
    /// The canvas: its ground (white), the other colors' blobs on it, the main blob over them.
    private var ground: OKLab
    private(set) var blobs: [Blob] = []
    private(set) var main: Main

    private var lastTime: TimeInterval?
    private var loudness: Double?
    private var intensity: Double?
    private var draw = 0.0
    /// The draw's slowly released peak; above the draw it is the rebound.
    private var held = 0.0
    /// The draw's first, asymmetric stage.
    private var pull = 0.0
    /// 1 while playing, 0 paused, eased between.
    private var presence = 1.0

    private var ripples: [Ripple] = []
    /// Where the lifts still showing started (laps), for checking.
    var liftPlaces: [Double] { ripples.map(\.origin) }
    /// Glints, at fixed places round the edge (laps).
    private var glints: [(place: Double, age: Double, envelope: FlashEnvelope)] = []
    private var pendingGlints: [Double] = []
    private var lastGlint: TimeInterval = -.infinity
    /// The last heavy kick or mid lift heard: glints only play once the low and mid have gone quiet.
    private var lastLowMid: TimeInterval = -.infinity
    /// Where effects land: varied but reproducible (the same music gives the same light).
    private var random = SeededRandom(seed: 0x5EED)
    /// The colors the ring shows this frame, before effects (each LED follows the canvas at a
    /// limited rate from here), and the bars' likewise.
    private(set) var shownField: [OKLab] = []
    private var barColors: [Int: OKLab] = [:]

    init(palette: [Swatch]) {
        swatches = Self.normalized(palette)
        ground = swatches[0].color
        main = Main(color: swatches[0].color, share: swatches[0].share)
        blobs = makeBlobs()
    }

    func setPalette(_ newPalette: [Swatch]) {
        let next = Self.normalized(newPalette)
        guard next.map(\.color) != swatches.map(\.color) || next.map(\.share) != swatches.map(\.share) else { return }
        swatches = next
        // The blobs stay where they are and take on the new colors gradually (see `frame`). A
        // different number of colors keeps the blobs there were, moving as they were; one added
        // starts as the ground and takes its color over the same fade.
        let targets = members()
        if targets.count != blobs.count {
            let old = blobs
            blobs = makeBlobs()
            for index in blobs.indices {
                if index < old.count { blobs[index] = old[index] } else { blobs[index].color = ground }
            }
        }
    }

    /// The cover's colors with shares summing to 1, the main color first: the biggest one that
    /// has a hue (OKLab chroma at least `mainChroma`) — a white or grey never leads, however
    /// much of the cover it takes; only a cover with no hue at all has a white main color.
    private static func normalized(_ palette: [Swatch]) -> [(color: OKLab, share: Double)] {
        let list = palette.isEmpty ? [Swatch(.white, share: 1)] : palette
        let sum = list.reduce(0) { $0 + max(0, $1.share) }
        var colors = list.map { (color: OKLab(srgb: $0.color), share: sum > 0 ? max(0, $0.share) / sum : 1 / Double(list.count)) }
        if let main = colors.indices.filter({ colors[$0].color.chroma >= GlowBudget.mainChroma }).max(by: { colors[$0].share < colors[$1].share }) {
            colors.insert(colors.remove(at: main), at: 0)
        }
        return colors
    }

    /// The drifting blobs' colors and shares: every cover color but the main one.
    private func members() -> [(color: OKLab, share: Double)] {
        Array(swatches.dropFirst())
    }

    private func makeBlobs() -> [Blob] {
        members().enumerated().map { index, member in
            let angle = 2 * .pi * Double(index) / Double(max(1, swatches.count))
            return Blob(color: member.color, share: member.share,
                        x: 0.5 + 0.25 * cos(angle), y: 0.5 + 0.25 * sin(angle),
                        heading: Double.random(in: 0..<(2 * .pi), using: &random),
                        shuffle: 2 * .pi * Double(index) / Double(max(1, swatches.count - 1)))
        }
    }

    func pixels(at time: TimeInterval, ledCount: Int) -> [LightPixel] {
        frame(at: time, ledCount: ledCount, input: rhythm())
    }

    func frame(at time: TimeInterval, ledCount: Int, input: (events: [RhythmEvent], snapshot: RhythmSnapshot)?) -> [LightPixel] {
        let dt = min(0.1, max(0, time - (lastTime ?? time)))
        lastTime = time
        let ring = LightLayout.ring.filter { $0 < ledCount }
        let layer = layer()
        let shows = { (part: MusicGlowLayer) in layer == .all || layer == part }

        presence = Self.ease(presence, toward: playing ? 1 : 0, dt: dt, over: playing ? GlowBudget.resumeEase : GlowBudget.pauseEase)
        let rawIntensity = (input?.snapshot.intensity ?? 0.3) * (playing ? 1 : 0)
        let intensity = Self.ease(self.intensity ?? rawIntensity, toward: rawIntensity, dt: dt, over: GlowBudget.intensityEase)
        self.intensity = intensity
        // Paused is silence: whatever the audio side still reports, loudness fades with presence.
        let rawLoudness = (input?.snapshot.loudness.low ?? 0.3 + 0.15 * sin(2 * .pi * time / 3)) * (playing ? 1 : 0)
        let loudness = Self.ease(self.loudness ?? rawLoudness, toward: rawLoudness, dt: dt, over: GlowBudget.loudnessEase)
        self.loudness = loudness
        // The draw: two low-passes, quick in and slower out. Only the low end moves it.
        let wantedDraw = shows(.draw) && playing ? min(1, (input?.snapshot.lowDraw ?? 0) * GlowBudget.drawDepth(intensity: intensity) * GlowBudget.drawGain) : 0
        pull = Self.ease(pull, toward: wantedDraw, dt: dt, over: wantedDraw > pull ? GlowBudget.drawAttack : GlowBudget.drawRelease)
        draw = Self.ease(draw, toward: pull, dt: dt, over: GlowBudget.drawSmooth)
        held = max(draw, Self.ease(held, toward: draw, dt: dt, over: GlowBudget.reboundFollow))
        let rebound = min(1, GlowBudget.reboundGain * (held - draw))

        for event in input?.events ?? [] where playing {
            switch event {
            case .kick:
                lastLowMid = time
            case .lift(_, .mid, let strength, let heavy):
                // Only the heavy hits are the "obvious rhythm" that holds the glints back.
                if heavy { lastLowMid = time }
                guard shows(.lift) else { break }
                if heavy {
                    addLift(size: GlowBudget.lift(strength: strength, intensity: intensity), reach: GlowBudget.reach(strength: strength), heavy: true)
                } else {
                    addLift(size: GlowBudget.softLift(strength: strength, intensity: intensity), reach: GlowBudget.softReach, heavy: false)
                }
            case .lift(_, _, let strength, _):
                // Cymbals on their own only: with kicks, snares or a drawing bass about, glints are clutter.
                guard shows(.high), playing, time - lastGlint >= GlowBudget.glintSpacing,
                      time - lastLowMid >= GlowBudget.glintQuiet, draw < GlowBudget.glintQuietDraw else { break }
                lastGlint = time
                pendingGlints.append(GlowBudget.glint(strength: strength))
            case .accent, .expectedBeat, .hit:
                break
            }
        }
        for index in ripples.indices {
            ripples[index].age += dt
            ripples[index].envelope.advance(dt: dt)
        }
        ripples.removeAll { $0.age > 0.5 && $0.envelope.level < 0.003 }
        for index in glints.indices {
            glints[index].age += dt
            glints[index].envelope.advance(dt: dt)
        }
        glints.removeAll { $0.age > 0.2 && $0.envelope.level < 0.003 }
        for size in pendingGlints { addGlint(size: size) }
        pendingGlints.removeAll()

        // The canvas: colors ease to the album's (a new album over `paletteFade`), blobs move.
        // Playing, the ground is white; paused, the main color again.
        let targets = members()
        let colorStep = 1 - exp(-dt / (GlowBudget.paletteFade / 3))
        let companion = Self.companion(swatches.map(\.color))
        ground = ground.mixed(with: companion.mixed(with: swatches[0].color, amount: 1 - presence), amount: colorStep)
        main.color = main.color.mixed(with: swatches[0].color, amount: colorStep)
        main.share = swatches[0].share
        for index in blobs.indices where index < targets.count {
            blobs[index].color = blobs[index].color.mixed(with: targets[index].color, amount: colorStep)
            blobs[index].share = targets[index].share
        }
        move(dt: dt, time: time, intensity: intensity * presence + GlowBudget.pauseDrift * (1 - presence))
        moveMain(dt: dt, time: time, intensity: intensity * presence, rebound: rebound)

        let base = GlowBudget.base(loudness: loudness, intensity: intensity) * (1 - GlowBudget.sag * draw)
        let pause = GlowBudget.pauseBrightness(at: time)
        let deepen = min(1, (GlowBudget.drawDeepen * draw + GlowBudget.reboundDeepen * rebound) * presence)
        func finish(_ color: OKLab, lift: Double, soft: Double, glint: Double) -> (Double, Double, Double) {
            let rich = color.saturated(by: GlowBudget.restChroma + GlowBudget.liftChroma * GlowBudget.screen(lift, soft) * presence)
            // Deepening deepens a hue, as far as the color has one: the white the main blob
            // uncovers stays white, and a color near white deepens only a little.
            let (vivid, hue) = Self.vivid(rich.ledChannels)
            var channels = Self.mix(rich.ledChannels, vivid, deepen * hue)
            // A light hit glows its color more saturated. A heavy one, with the low end drawing,
            // lights the color's own hue at full strength; with it quiet, it flashes toward white
            // at its peak.
            channels = Self.mix(channels, vivid, min(1, GlowBudget.softVivid * soft + GlowBudget.liftVivid * lift * draw) * presence * hue)
            let flash = min(1, max(0, (lift - GlowBudget.whiteFrom) / (1 - GlowBudget.whiteFrom)))
            channels = Self.mix(channels, companion.ledChannels, GlowBudget.liftWhite * flash * flash * (3 - 2 * flash) * (1 - draw) * presence)
            channels = Self.mix(channels, companion.ledChannels, GlowBudget.glintWhite * glint)
            return Self.capped(channels)
        }

        // Each LED follows the canvas, but never faster than `colorRate`.
        let maxStep = GlowBudget.colorRate * dt
        func follow(_ previous: OKLab?, _ target: OKLab) -> OKLab {
            guard let previous else { return target }
            let distance = previous.distance(to: target)
            return distance <= maxStep ? target : previous.mixed(with: target, amount: maxStep / distance)
        }
        var pixels = Array(repeating: LightPixel.black, count: ledCount)
        var field: [OKLab] = []
        // Each LED shows the canvas where it sits, spread a little into its neighbours, as the
        // light guide spreads it: however the colors meet on the canvas, neighbours stay close.
        let sampled = ring.map { canvas(at: LightLayout.position($0)) }
        let spread = sampled.indices.map { slot in
            let before = sampled[(slot + ring.count - 1) % ring.count], after = sampled[(slot + 1) % ring.count]
            let s = GlowBudget.ledSpread
            return OKLab(l: sampled[slot].l * (1 - 2 * s) + (before.l + after.l) * s,
                         a: sampled[slot].a * (1 - 2 * s) + (before.a + after.a) * s,
                         b: sampled[slot].b * (1 - 2 * s) + (before.b + after.b) * s)
        }
        let heavyRipples = ripples.filter(\.heavy), softRipples = ripples.filter { !$0.heavy }
        for (slot, led) in ring.enumerated() {
            let lap = (Double(slot) + 0.5) / Double(ring.count)
            let color = follow(slot < shownField.count ? shownField[slot] : nil, spread[slot])
            field.append(color)
            func lifted(_ ripples: [Ripple]) -> Double {
                ripples.reduce(0.0) { level, ripple in
                    GlowBudget.screen(level, ripple.envelope.level * GlowBudget.spreadProfile(distance: Self.ringDistance(lap, ripple.origin), reach: ripple.reach, age: ripple.age))
                }
            }
            let lift = lifted(heavyRipples), soft = lifted(softRipples)
            let glint = glints.reduce(0.0) { level, glint in
                let x = Self.ringDistance(lap, glint.place) / GlowBudget.glintWidth
                return GlowBudget.screen(level, glint.envelope.level * exp(-x * x))
            }
            let flashes = GlowBudget.screen(GlowBudget.screen(GlowBudget.screen(lift, soft), GlowBudget.reboundLift * rebound), glint)
            let playingLevel = GlowBudget.brightness(base: base, flash: flashes)
            let level = pause + (playingLevel - pause) * presence
            pixels[led] = LightPixel(channels: finish(color, lift: lift, soft: soft, glint: glint), level: level)
        }
        shownField = field

        // Short bars: the canvas along them (level strips), a little dimmer; lit by heavy lifts that spread far.
        let barLift = ripples.filter(\.heavy).reduce(0.0) { GlowBudget.screen($0, $1.envelope.level * min(1, $1.reach / 0.5)) }
        let barBase = GlowBudget.barBase(loudness: loudness, intensity: intensity) * (1 - GlowBudget.sag * draw)
        let barPause = GlowBudget.barPauseBrightness(at: time)
        for bar in [LightLayout.leftBar, LightLayout.rightBar] where bar < ledCount {
            let center = LightLayout.position(bar), half = LightLayout.barLength / 2
            let along = [-half, 0, half].map { canvas(at: (center.x + $0, center.y)) }
            let color = follow(barColors[bar], OKLab.blend(along, weights: [1, 1, 1], keepChroma: GlowBudget.keepChroma))
            barColors[bar] = color
            let barPlaying = GlowBudget.brightness(base: barBase, flash: barLift)
            pixels[bar] = LightPixel(channels: finish(color, lift: barLift, soft: 0, glint: 0), level: barPause + (barPlaying - barPause) * presence)
        }
        if GlowScope.shared.watching {
            capture(time: time, pixels: pixels, input: input, rebound: rebound)
        }
        return pixels
    }

    /// What the 律动可视化 window shows: the canvas, the blobs, the LEDs and the low end.
    private func capture(time: TimeInterval, pixels: [LightPixel], input: (events: [RhythmEvent], snapshot: RhythmSnapshot)?, rebound: Double) {
        let n = GlowScope.grid
        let canvas = (0..<n * n).map { index in
            self.canvas(at: ((Double(index % n) + 0.5) / Double(n), (Double(index / n) + 0.5) / Double(n))).srgb
        }
        let blobs = [GlowScope.Blob(x: main.x, y: main.y, radius: main.radius, vx: 0, vy: 0, main: true, depth: 1, color: main.color.srgb)]
            + blobs.map { blob in
                GlowScope.Blob(x: blob.x, y: blob.y, radius: radius(of: blob) * (1 + GlowBudget.depthGrow * blob.depth), vx: blob.vx, vy: blob.vy, main: false, depth: blob.depth, color: blob.color.srgb)
            }
        let leds = pixels.indices.map { led in
            let p = LightLayout.position(led), pixel = pixels[led]
            let drive = LEDOutput.drive(pixel.level)
            let color = RGB(SRGB.encode(pixel.channels.0 * drive), SRGB.encode(pixel.channels.1 * drive), SRGB.encode(pixel.channels.2 * drive))
            return (x: p.x, y: p.y, color: color, bar: !LightLayout.ring.contains(led))
        }
        let lifts = ripples.map { ripple in
            let p = LightLayout.edgePoint(lap: ripple.origin)
            return (x: p.x, y: p.y, level: ripple.envelope.level)
        }
        GlowScope.shared.record(GlowScope.Frame(
            time: time, canvas: canvas, blobs: blobs, leds: leds, lifts: lifts,
            anchor: draw > 0.02 ? main.edge : nil,
            draw: draw, rebound: rebound, lowDraw: input?.snapshot.lowDraw ?? 0,
            intensity: intensity ?? 0
        ), events: input?.events ?? [])
    }

    /// Where a blob's weight on the canvas falls to 1/e.
    private func radius(of blob: Blob) -> Double {
        GlowBudget.blobRadius(share: blob.share)
    }

    /// The canvas color at a point: the ground, each other color a soft disc over it, and the
    /// main blob laid over them all — every disc with the same soft edge (`GlowBudget.cover`),
    /// in OKLab.
    func canvas(at point: (x: Double, y: Double)) -> OKLab {
        var colors = [ground], weights = [GlowBudget.groundWeight]
        for blob in blobs {
            // The one in front of the shuffle covers the rest, a little bigger; the ones behind fade.
            let front = exp(GlowBudget.depthWeight * blob.depth)
            let radius = radius(of: blob) * (1 + GlowBudget.depthGrow * blob.depth)
            colors.append(blob.color)
            weights.append(GlowBudget.blobPeak * front * GlowBudget.cover(distance: hypot(point.x - blob.x, point.y - blob.y), radius: radius) + 1e-6)
        }
        let under = OKLab.blend(colors, weights: weights, keepChroma: GlowBudget.keepChroma)
        let cover = GlowBudget.cover(distance: hypot(point.x - main.x, point.y - main.y), radius: main.radius)
        return OKLab.blend([under, main.color], weights: [1 - cover + 1e-6, cover + 1e-6], keepChroma: GlowBudget.keepChroma)
    }

    /// The main blob. At rest it wanders round the middle, `mainOffset` (± `mainOffsetBreath`)
    /// from the centre, turning at up to `mainTurnCalm` + `mainTurnRhythm`·intensity rad/s and
    /// now and then the other way. The draw pulls it, as far as it draws, out onto the place on
    /// the edge it faces (straight out from the centre), shrinking from `mainRest` to
    /// `mainTight`; the rebound swells it by `reboundGrow`. So the pull follows the edge as the
    /// blob wanders — the place drifts slowly along the edge, never jumps. Paused, it eases to
    /// its share's size, so the other colors show.
    private func moveMain(dt: Double, time: TimeInterval, intensity: Double, rebound: Double) {
        let turn = (GlowBudget.mainTurnCalm + GlowBudget.mainTurnRhythm * intensity) * sin(2 * .pi * time / GlowBudget.mainTurnPeriod)
        main.angle += turn * dt
        let offset = GlowBudget.mainOffset + GlowBudget.mainOffsetBreath * sin(2 * .pi * time / 17)
        let (c, s) = (cos(main.angle), sin(main.angle))
        let rest = (x: 0.5 + offset * c, y: 0.5 + offset * s)
        let reach = 0.5 / max(abs(c), abs(s))
        main.edge = (0.5 + reach * c, 0.5 + reach * s)
        main.x = rest.x + (main.edge.x - rest.x) * draw
        main.y = rest.y + (main.edge.y - rest.y) * draw
        let playing = (GlowBudget.mainRest + (GlowBudget.mainTight - GlowBudget.mainRest) * draw) * (1 + GlowBudget.reboundGrow * rebound)
        let paused = GlowBudget.blobRadius(share: main.share)
        main.radius = paused + (playing - paused) * presence
    }

    /// The blobs shuffle and glide: they take turns coming to the front, like cards (`shuffle`),
    /// and each glides along a meandering heading, steered round toward the middle as it
    /// gets further out and away from its neighbours, its velocity following the heading — wide
    /// arcs, never a bounce. Faster and twistier the livelier the music.
    private func move(dt: Double, time: TimeInterval, intensity: Double) {
        let speed = GlowBudget.wanderCalm + GlowBudget.wanderRhythm * intensity
        let meander = GlowBudget.turnCalm + GlowBudget.turnRhythm * intensity
        let follow = 1 - exp(-dt / GlowBudget.glide)
        // How far to turn to face `angle`, signed, up to ±π: a blob heading straight out still turns.
        func toward(_ angle: Double, from heading: Double) -> Double { (angle - heading).remainder(dividingBy: 2 * .pi) }
        for index in blobs.indices {
            var blob = blobs[index]
            let period = GlowBudget.meanderPeriod * (1 + 0.23 * Double(index))
            var turn = meander * sin(2 * .pi * time / period + 1.7 * Double(index))
            let cx = 0.5 - blob.x, cy = 0.5 - blob.y
            turn += GlowBudget.steer * speed * (cx * cx + cy * cy) * toward(atan2(cy, cx), from: blob.heading)
            for other in blobs.indices where other != index {
                let dx = blob.x - blobs[other].x, dy = blob.y - blobs[other].y
                let near = exp(-(dx * dx + dy * dy) / (GlowBudget.apart * GlowBudget.apart))
                turn += GlowBudget.apartSteer * near * toward(atan2(dy, dx), from: blob.heading)
            }
            blob.heading += min(GlowBudget.maxTurn, max(-GlowBudget.maxTurn, turn)) * dt
            // It travels where it heads; only its speed eases, so it never skids on past a turn.
            let current = (blob.vx * blob.vx + blob.vy * blob.vy).squareRoot()
            let eased = current + (speed - current) * follow
            blob.vx = eased * cos(blob.heading)
            blob.vy = eased * sin(blob.heading)
            // Centers stay on the canvas: a blob past a corner would color the corner LED alone.
            let inset = GlowBudget.blobInset
            blob.shuffle += 2 * .pi * (GlowBudget.shuffleCalm + GlowBudget.shuffleRhythm * intensity) * dt
            blob.x = min(1 - inset, max(inset, blob.x + blob.vx * dt))
            blob.y = min(1 - inset, max(inset, blob.y + blob.vy * dt))
            blobs[index] = blob
        }
    }

    /// The one placement rule for every band: each trigger — a mid lift, a glint — happens at
    /// new places round the edge, picked at random (reproducibly), `count` of them about evenly spaced (each nudged up to `placeJitter` of the spacing), kept `gap`
    /// laps from the places this band still has lit when a few tries allow.
    private func place(count: Int, avoiding lit: [Double], gap: Double) -> [Double] {
        var set: [Double] = []
        for _ in 0..<8 {
            let turn = Double.random(in: 0..<1, using: &random)
            set = (0..<count).map { index in
                let nudge = count > 1 ? Double.random(in: -0.5...0.5, using: &random) * GlowBudget.placeJitter : 0
                return (turn + (Double(index) + nudge) / Double(count) + 1).truncatingRemainder(dividingBy: 1)
            }
            if set.allSatisfy({ p in lit.allSatisfy { Self.ringDistance(p, $0) >= gap } }) { break }
        }
        return set
    }

    /// A mid lift, at a new place on the edge.
    private func addLift(size: Double, reach: Double, heavy: Bool) {
        guard size > 0.001 else { return }
        let lit = ripples.filter { $0.envelope.level > 0.1 }.map(\.origin)
        var ripple = Ripple(origin: place(count: 1, avoiding: lit, gap: GlowBudget.placeGap)[0], reach: reach, heavy: heavy)
        ripple.envelope.trigger(size)
        ripples.append(ripple)
        if ripples.count > 12 { ripples.removeFirst() }
    }

    /// A high hit's glints (`glintCount`, how many picked at random), at new places.
    private func addGlint(size: Double) {
        guard size > 0.01 else { return }
        let lit = glints.filter { $0.envelope.level > 0.1 }.map(\.place)
        var envelope = FlashEnvelope(attack: GlowBudget.glintAttack, decay: GlowBudget.glintDecay)
        envelope.trigger(size)
        let count = Int.random(in: GlowBudget.glintCount, using: &random)
        for spot in place(count: count, avoiding: lit, gap: GlowBudget.glintGap) {
            glints.append((spot, 0, envelope))
        }
        if glints.count > 12 { glints.removeFirst(glints.count - 12) }
    }

    /// Whether some LED stands out alone: unlike both neighbours, which are alike.
    static func hasLoneLED(_ field: [OKLab]) -> Bool {
        field.indices.contains { index in
            let before = field[(index + field.count - 1) % field.count], after = field[(index + 1) % field.count]
            return before.distance(to: after) < GlowBudget.loneAlike
                && field[index].distance(to: before) > GlowBudget.loneApart && field[index].distance(to: after) > GlowBudget.loneApart
        }
    }

    typealias Channels = (Double, Double, Double)

    /// The most vivid form of an LED color — the same hue with its white taken out (the lowest
    /// channel to 0) — and how much hue the color has to deepen, 0...1: none for a white, rising
    /// smoothly over `GlowBudget.hueFrom`…`hueFull` of (highest − lowest) / highest, so two
    /// neighbouring LEDs either side of "having a hue" deepen alike, never one to a pure color
    /// and the other not.
    static func vivid(_ c: Channels) -> (channels: Channels, hue: Double) {
        let high = max(c.0, c.1, c.2), low = min(c.0, c.1, c.2), span = high - low
        guard high > 0, span > 1e-6 else { return (c, 0) }
        let x = min(1, max(0, (span / high - GlowBudget.hueFrom) / (GlowBudget.hueFull - GlowBudget.hueFrom)))
        return (((c.0 - low) / span, (c.1 - low) / span, (c.2 - low) / span), x * x * (3 - 2 * x))
    }

    /// A color no more saturated than `GlowBudget.maxSaturation` — (highest − lowest) / highest
    /// channel — keeping its hue and its highest channel: past the cap, the other channels are
    /// raised toward the highest, as if a little white were added.
    static func capped(_ c: Channels) -> Channels {
        let high = max(c.0, c.1, c.2), low = min(c.0, c.1, c.2)
        guard high > 0, (high - low) / high > GlowBudget.maxSaturation else { return c }
        let keep = GlowBudget.maxSaturation * high / (high - low)
        return (high - (high - c.0) * keep, high - (high - c.1) * keep, high - (high - c.2) * keep)
    }

    static func mix(_ a: Channels, _ b: Channels, _ amount: Double) -> Channels {
        let t = min(1, max(0, amount))
        return (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    /// The white: the cover's own if it has one, else a white faintly tinted with the main color.
    private static func companion(_ colors: [OKLab]) -> OKLab {
        if let white = colors.first(where: { $0.chroma < 0.04 && $0.l > 0.8 }) { return white }
        let main = colors[0]
        return OKLab(l: 0.92, chroma: main.chroma * 0.12, hue: main.hue)
    }

    /// One step of a one-pole low-pass with time constant `seconds`.
    private static func ease(_ value: Double, toward target: Double, dt: Double, over seconds: Double) -> Double {
        value + (target - value) * (1 - exp(-dt / seconds))
    }

    private static func ringDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }
}

/// A small xorshift generator, so the light show is the same each time for the same input.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Debug tooling: replays a rhythm trace through RhythmKit and this animation, so the light
/// show can be inspected offline (`dock-probe glowsim`).
@MainActor
public enum GlowReplay {
    /// Returns one line per rendered frame: "<time> <state> <kick 0/1> <#RRGGBB × ledCount>".
    public static func replay(trace: RhythmTrace, palette: [Swatch], ledCount: Int = 24) -> [String] {
        let analyzer = RhythmAnalyzer(frameRate: trace.frameRate)
        let glow = MusicGlow(palette: palette)
        var output = LEDOutput()
        var lines: [String] = []
        var pending: [RhythmEvent] = []
        var nextRender = trace.frames.first?.time ?? 0
        for frame in trace.frames {
            pending += analyzer.process(frame)
            // Render at the strip rate like the app, handing over the events gathered since last time.
            guard frame.time >= nextRender else { continue }
            nextRender += 1 / LightLayout.framesPerSecond
            let beat = pending.contains { event in
                if case .kick = event { return true }
                return false
            }
            let colors = output.render(glow.frame(at: frame.time, ledCount: ledCount, input: (pending, analyzer.snapshot)))
            pending.removeAll()
            lines.append(String(format: "%.3f %@ %d ", frame.time, analyzer.snapshot.state.rawValue, beat ? 1 : 0) + colors.map(\.hex).joined(separator: " "))
        }
        return lines
    }
}
