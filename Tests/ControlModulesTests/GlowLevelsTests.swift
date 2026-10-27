import DockCore
import Foundation
import RhythmKit
import Testing
@testable import ControlModules

@Suite struct GlowLevelsTests {
    /// A small lift landing while a big one is still fading must still brighten the light.
    @Test func smallLiftDuringAFadeIsNotSwallowed() {
        var envelope = FlashEnvelope(attack: GlowBudget.liftAttack, decay: GlowBudget.liftDecay)
        let dt = 1.0 / 30
        envelope.trigger(GlowBudget.lift(strength: 1, intensity: 1))
        for _ in 0..<18 { envelope.advance(dt: dt) }   // 0.6 s
        let before = envelope.level
        envelope.trigger(GlowBudget.lift(strength: 0.3, intensity: 1))
        var peak = before
        for _ in 0..<10 {
            envelope.advance(dt: dt)
            peak = max(peak, envelope.level)
        }
        #expect(before > GlowBudget.lift(strength: 0.3, intensity: 1), "the fade is still above the small lift's size")
        #expect(peak > before + 0.08, "before \(before) peak \(peak)")
    }

    /// A flash rises roundly to its full size and falls slowly, with no jump between frames.
    @Test func flashIsSmooth() {
        var envelope = FlashEnvelope(attack: GlowBudget.liftAttack, decay: GlowBudget.liftDecay)
        let dt = 1.0 / 30
        envelope.trigger(1)
        var levels: [Double] = []
        for _ in 0..<60 {
            envelope.advance(dt: dt)
            levels.append(envelope.level)
        }
        let peak = levels.max()!
        let peakFrame = levels.firstIndex(of: peak)!
        #expect(abs(peak - 1) < 0.02, "peak \(peak)")
        #expect((0.08...0.2).contains(Double(peakFrame + 1) * dt), "peak after \(Double(peakFrame + 1) * dt) s")
        let half = levels[peakFrame...].firstIndex { $0 < 0.5 }.map { Double($0 + 1) * dt }
        #expect(half.map { (0.45...0.8).contains($0) } ?? false, "half after \(String(describing: half)) s")
        let steps = zip(levels, levels.dropFirst()).map { abs($1 - $0) }
        #expect(steps.max()! < 0.35, "largest step \(steps.max()!)")
    }

    /// A full flash reaches full brightness; nothing ever goes past it or below the base.
    @Test func brightnessStaysWithinBudget() {
        #expect(GlowBudget.brightness(base: 0.3, flash: GlowBudget.lift(strength: 1, intensity: 1)) == 1)
        for base in stride(from: 0.0, through: 0.6, by: 0.1) {
            for flash in stride(from: 0.0, through: 1, by: 0.1) {
                let value = GlowBudget.brightness(base: base, flash: flash)
                #expect(value >= base && value <= 1)
            }
        }
    }

    /// Heavier hits lift and burn more, and a calm passage (intensity 0) does neither.
    @Test func sizesFollowStrengthAndIntensity() {
        let lifts = [0.2, 0.5, 0.8, 1.0].map { GlowBudget.lift(strength: $0, intensity: 1) }
        #expect(lifts == lifts.sorted() && Set(lifts).count == lifts.count)
        #expect(GlowBudget.lift(strength: 1, intensity: 0) == 0)
    }
}

/// The light show on its canvas, each move on its own.
@MainActor @Suite struct GlowMovesTests {
    let blue = RGB(40, 90, 230), orange = RGB(240, 150, 40)

    /// Runs a glow for `seconds` at 60 fps with a steady snapshot and events at the start.
    func run(_ glow: MusicGlow, seconds: Double, draw: Double = 0, events: [RhythmEvent] = [], from start: Double = 0) -> [[LightPixel]] {
        var snapshot = RhythmSnapshot()
        snapshot.intensity = 1
        snapshot.loudness = Bands(low: 0.5, mid: 0.5, high: 0.5)
        snapshot.lowDraw = draw
        return (1...Int(seconds * 60)).map { frame in
            glow.frame(at: start + Double(frame) / 60, ledCount: 24, input: (frame == 1 ? events : [], snapshot))
        }
    }

