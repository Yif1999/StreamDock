import DockCore
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

    /// The low end's "in": the light dims and the color deepens (against the same glow undrawn).
    @Test func lowDrawDimsAndDeepens() {
        let drawn = glow(.draw, palette: pastel), control = glow(.draw, palette: pastel)
        let a = run(drawn, seconds: 3, draw: 1).last!, b = run(control, seconds: 3).last!
        let level = { (pixels: [LightPixel]) in LightLayout.ring.map { pixels[$0].level }.max()! }
        #expect(level(a) < 0.8 * level(b), "dims: \(level(b)) → \(level(a))")
        #expect(meanWhiteness(a) < meanWhiteness(b) - 0.05, "deepens: \(meanWhiteness(b)) → \(meanWhiteness(a))")
        #expect(a[LightLayout.leftBar].level < b[LightLayout.leftBar].level)
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
        _ = run(lifted, seconds: 1); _ = run(control, seconds: 1)
        let a = run(lifted, seconds: 0.15, events: [.lift(time: 1, band: .mid, strength: 0.2)], from: 1).last!
        let b = run(control, seconds: 0.15, from: 1).last!
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

    /// A heavy snare flashes near-white at its peak: bright and low in color.
    @Test func heavySnaresFlashWhite() {
        let lifted = glow(.lift), control = glow(.lift)
        _ = run(lifted, seconds: 1); _ = run(control, seconds: 1)
        let a = run(lifted, seconds: 0.12, events: [.lift(time: 1, band: .mid, strength: 1)], from: 1).last!
        let b = run(control, seconds: 0.12, from: 1).last!
        let peak = LightLayout.ring.max { a[$0].level - b[$0].level < a[$1].level - b[$1].level }!
        #expect(a[peak].level > 0.9, "bright: \(a[peak].level)")
        #expect(whiteness(a[peak]) > whiteness(b[peak]) + 0.1, "whitish: \(whiteness(b[peak])) → \(whiteness(a[peak]))")
    }

    /// A heavy kick sends a blob off: the colors move more than they would have.
    @Test func kicksSendABlob() {
        let kicked = glow(.flow), control = glow(.flow)
        _ = run(kicked, seconds: 1); _ = run(control, seconds: 1)
        let speed = { (glow: MusicGlow) in glow.blobs.map { ($0.vx * $0.vx + $0.vy * $0.vy).squareRoot() }.max()! }
        _ = run(kicked, seconds: 0.05, events: [.kick(time: 1, strength: 1)], from: 1)
        _ = run(control, seconds: 0.05, from: 1)
        #expect(speed(kicked) > speed(control) + 0.3, "\(speed(control)) → \(speed(kicked))")
    }

    /// Under the drums, cymbals stay dark: glints are for cymbals heard on their own.
    @Test func glintsWaitForTheDrumsToStop() {
        let glow = glow(.high)
        let before = run(glow, seconds: 1).last!
        let busy = run(glow, seconds: 0.05, events: [.lift(time: 1, band: .mid, strength: 1), .lift(time: 1, band: .high, strength: 1)], from: 1).last!
        #expect(LightLayout.ring.allSatisfy { busy[$0].level < before[$0].level + 0.05 }, "no glint right after a snare")
    }

    /// A cymbal is a crisp, whitish point.
    @Test func highHitsGlint() {
        let glinting = glow(.high), control = glow(.high)
        _ = run(glinting, seconds: 1); _ = run(control, seconds: 1)
        let peak = run(glinting, seconds: 0.05, events: [.lift(time: 1, band: .high, strength: 1)], from: 1).last!
        let before = run(control, seconds: 0.05, from: 1).last!
        let rises = LightLayout.ring.map { peak[$0].level - before[$0].level }
        let lit = rises.filter { $0 > 0.15 }.count
        #expect((1...3).contains(lit), "LEDs lit by the glint: \(lit)")
        let spot = LightLayout.ring[rises.firstIndex(of: rises.max()!)!]
        #expect(whiteness(peak[spot]) > whiteness(before[spot]) + 0.05)
    }

    /// Deepening takes a pale color to the vivid form of its hue; white stays white without a hue to give.
    @Test func vividKeepsTheHueAndTakesOutTheWhite() {
        let pale = MusicGlow.vivid((1, 0.8, 0.7))!
        #expect(pale.0 == 1 && pale.2 == 0 && abs(pale.1 - 1.0 / 3) < 1e-9)
        #expect(MusicGlow.vivid((1, 0.95, 0.92)) == nil)
    }

    /// Kicked hard twice a second, no LED ever switches color at once: every step is a blend.
    @Test func ledsNeverSwitchColorAtOnce() {
        let glow = MusicGlow(palette: [Swatch(RGB(40, 90, 230), share: 0.5), Swatch(RGB(240, 150, 40), share: 0.5)])
        glow.layer = { .flow }
        var snapshot = RhythmSnapshot()
        snapshot.intensity = 1
        var previous: [OKLab] = [], largest = 0.0
        for frame in 1...1800 {
            let events: [RhythmEvent] = frame % 30 == 0 ? [.kick(time: Double(frame) / 60, strength: 1)] : []
            _ = glow.frame(at: Double(frame) / 60, ledCount: 24, input: (events, snapshot))
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

    /// A minute of four colors and the white, kicked twice a second: no LED ever stands alone.
    @Test func noLoneLEDs() {
        let glow = MusicGlow(palette: [Swatch(RGB(230, 60, 40), share: 0.4), Swatch(RGB(40, 90, 230), share: 0.25),
                                       Swatch(RGB(240, 200, 40), share: 0.2), Swatch(RGB(40, 180, 90), share: 0.15)])
        glow.layer = { .flow }
        var snapshot = RhythmSnapshot()
        snapshot.intensity = 1
        for frame in 1...3600 {
            let events: [RhythmEvent] = frame % 30 == 0 ? [.kick(time: Double(frame) / 60, strength: 1)] : []
            _ = glow.frame(at: Double(frame) / 60, ledCount: 24, input: (events, snapshot))
            #expect(!MusicGlow.hasLoneLED(glow.shownField), "frame \(frame)")
            if MusicGlow.hasLoneLED(glow.shownField) { break }
        }
    }
}
