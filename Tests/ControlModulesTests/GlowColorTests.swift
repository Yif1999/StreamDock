import DockCore
import Foundation
import RhythmKit
import Testing
@testable import ControlModules

@Suite struct GlowColorTests {
    @Test func oklabRoundTrips() {
        for color in [RGB(255, 0, 0), RGB(30, 120, 220), RGB(250, 200, 40), RGB(128, 128, 128)] {
            let back = OKLab(srgb: color).srgb
            #expect(abs(Int(back.red) - Int(color.red)) <= 1 && abs(Int(back.green) - Int(color.green)) <= 1 && abs(Int(back.blue) - Int(color.blue)) <= 1, "\(color.hex) → \(back.hex)")
        }
    }

    /// Blue and orange meet in a clean in-between, not the grey a plain average gives.
    @Test func blendKeepsColorsVivid() {
        let blue = OKLab(srgb: RGB(40, 90, 230)), orange = OKLab(srgb: RGB(240, 150, 40))
        let plain = OKLab.blend([blue, orange], weights: [1, 1], keepChroma: 0)
        let kept = OKLab.blend([blue, orange], weights: [1, 1], keepChroma: GlowBudget.keepChroma)
        #expect(kept.chroma > plain.chroma * 2, "plain \(plain.chroma) kept \(kept.chroma)")
    }

    @Test func gradingNeverLeavesAPaletteDull() {
        // Black-and-white artwork: a soft warm white pair.
        let none = ArtworkPalette.refine([])
        #expect(none.count == 2)
        // One washed-out blue-grey: vivid enough, plus an analogous partner.
        let single = ArtworkPalette.refine([RGB(110, 120, 140)]).map(OKLab.init(srgb:))
        #expect(single.count == 2)
        #expect(single.allSatisfy { $0.chroma >= ArtworkPalette.minChroma * 0.75 }, "\(single.map(\.chroma))")
        #expect(abs(single[0].hue - single[1].hue) > 0.3)
        // Dark brown becomes a vivid amber of the same hue.
        let brown = OKLab(srgb: RGB(90, 55, 25))
        let amber = OKLab(srgb: ArtworkPalette.refine([RGB(90, 55, 25)])[0])
        #expect(amber.chroma > brown.chroma && abs(amber.hue - brown.hue) < 0.1)
    }

    /// A light accent stays local, a heavy one fills the ring.
    @Test func heavyAccentsSpreadFurther() {
        let light = GlowBudget.reach(strength: 0.3), heavy = GlowBudget.reach(strength: 1)
        #expect(GlowBudget.spreadProfile(distance: 0.5, reach: heavy, age: 0.6) > 0.6)
        #expect(GlowBudget.spreadProfile(distance: 0.5, reach: light, age: 0.6) < 0.05)
        #expect(GlowBudget.spreadProfile(distance: 0, reach: light, age: 0) > 0.99)
    }
}

@MainActor @Suite struct PauseTests {
    /// Paused, the glow eases down into a dim breath (no jump), and comes back when playing.
    @Test func pauseSettlesIntoABreath() {
        let glow = MusicGlow(palette: [RGB(40, 90, 230), RGB(240, 150, 40)])
        var snapshot = RhythmSnapshot()
        snapshot.intensity = 1
        snapshot.loudness = Bands(low: 0.8, mid: 0.8, high: 0.8)
        func level(_ frame: [RGB]) -> Double { Double(frame.map { Int($0.red) + Int($0.green) + Int($0.blue) }.reduce(0, +)) }
        var output = LEDOutput()
        var time = 0.0
        var playing: [Double] = []
        for _ in 0..<90 {
            time += 1.0 / 30
            playing.append(level(output.render(glow.frame(at: time, ledCount: 24, input: ([], snapshot)))))
        }
        glow.playing = false
        var paused: [Double] = []
        for _ in 0..<150 {
            time += 1.0 / 30
            paused.append(level(output.render(glow.frame(at: time, ledCount: 24, input: ([], snapshot)))))
        }
        let settled = paused.suffix(30).reduce(0, +) / 30
        #expect(settled < 0.6 * playing.last!, "playing \(playing.last!) paused \(settled)")
        let steps = zip([playing.last!] + paused, paused).map { abs($1 - $0) / playing.last! }
        #expect(steps.max()! < 0.08, "largest step \(steps.max()!)")
    }
}