    /// Soft colors with room to grow richer.
    let pastel = [Swatch(RGB(130, 160, 230), share: 0.7), Swatch(RGB(240, 190, 140), share: 0.3)]

    func glow(_ layer: MusicGlowLayer = .all, palette: [Swatch]? = nil) -> MusicGlow {
        let glow = MusicGlow(palette: palette ?? [Swatch(blue, share: 0.7), Swatch(orange, share: 0.3)])
        glow.layer = { layer }
        return glow
    }

    func whiteness(_ p: LightPixel) -> Double {
        min(p.channels.0, p.channels.1, p.channels.2) / max(p.channels.0, p.channels.1, p.channels.2)
    }
    func meanWhiteness(_ pixels: [LightPixel]) -> Double {
        LightLayout.ring.reduce(0.0) { $0 + whiteness(pixels[$1]) } / Double(LightLayout.ring.count)
    }

    /// The LEDs sit round a square, in the ring's order: 0 just below the middle of the left
    /// side, 5 mid-front, 10/11 either side of mid-right, 16 mid-back, 21 just above mid-left.
    @Test func ledsSitRoundTheSquare() {
        // Measured corners 2.5 / 8.5 / 13.5 / 19.5: 6 LEDs front and back, 5 left and right.
        let p = LightLayout.position
        func near(_ a: (x: Double, y: Double), x: Double, y: Double) -> Bool { abs(a.x - x) < 1e-9 && abs(a.y - y) < 1e-9 }
        #expect(near(p(0), x: 0, y: 0.5))
        #expect(near(p(5), x: 2.5 / 6, y: 0) && near(p(6), x: 3.5 / 6, y: 0))
        #expect(near(p(11), x: 1, y: 0.5))
        #expect(near(p(16), x: 3.5 / 6, y: 1) && near(p(17), x: 2.5 / 6, y: 1))
        #expect(near(p(21), x: 0, y: 0.7))
        // Between LEDs the edge moves on evenly, round the corners and back to the start.
        #expect(near(LightLayout.edgePoint(lap: 3 / 22), x: 0, y: 0))
        #expect(near(LightLayout.edgePoint(lap: 1), x: 0, y: 0.6))
    }

    /// At rest the main color holds most of the ring, and the canvas keeps moving gently.
    @Test func restShowsTheMainColorAndDrifts() {
        let glow = glow(.flow)
        let frames = run(glow, seconds: 6)
        let rest = frames.last!
        let blueLEDs = LightLayout.ring.filter { rest[$0].channels.2 > rest[$0].channels.0 }.count
        #expect(blueLEDs >= 11, "blue LEDs \(blueLEDs)")
        let moved = zip(frames[0], frames.last!).contains { abs($0.channels.0 - $1.channels.0) > 0.02 }
        #expect(moved, "the colors drift")
    }

