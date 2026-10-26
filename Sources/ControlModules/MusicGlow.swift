import DockCore
import Foundation
import RhythmKit

/// Which parts of the music light show play — all of them, or one alone (tests check each
/// effect on its own). The blobs always move with the music, so a part alone looks as it does
/// with the rest.
enum MusicGlowLayer: Sendable {
    case all, flow, draw, lift, high
}

/// A Sound Glow–style light show driven by RhythmKit (see docs/rhythm.md), drawn on a square
/// canvas the size of the base, seen from above: the main color fills it, and soft blobs of
/// the cover's colors (and a white) drift about inside; each LED shows the canvas where it sits
/// (`LightLayout.position`) — the ring its edge, the short bars two points inside. It makes no
/// rhythm decisions of its own; it turns what the audio side reports into light:
///
/// - calm, the blobs drift slowly and the colors well up and ebb along the edge;
/// - heavy kick → a blob is kicked toward a new place on the edge, washing it with its color;
/// - low draw (kick and bass) is the "in": the blobs shrink back, the light dims and the color
///   deepens; letting go, they swell a little past rest and settle;
/// - mid hit is the "out": the light brightens from a new place on the edge outward and the blob
///   nearest it swells (snares come first: a lift holds the draw back);
/// - high hit with the low and mid quiet → a crisp whitish glint on the edge.
/// Paused, it settles into a slow, dim breath.
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
    /// Which effects play (all, except in tests); read each frame.
    var layer: () -> MusicGlowLayer = { .all }

    /// A soft disc of one color on the canvas, moving.
    struct Blob {
        var color: OKLab
        var share: Double
        var x: Double, y: Double
        var vx = 0.0, vy = 0.0
        /// Where its idle wandering heads, turning slowly (radians).
        var heading: Double
        /// Mid lifts landing near it swell it.
        var swell = FlashEnvelope(attack: GlowBudget.liftAttack, decay: GlowBudget.liftDecay)
    }

    /// One lift, spreading round the edge toward `reach` from where it landed (laps).
    private struct Ripple {
        let origin: Double
        let reach: Double
        var age = 0.0
        var envelope = FlashEnvelope(attack: GlowBudget.liftAttack, decay: GlowBudget.liftDecay)
    }

    private var swatches: [(color: OKLab, share: Double)]
    /// The canvas: its ground (the main color) and the blobs on it.
    private var ground: OKLab
    private(set) var blobs: [Blob] = []

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
    /// The last kick or mid lift heard: glints only play once the low and mid have gone quiet.
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
        blobs = makeBlobs()
    }

    func setPalette(_ newPalette: [Swatch]) {
        let next = Self.normalized(newPalette)
        guard next.map(\.color) != swatches.map(\.color) || next.map(\.share) != swatches.map(\.share) else { return }
        swatches = next
        // The blobs stay where they are and take on the new colors gradually (see `frame`);
        // a different number of colors starts a fresh set, eased in the same way.
        let targets = members()
        if targets.count != blobs.count {
            let old = blobs
            blobs = makeBlobs()
            for index in blobs.indices where index < old.count { blobs[index].color = old[index].color }
        }
    }

    private static func normalized(_ palette: [Swatch]) -> [(color: OKLab, share: Double)] {
        let list = palette.isEmpty ? [Swatch(.white, share: 1)] : palette
        let sum = list.reduce(0) { $0 + max(0, $1.share) }
        return list.map { (OKLab(srgb: $0.color), sum > 0 ? max(0, $0.share) / sum : 1 / Double(list.count)) }
    }

    /// The blobs' colors and shares: every cover color, and a white (`companionShare`) unless the
    /// cover has its own.
    private func members() -> [(color: OKLab, share: Double)] {
        var list = swatches
        if !swatches.contains(where: { $0.color.chroma < 0.04 && $0.color.l > 0.8 }) {
            list = list.map { ($0.color, $0.share * (1 - GlowBudget.companionShare)) }
            list.append((Self.companion(swatches.map(\.color)), GlowBudget.companionShare))
        }
        return list
    }

    private func makeBlobs() -> [Blob] {
        members().enumerated().map { index, member in
            let angle = 2 * .pi * Double(index) / Double(max(1, swatches.count + 1))
            return Blob(color: member.color, share: member.share,
                        x: 0.5 + 0.25 * cos(angle), y: 0.5 + 0.25 * sin(angle),
                        heading: Double.random(in: 0..<(2 * .pi), using: &random))
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
        // The draw: two low-passes, quick in and slower out; a lift showing holds it back (snares first).
        let wantedDraw = shows(.draw) && playing ? min(1, (input?.snapshot.lowDraw ?? 0) * GlowBudget.drawDepth(intensity: intensity) * GlowBudget.drawGain) : 0
        let lifting = ripples.reduce(0.0) { max($0, $1.envelope.level) }
        let heldDraw = wantedDraw * (1 - GlowBudget.liftHoldsDraw * min(1, lifting))
        pull = Self.ease(pull, toward: heldDraw, dt: dt, over: heldDraw > pull ? GlowBudget.drawAttack : GlowBudget.drawRelease)
        draw = Self.ease(draw, toward: pull, dt: dt, over: GlowBudget.drawSmooth)
        held = max(draw, Self.ease(held, toward: draw, dt: dt, over: GlowBudget.reboundFollow))
        let rebound = min(1, GlowBudget.reboundGain * (held - draw))

        for event in input?.events ?? [] where playing {
            switch event {
            case .kick(_, let strength):
                lastLowMid = time
                kick(strength: strength * intensity)
            case .lift(_, .mid, let strength):
                lastLowMid = time
                if shows(.lift) { addLift(size: GlowBudget.lift(strength: strength, intensity: intensity), reach: GlowBudget.reach(strength: strength)) }
            case .lift(_, _, let strength):
                // Cymbals on their own only: with kicks, snares or a drawing bass about, glints are clutter.
                guard shows(.high), time - lastGlint >= GlowBudget.glintSpacing,
                      time - lastLowMid >= GlowBudget.glintQuiet, draw < GlowBudget.glintQuietDraw else { break }
                lastGlint = time
                pendingGlints.append(GlowBudget.glint(strength: strength, intensity: intensity))
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
        let targets = members()
        let colorStep = 1 - exp(-dt / (GlowBudget.paletteFade / 3))
        ground = ground.mixed(with: swatches[0].color, amount: colorStep)
        for index in blobs.indices where index < targets.count {
            blobs[index].color = blobs[index].color.mixed(with: targets[index].color, amount: colorStep)
            blobs[index].share = targets[index].share
            blobs[index].swell.advance(dt: dt)
        }
        move(dt: dt, time: time, intensity: intensity * presence + GlowBudget.pauseDrift * (1 - presence))
        let scale = (1 - GlowBudget.drawShrink * draw) * (1 + GlowBudget.reboundGrow * rebound)

        let base = GlowBudget.base(loudness: loudness, intensity: intensity) * (1 - GlowBudget.sag * draw)
        let pause = GlowBudget.pauseBrightness(at: time)
        let deepen = min(1, (GlowBudget.drawDeepen * draw + GlowBudget.reboundDeepen * rebound) * presence)
        let mainVivid = Self.vivid(swatches[0].color.ledChannels)
        let companion = Self.companion(swatches.map(\.color))
        func finish(_ color: OKLab, lift: Double, glint: Double) -> (Double, Double, Double) {
            let rich = color.saturated(by: GlowBudget.restChroma + GlowBudget.liftChroma * lift * presence)
            var channels = Self.mix(rich.ledChannels, Self.vivid(rich.ledChannels) ?? mainVivid ?? rich.ledChannels, deepen)
            // A heavy lift flashes toward white at its peak; ordinary ones keep their color.
            let flash = min(1, max(0, (lift - GlowBudget.whiteFrom) / (1 - GlowBudget.whiteFrom)))
            channels = Self.mix(channels, companion.ledChannels, GlowBudget.liftWhite * flash * flash * (3 - 2 * flash) * presence)
            channels = Self.mix(channels, companion.ledChannels, GlowBudget.glintWhite * glint)
            return channels
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
        for (slot, led) in ring.enumerated() {
            let lap = (Double(slot) + 0.5) / Double(ring.count)
            let color = follow(slot < shownField.count ? shownField[slot] : nil, canvas(at: LightLayout.position(led), scale: scale))
            field.append(color)
            let lift = ripples.reduce(0.0) { level, ripple in
                GlowBudget.screen(level, ripple.envelope.level * GlowBudget.spreadProfile(distance: Self.ringDistance(lap, ripple.origin), reach: ripple.reach, age: ripple.age))
            }
            let glint = glints.reduce(0.0) { level, glint in
                let x = Self.ringDistance(lap, glint.place) / GlowBudget.glintWidth
                return GlowBudget.screen(level, glint.envelope.level * exp(-x * x))
            }
            let flashes = GlowBudget.screen(GlowBudget.screen(lift, GlowBudget.reboundLift * rebound), glint)
            let playingLevel = GlowBudget.brightness(base: base, flash: flashes)
            let level = pause + (playingLevel - pause) * presence
            pixels[led] = LightPixel(channels: finish(color, lift: lift, glint: glint), level: level)
        }
        shownField = field

        // Short bars: the canvas along them (level strips), a little dimmer; lit by mid lifts that spread far.
        let barLift = ripples.reduce(0.0) { GlowBudget.screen($0, $1.envelope.level * min(1, $1.reach / 0.5)) }
        let barPlaying = GlowBudget.brightness(base: GlowBudget.barBase(loudness: loudness, intensity: intensity) * (1 - GlowBudget.sag * draw), flash: barLift)
        let barPause = GlowBudget.barPauseBrightness(at: time)
        let barLevel = barPause + (barPlaying - barPause) * presence
        for bar in [LightLayout.leftBar, LightLayout.rightBar] where bar < ledCount {
            let center = LightLayout.position(bar), half = LightLayout.barLength / 2
            let along = [-half, 0, half].map { canvas(at: (center.x + $0, center.y), scale: scale) }
            let color = follow(barColors[bar], OKLab.blend(along, weights: [1, 1, 1], keepChroma: GlowBudget.keepChroma))
            barColors[bar] = color
            pixels[bar] = LightPixel(channels: finish(color, lift: barLift, glint: 0), level: barLevel)
        }
        return pixels
    }

    /// The canvas color at a point: the ground, with each blob a soft disc over it (OKLab).
    func canvas(at point: (x: Double, y: Double), scale: Double) -> OKLab {
        var colors = [ground], weights = [GlowBudget.groundWeight]
        for blob in blobs {
            let radius = GlowBudget.feather * max(GlowBudget.blobMin, GlowBudget.blobRadius(share: blob.share) * scale * (1 + GlowBudget.swellGrow * blob.swell.level))
            let dx = point.x - blob.x, dy = point.y - blob.y
            colors.append(blob.color)
            weights.append(exp(-(dx * dx + dy * dy) / (radius * radius)) + 1e-6)
        }
        return OKLab.blend(colors, weights: weights, keepChroma: GlowBudget.keepChroma)
    }

    /// The blobs drift: each pushed gently along a slowly turning heading (harder the livelier the
    /// music), kept apart from each other, held inside the base by soft walls, and damped.
    private func move(dt: Double, time: TimeInterval, intensity: Double) {
        let push = GlowBudget.wanderCalm + GlowBudget.wanderRhythm * intensity
        let decay = exp(-dt / GlowBudget.damping)
        for index in blobs.indices {
            var blob = blobs[index]
            blob.heading += GlowBudget.turnRate * dt * (index % 2 == 0 ? 1 : -1) * (0.7 + 0.1 * Double(index))
            var fx = push * cos(blob.heading), fy = push * sin(blob.heading)
            let margin = GlowBudget.wallMargin
            if blob.x < margin { fx += GlowBudget.wallSpring * (margin - blob.x) }
            if blob.x > 1 - margin { fx -= GlowBudget.wallSpring * (blob.x - 1 + margin) }
            if blob.y < margin { fy += GlowBudget.wallSpring * (margin - blob.y) }
            if blob.y > 1 - margin { fy -= GlowBudget.wallSpring * (blob.y - 1 + margin) }
            for other in blobs.indices where other != index {
                let dx = blob.x - blobs[other].x, dy = blob.y - blobs[other].y
                let d2 = max(1e-4, dx * dx + dy * dy)
                if d2 < GlowBudget.apart * GlowBudget.apart {
                    fx += GlowBudget.repel * dx / d2
                    fy += GlowBudget.repel * dy / d2
                }
            }
            blob.vx = (blob.vx + fx * dt) * decay
            blob.vy = (blob.vy + fy * dt) * decay
            let speed = (blob.vx * blob.vx + blob.vy * blob.vy).squareRoot()
            if speed > GlowBudget.maxSpeed { blob.vx *= GlowBudget.maxSpeed / speed; blob.vy *= GlowBudget.maxSpeed / speed }
            // Centers stay on the canvas: a blob past a corner would color the corner LED alone.
            let inset = GlowBudget.blobInset
            blob.x += blob.vx * dt
            blob.y += blob.vy * dt
            if blob.x < inset || blob.x > 1 - inset { blob.x = min(1 - inset, max(inset, blob.x)); blob.vx = 0 }
            if blob.y < inset || blob.y > 1 - inset { blob.y = min(1 - inset, max(inset, blob.y)); blob.vy = 0 }
            blobs[index] = blob
        }
    }

    /// A heavy kick sends the blob nearest a new place on the edge toward it.
    private func kick(strength: Double) {
        guard strength > 0.01, !blobs.isEmpty else { return }
        let target = LightLayout.edgePoint(lap: place(count: 1, avoiding: [], gap: 0)[0])
        let nearest = blobs.indices.min { Self.distance(blobs[$0], target) < Self.distance(blobs[$1], target) }!
        let dx = target.x - blobs[nearest].x, dy = target.y - blobs[nearest].y
        let length = max(1e-6, (dx * dx + dy * dy).squareRoot())
        blobs[nearest].vx += dx / length * GlowBudget.kickSpeed * strength
        blobs[nearest].vy += dy / length * GlowBudget.kickSpeed * strength
    }

    private static func distance(_ blob: Blob, _ point: (x: Double, y: Double)) -> Double {
        ((blob.x - point.x) * (blob.x - point.x) + (blob.y - point.y) * (blob.y - point.y)).squareRoot()
    }

    /// The one placement rule for every band: each trigger — a kick's target, a mid lift, a
    /// glint — happens at new places round the edge, picked at random (reproducibly), `count`
    /// of them about evenly spaced (each nudged up to `placeJitter` of the spacing), kept `gap`
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

    /// A mid lift, at a new place on the edge; the blob nearest it swells.
    private func addLift(size: Double, reach: Double) {
        guard size > 0.001 else { return }
        let lit = ripples.filter { $0.envelope.level > 0.1 }.map(\.origin)
        var ripple = Ripple(origin: place(count: 1, avoiding: lit, gap: GlowBudget.placeGap)[0], reach: reach)
        ripple.envelope.trigger(size)
        ripples.append(ripple)
        if ripples.count > 12 { ripples.removeFirst() }
        let point = LightLayout.edgePoint(lap: ripple.origin)
        if let nearest = blobs.indices.min(by: { Self.distance(blobs[$0], point) < Self.distance(blobs[$1], point) }) {
            blobs[nearest].swell.trigger(size)
        }
    }

    /// A glint, at a new place.
    private func addGlint(size: Double) {
        guard size > 0.01 else { return }
        let lit = glints.filter { $0.envelope.level > 0.1 }.map(\.place)
        var envelope = FlashEnvelope(attack: GlowBudget.glintAttack, decay: GlowBudget.glintDecay)
        envelope.trigger(size)
        glints.append((place(count: 1, avoiding: lit, gap: GlowBudget.glintGap)[0], 0, envelope))
        if glints.count > 8 { glints.removeFirst() }
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

    /// The most vivid form of an LED color: the same hue with its white taken out (the lowest
    /// channel to 0), or nil for a color too near white to have a hue to deepen.
    static func vivid(_ c: Channels) -> Channels? {
        let high = max(c.0, c.1, c.2), low = min(c.0, c.1, c.2)
        guard high > 0, (high - low) / high >= GlowBudget.hueless else { return nil }
        let span = high - low
        return ((c.0 - low) / span, (c.1 - low) / span, (c.2 - low) / span)
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