    /// The low end's "in": the main color is drawn small onto one place on the edge, uncovering
    /// the white; the light dims and the colors left deepen (against the same glow undrawn).
    @Test func lowDrawPullsTheMainColorIn() {
        let drawn = glow(.draw, palette: pastel), control = glow(.draw, palette: pastel)
        let a = run(drawn, seconds: 3, draw: 1).last!, b = run(control, seconds: 3).last!
        let level = { (pixels: [LightPixel]) in LightLayout.ring.map { pixels[$0].level }.max()! }
        #expect(level(a) < 0.8 * level(b), "dims: \(level(b)) → \(level(a))")
        #expect(a[LightLayout.leftBar].level < b[LightLayout.leftBar].level)
        let edge = min(drawn.main.x, 1 - drawn.main.x, drawn.main.y, 1 - drawn.main.y)
        #expect(edge < 0.02 && drawn.main.radius < 0.3, "drawn onto the edge: \(edge), radius \(drawn.main.radius)")
        #expect(min(control.main.x, 1 - control.main.x, control.main.y, 1 - control.main.y) > 0.15 && control.main.radius > 0.45)
        // The canvas the ring shows: far fewer LEDs keep the main color (its hue, half its chroma).
        let mainColor = OKLab(srgb: pastel[0].color)
        let mainLEDs = { (glow: MusicGlow) in
            glow.shownField.filter { $0.chroma > 0.5 * mainColor.chroma && abs(($0.hue - mainColor.hue).remainder(dividingBy: 2 * .pi)) < 0.6 }.count
        }
        #expect(mainLEDs(drawn) < mainLEDs(control) - 6, "main color on \(mainLEDs(control)) → \(mainLEDs(drawn)) LEDs")
        let deepest = { (pixels: [LightPixel]) in LightLayout.ring.map { self.whiteness(pixels[$0]) }.min()! }
        #expect(deepest(a) < deepest(b) - 0.05, "deepens: \(deepest(b)) → \(deepest(a))")
    }

    /// Let go by the low end, the light springs back past rest — richer — then settles.
    @Test func drawReboundsPastRest() {
        let drawn = glow(.draw, palette: pastel), control = glow(.draw, palette: pastel)
        _ = run(drawn, seconds: 3); _ = run(control, seconds: 3)
        _ = run(drawn, seconds: 0.5, draw: 1, from: 3); _ = run(control, seconds: 0.5, from: 3)
        let difference = zip(run(drawn, seconds: 4, from: 3.5), run(control, seconds: 4, from: 3.5)).map { meanWhiteness($0) - meanWhiteness($1) }
        #expect(difference.prefix(90).min()! < -0.02, "richest against undrawn: \(difference.prefix(90).min()!)")
        #expect(abs(difference.last!) < 0.02, "settled against undrawn: \(difference.last!)")
    }

    /// The snare's "out": the light brightens from one place on the edge — a light snare in its
    /// own colors — and only there: far round the ring the light is as it was.
    @Test func midLiftsBrightenInPlace() {
        let lifted = glow(.lift, palette: pastel), control = glow(.lift, palette: pastel)
        _ = run(lifted, seconds: 3); _ = run(control, seconds: 3)
        let a = run(lifted, seconds: 0.15, events: [.lift(time: 3, band: .mid, strength: 0.2, heavy: true)], from: 3).last!
        let b = run(control, seconds: 0.15, from: 3).last!
        let lit = LightLayout.ring.filter { a[$0].level > b[$0].level + 0.2 }
        #expect(lit.count >= 3, "LEDs lifted: \(lit.count)")
        #expect(lit.allSatisfy { whiteness(a[$0]) <= whiteness(b[$0]) + 0.05 })
        let origin = lifted.liftPlaces.last!
        for (slot, led) in LightLayout.ring.enumerated() {
            let d = abs((Double(slot) + 0.5) / Double(LightLayout.ring.count) - origin)
            guard min(d, 1 - d) > 0.35 else { continue }
            #expect(abs(a[led].level - b[led].level) < 1e-4, "LED \(led) brightened far from the lift")
        }
    }

    /// A light mid hit only glows: a little brighter, its color more saturated, never white —
    /// far less than a heavy one.
    @Test func lightMidHitsOnlyGlow() {
        func rise(heavy: Bool) -> (level: Double, whiter: Double) {
            let lifted = glow(.lift, palette: pastel), control = glow(.lift, palette: pastel)
            _ = run(lifted, seconds: 3); _ = run(control, seconds: 3)
            let a = run(lifted, seconds: 0.15, events: [.lift(time: 3, band: .mid, strength: 1, heavy: heavy)], from: 3).last!
            let b = run(control, seconds: 0.15, from: 3).last!
            let peak = LightLayout.ring.max { a[$0].level - b[$0].level < a[$1].level - b[$1].level }!
            return (a[peak].level - b[peak].level, whiteness(a[peak]) - whiteness(b[peak]))
        }
        let light = rise(heavy: false), heavy = rise(heavy: true)
        #expect(light.level > 0.05 && light.level < 0.4 * heavy.level, "light \(light.level), heavy \(heavy.level)")
        #expect(light.whiter < -0.02, "more saturated: \(light.whiter)")
    }

    /// With the low end quiet, a heavy snare flashes near-white at its peak: bright and low in color.
    @Test func heavySnaresFlashWhite() {
        let lifted = glow(.lift), control = glow(.lift)
        _ = run(lifted, seconds: 3); _ = run(control, seconds: 3)
        let a = run(lifted, seconds: 0.15, events: [.lift(time: 3, band: .mid, strength: 1, heavy: true)], from: 3).last!
        let b = run(control, seconds: 0.15, from: 3).last!
        let peak = LightLayout.ring.max { a[$0].level - b[$0].level < a[$1].level - b[$1].level }!
        #expect(a[peak].level > 0.9, "bright: \(a[peak].level)")
        #expect(whiteness(a[peak]) > whiteness(b[peak]) + 0.1, "whitish: \(whiteness(b[peak])) → \(whiteness(a[peak]))")
    }

    /// Held drawn, the main blob stays on the edge where it faces, and that place drifts slowly
    /// along the edge with it — never a jump.
    @Test func pullDriftsAlongTheEdge() async {
        let glow = glow(.draw)
        _ = run(glow, seconds: 3, draw: 1)
        var places: [(x: Double, y: Double)] = []
        for second in 0..<600 {
            if second % 10 == 0 { await Task.yield() }
            _ = run(glow, seconds: 1.0 / 60, draw: 1, from: 3 + Double(second) / 60)
            places.append((glow.main.x, glow.main.y))
        }
        #expect(places.allSatisfy { min($0.x, 1 - $0.x, $0.y, 1 - $0.y) < 0.02 }, "on the edge")
        let steps = zip(places, places.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        #expect(steps.max()! < 0.01, "largest step a frame \(steps.max()!)")
        #expect(hypot(places.last!.x - places[0].x, places.last!.y - places[0].y) > 0.1, "it drifts")
    }

    /// The draw dims what the ring sends out — the white it uncovers included (on a saturated
    /// cover it sends out more light than the color it replaces).
    @Test func drawDimsTheLightSentOut() {
        let red = [Swatch(RGB(230, 30, 40), share: 0.8), Swatch(RGB(40, 60, 220), share: 0.2)]
        let drawn = glow(.draw, palette: red), control = glow(.draw, palette: red)
        let a = run(drawn, seconds: 3, draw: 1).last!, b = run(control, seconds: 3).last!
        let light = { (pixels: [LightPixel]) in
            LightLayout.ring.reduce(0.0) { sum, led in
                let p = pixels[led], drive = LEDOutput.drive(p.level)
                return sum + drive * (0.2126 * p.channels.0 + 0.7152 * p.channels.1 + 0.0722 * p.channels.2)
            }
        }
        #expect(light(a) < 0.7 * light(b), "light sent out: \(light(b)) → \(light(a))")
    }

    /// The other colors glide in wide arcs: their velocity never jerks, and they turn round well
    /// before the edge instead of running into it.
    @Test func blobsGlideWithoutBouncing() async {
        let glow = MusicGlow(palette: [Swatch(RGB(230, 60, 40), share: 0.4), Swatch(RGB(40, 90, 230), share: 0.25),
                                       Swatch(RGB(240, 200, 40), share: 0.2), Swatch(RGB(40, 180, 90), share: 0.15)])
        glow.layer = { .flow }
        var snapshot = RhythmSnapshot()
        snapshot.intensity = 1
        var previous = glow.blobs.map { ($0.vx, $0.vy) }, jerk = 0.0, nearest = 1.0
        for frame in 1...3600 {
            if frame % 10 == 0 { await Task.yield() }   // long: let other tests on the main actor run
            _ = glow.frame(at: Double(frame) / 60, ledCount: 24, input: ([], snapshot))
            let now = glow.blobs.map { ($0.vx, $0.vy) }
            if frame > 60 { jerk = max(jerk, zip(previous, now).map { hypot($1.0 - $0.0, $1.1 - $0.1) * 60 }.max()!) }
            previous = now
            nearest = min(nearest, glow.blobs.map { min($0.x, 1 - $0.x, $0.y, 1 - $0.y) }.min()!)
        }
        #expect(jerk < 1.0, "largest acceleration \(jerk) /s²")
        #expect(nearest > GlowBudget.blobInset + 0.02, "closest to the edge \(nearest)")
    }

    /// The other colors take turns in front, like cards shuffled — every one of them, round and
    /// round, faster in a busy passage.
    @Test func otherColorsShuffleToTheFront() {
        func fronts(intensity: Double, seconds: Double) -> (seen: Set<Int>, changes: Int) {
            let glow = MusicGlow(palette: [Swatch(RGB(230, 60, 40), share: 0.4), Swatch(RGB(40, 90, 230), share: 0.25),
                                           Swatch(RGB(240, 200, 40), share: 0.2), Swatch(RGB(40, 180, 90), share: 0.15)])
            glow.layer = { .flow }
            var snapshot = RhythmSnapshot()
            snapshot.intensity = intensity
            var seen = Set<Int>(), changes = 0, last: Int?
            for frame in 1...Int(seconds * 60) {
                _ = glow.frame(at: Double(frame) / 60, ledCount: 24, input: ([], snapshot))
                let front = glow.blobs.indices.max { glow.blobs[$0].depth < glow.blobs[$1].depth }!
                seen.insert(front)
                if let last, last != front { changes += 1 }
                last = front
            }
            return (seen, changes)
        }
        let busy = fronts(intensity: 1, seconds: 6), calm = fronts(intensity: 0, seconds: 6)
        #expect(busy.seen.count == 3 && busy.changes >= 6, "busy: \(busy)")
        #expect(calm.changes < busy.changes / 2, "calm \(calm.changes), busy \(busy.changes)")
    }

    /// The other colors roll slowly in a calm passage and tumble in a busy one.
    @Test func tumblingFollowsTheRhythm() async {
        func speed(intensity: Double) async -> Double {
            let glow = glow(.flow)
            var snapshot = RhythmSnapshot()
            snapshot.intensity = intensity
            var total = 0.0, previous = glow.blobs.map { ($0.x, $0.y) }
            for frame in 1...600 {
                if frame % 10 == 0 { await Task.yield() }
                _ = glow.frame(at: Double(frame) / 60, ledCount: 24, input: ([], snapshot))
                let now = glow.blobs.map { ($0.x, $0.y) }
                if frame > 180 { total += zip(previous, now).map { hypot($1.0 - $0.0, $1.1 - $0.1) }.reduce(0, +) }
                previous = now
            }
            return total
        }
        let calm = await speed(intensity: 0), busy = await speed(intensity: 1)
        #expect(busy > 3 * calm, "calm \(calm), busy \(busy)")
    }

    /// The main blob is the biggest color with a hue: a white taking more of the cover never leads.
    @Test func mainColorIsNeverWhite() {
        let glow = MusicGlow(palette: [Swatch(RGB(222, 222, 222), share: 0.5), Swatch(orange, share: 0.2), Swatch(blue, share: 0.3)])
        #expect(glow.main.color.distance(to: OKLab(srgb: blue)) < 1e-9)
        let white = MusicGlow(palette: [Swatch(RGB(240, 240, 240), share: 1)])
        #expect(white.main.color.chroma < 0.02, "an all-white cover stays white")
    }

    /// However small the main blob is drawn, neighbouring LEDs never differ by more than
    /// `GlowBudget.ledStep`: its color fades in over several LEDs, never a hand-over from one to the next.
    @Test func neighboursBlendWhileDrawn() async {
        // A strong main color on one other; and four colors, three of them shuffling in front
        // of each other at full speed.
        let palettes = [
            [Swatch(RGB(230, 30, 40), share: 0.8), Swatch(RGB(40, 60, 220), share: 0.2)],
            [Swatch(RGB(230, 60, 40), share: 0.4), Swatch(RGB(40, 90, 230), share: 0.25),
             Swatch(RGB(240, 200, 40), share: 0.2), Swatch(RGB(40, 180, 90), share: 0.15)],
        ]
        for palette in palettes {
            let glow = MusicGlow(palette: palette)
            glow.layer = { .draw }
            var snapshot = RhythmSnapshot()
            snapshot.intensity = 1
            var largest = 0.0
            for frame in 1...1800 {
                if frame % 10 == 0 { await Task.yield() }   // long: let other tests on the main actor run
                snapshot.lowDraw = frame % 120 < 60 ? 1 : 0
                _ = glow.frame(at: Double(frame) / 60, ledCount: 24, input: ([], snapshot))
                let field = glow.shownField
                largest = max(largest, field.indices.map { field[$0].distance(to: field[($0 + 1) % field.count]) }.max()!)
            }
            #expect(largest <= GlowBudget.ledStep, "\(palette.count) colors: largest step between neighbours \(largest)")
        }
    }

    /// What the LEDs finally send out — deepened, lit — never steps between neighbours either,
    /// even on a cover whose colors sit right at the edge of having a hue (a near-white pink and
    /// a greyish one: 旺仔小乔《千年泪》).
    @Test func outputBlendsBetweenNeighbours() async {
        let glow = MusicGlow(palette: [Swatch(RGB(hex: "#E7DAE0"), share: 0.91), Swatch(RGB(hex: "#AF8895"), share: 0.09)])
        glow.layer = { .draw }
        var snapshot = RhythmSnapshot()
        snapshot.intensity = 1
        var largest = 0.0
        for frame in 1...1800 {
            if frame % 10 == 0 { await Task.yield() }   // long: let other tests on the main actor run
            snapshot.lowDraw = frame % 120 < 60 ? 1 : 0
            let pixels = glow.frame(at: Double(frame) / 60, ledCount: 24, input: ([], snapshot))
            // The light sent out, as a color: channels × drive, in OKLab.
            let sent = LightLayout.ring.map { led -> OKLab in
                let p = pixels[led], drive = LEDOutput.drive(p.level)
                return OKLab(linear: (p.channels.0 * drive, p.channels.1 * drive, p.channels.2 * drive))
            }
            largest = max(largest, sent.indices.map { sent[$0].distance(to: sent[($0 + 1) % sent.count]) }.max()!)
        }
        #expect(largest <= GlowBudget.ledStep, "largest step sent out between neighbours \(largest)")
    }

    /// A new album with a different number of colors keeps the blobs where they were: only
    /// the colors change, and a blob added or dropped fades in or out.
    @Test func newAlbumKeepsTheBlobsInPlace() {
        let glow = glow(.flow, palette: [Swatch(blue, share: 0.4), Swatch(orange, share: 0.3), Swatch(RGB(40, 180, 90), share: 0.3)])
        _ = run(glow, seconds: 3)
        let before = glow.blobs.map { ($0.x, $0.y) }
        glow.setPalette([Swatch(RGB(230, 40, 50), share: 0.4), Swatch(blue, share: 0.2), Swatch(orange, share: 0.2), Swatch(RGB(240, 200, 40), share: 0.2)])
        #expect(glow.blobs.count == 3)
        #expect(zip(before, glow.blobs).allSatisfy { $0.0 == $1.x && $0.1 == $1.y }, "the blobs there before stay put")
    }

    /// Whatever plays — drawn deep, rebounding, heavy and light mid hits — on a cover of pure
    /// colors, nothing sent out is more saturated than `GlowBudget.maxSaturation`.
    @Test func saturationStaysUnderTheCap() async {
        let glow = MusicGlow(palette: [Swatch(RGB(255, 0, 0), share: 0.5), Swatch(RGB(0, 0, 255), share: 0.3), Swatch(RGB(0, 255, 0), share: 0.2)])
        var snapshot = RhythmSnapshot()
        snapshot.intensity = 1
        snapshot.loudness = Bands(low: 0.5, mid: 0.5, high: 0.5)
        var most = 0.0
        for frame in 1...1200 {
            if frame % 10 == 0 { await Task.yield() }   // long: let other tests on the main actor run
            let time = Double(frame) / 60
            snapshot.lowDraw = frame % 120 < 60 ? 1 : 0
            var events: [RhythmEvent] = []
            if frame % 30 == 0 { events.append(.lift(time: time, band: .mid, strength: 1, heavy: frame % 60 == 0)) }
            let pixels = glow.frame(at: time, ledCount: 24, input: (events, snapshot))
            for p in pixels {
                let high = max(p.channels.0, p.channels.1, p.channels.2), low = min(p.channels.0, p.channels.1, p.channels.2)
                if high > 0 { most = max(most, (high - low) / high) }
            }
        }
        #expect(most <= GlowBudget.maxSaturation + 1e-9, "most saturated sent out: \(most)")
        #expect(most > GlowBudget.maxSaturation - 0.02, "and the cap is reached: \(most)")
    }

    /// Only the low end moves the blobs: kicks and mid lifts leave them where they would be.
    @Test func onlyTheLowEndMovesTheBlobs() {
        let hit = glow(), control = glow()
        _ = run(hit, seconds: 1); _ = run(control, seconds: 1)
        _ = run(hit, seconds: 1, events: [.kick(time: 1, strength: 1), .lift(time: 1, band: .mid, strength: 1, heavy: true)], from: 1)
        _ = run(control, seconds: 1, from: 1)
        #expect(hit.main.x == control.main.x && hit.main.y == control.main.y && hit.main.radius == control.main.radius)
        #expect(zip(hit.blobs, control.blobs).allSatisfy { $0.x == $1.x && $0.y == $1.y })
    }

    /// Under the drums, cymbals stay dark: glints are for cymbals heard on their own.
    @Test func glintsWaitForTheDrumsToStop() {
        let glow = glow(.high)
        let before = run(glow, seconds: 1).last!
        let busy = run(glow, seconds: 0.05, events: [.lift(time: 1, band: .mid, strength: 1, heavy: true), .lift(time: 1, band: .high, strength: 1, heavy: false)], from: 1).last!
        #expect(LightLayout.ring.allSatisfy { busy[$0].level < before[$0].level + 0.05 }, "no glint right after a snare")
    }

    /// A cymbal is a crisp, whitish point.
    @Test func highHitsGlint() {
        let glinting = glow(.high), control = glow(.high)
        _ = run(glinting, seconds: 1); _ = run(control, seconds: 1)
        let peak = run(glinting, seconds: 0.05, events: [.lift(time: 1, band: .high, strength: 1, heavy: false)], from: 1).last!
        let before = run(control, seconds: 0.05, from: 1).last!
        let rises = LightLayout.ring.map { peak[$0].level - before[$0].level }
        let lit = rises.filter { $0 > 0.15 }.count
        #expect((1...3).contains(lit), "LEDs lit by the glint: \(lit)")
        let spot = LightLayout.ring[rises.firstIndex(of: rises.max()!)!]
        #expect(whiteness(peak[spot]) > whiteness(before[spot]) + 0.05)
    }

    /// Deepening takes a pale color to the vivid form of its hue; white stays white without a hue to give.
    @Test func vividKeepsTheHueAndTakesOutTheWhite() {
        let pale = MusicGlow.vivid((1, 0.8, 0.7))
        #expect(pale.channels.0 == 1 && pale.channels.2 == 0 && abs(pale.channels.1 - 1.0 / 3) < 1e-9 && pale.hue == 1)
        #expect(MusicGlow.vivid((1, 1, 1)).hue == 0)
        #expect(MusicGlow.vivid((1, 0.97, 0.96)).hue < 0.01, "near white barely deepens")
        let edge = (MusicGlow.vivid((1, 0.855, 0.855)).hue, MusicGlow.vivid((1, 0.845, 0.845)).hue)
        #expect(abs(edge.0 - edge.1) < 0.1, "no step across the old line: \(edge)")
    }

    /// Drawn in and let go twice a second, no LED ever switches color at once: every step is a blend.
    @Test func ledsNeverSwitchColorAtOnce() async {
        let glow = MusicGlow(palette: [Swatch(RGB(40, 90, 230), share: 0.5), Swatch(RGB(240, 150, 40), share: 0.5)])
        glow.layer = { .draw }
        var snapshot = RhythmSnapshot()
        snapshot.intensity = 1
        var previous: [OKLab] = [], largest = 0.0
        for frame in 1...1800 {
            if frame % 10 == 0 { await Task.yield() }   // long: let other tests on the main actor run
            snapshot.lowDraw = frame % 30 < 15 ? 1 : 0
            _ = glow.frame(at: Double(frame) / 60, ledCount: 24, input: ([], snapshot))
            if !previous.isEmpty { largest = max(largest, zip(previous, glow.shownField).map { $0.distance(to: $1) }.max()!) }
            previous = glow.shownField
        }
        #expect(largest <= GlowBudget.colorRate / 60 + 1e-9, "largest step in a frame \(largest)")
    }

    /// Blending opposite hues near half and half goes through a soft in-between, never a fast swing.
    @Test func oppositeHuesBlendSmoothly() {
        // Exactly opposite: the plain average passes through grey, its hue flipping at half and half.
        let one = OKLab(l: 0.7, chroma: 0.15, hue: 1.0), other = OKLab(l: 0.7, chroma: 0.15, hue: 1.0 + .pi)
        var previous: OKLab?, largest = 0.0
        for step in 0...201 {
            let w = Double(step) / 201
            let color = OKLab.blend([one, other], weights: [1 - w, w], keepChroma: GlowBudget.keepChroma)
            if let previous { largest = max(largest, previous.distance(to: color)) }
            previous = color
        }
        #expect(largest < 0.02, "largest step for 0.5 % of weight: \(largest)")
    }

    /// A minute of four colors and the white, drawn in and let go twice a second: no LED ever
    /// stands alone.
    @Test func noLoneLEDs() async {
        let glow = MusicGlow(palette: [Swatch(RGB(230, 60, 40), share: 0.4), Swatch(RGB(40, 90, 230), share: 0.25),
                                       Swatch(RGB(240, 200, 40), share: 0.2), Swatch(RGB(40, 180, 90), share: 0.15)])
        glow.layer = { .draw }
        var snapshot = RhythmSnapshot()
        snapshot.intensity = 1
        for frame in 1...3600 {
            if frame % 10 == 0 { await Task.yield() }   // long: let other tests on the main actor run
            snapshot.lowDraw = frame % 30 < 15 ? 1 : 0
            _ = glow.frame(at: Double(frame) / 60, ledCount: 24, input: ([], snapshot))
            #expect(!MusicGlow.hasLoneLED(glow.shownField), "frame \(frame)")
            if MusicGlow.hasLoneLED(glow.shownField) { break }
        }
    }
}
