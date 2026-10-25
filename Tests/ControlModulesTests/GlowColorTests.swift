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

    /// The strip shows the cover's own colors: nothing lifted, nothing invented.
    @Test func paletteKeepsTheCoversOwnColors() {
        func cover(_ parts: [(RGB, Int)]) -> [OKLab] { parts.flatMap { Array(repeating: OKLab(srgb: $0.0), count: $0.1) } }
        // A grey-green cover with a few vivid pixels: a faintly tinted white, never their blue.
        let grey = ArtworkPalette.palette(from: cover([(RGB(205, 215, 210), 990), (RGB(20, 110, 220), 10)])).map(OKLab.init(srgb:))
        #expect(grey.count == 2 && grey.allSatisfy { $0.chroma < 0.03 }, "\(grey.map(\.chroma))")
        // Red over white: the red as it is, then a white for the white area.
        let red = RGB(180, 40, 50)
        let redWhite = ArtworkPalette.palette(from: cover([(red, 600), (RGB(245, 240, 235), 400)])).map(OKLab.init(srgb:))
        #expect(redWhite.count == 2 && abs(redWhite[0].chroma - OKLab(srgb: red).chroma) < 0.01 && redWhite[1].chroma < 0.03)
        // Near-black gives no light: a small blue patch on black is the whole palette, with a paler shade of itself.
        let blue = ArtworkPalette.palette(from: cover([(RGB(8, 8, 10), 900), (RGB(30, 80, 200), 100)])).map(OKLab.init(srgb:))
        #expect(blue.count == 2 && abs(blue[0].hue - blue[1].hue) < 0.01 && blue[1].chroma < blue[0].chroma)
        // A dark green still counts by its area, not its darkness.
        let green = ArtworkPalette.palette(from: cover([(RGB(20, 60, 30), 500), (RGB(240, 240, 240), 500)])).map(OKLab.init(srgb:))
        #expect(green.contains { $0.chroma > 0.05 && abs($0.hue - OKLab(srgb: RGB(20, 60, 30)).hue) < 0.1 })
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
    /// Paused, the glow eases down (no jump) to the quietest playing level and breathes there.
    @Test func pauseSettlesIntoABreath() {
        let glow = MusicGlow(palette: [RGB(40, 90, 230), RGB(240, 150, 40)])
        var snapshot = RhythmSnapshot()
        snapshot.intensity = 1
        // Perceived brightness: the brightest ring LED (a blob's center) and a short bar.
        var time = 0.0
        var bars: [Double] = []
        func run(_ frames: Int) -> [Double] {
            (0..<frames).map { _ in
                time += 1.0 / 30
                let pixels = glow.frame(at: time, ledCount: 24, input: ([], snapshot))
                bars.append(pixels[LightLayout.leftBar].level)
                return LightLayout.ring.map { pixels[$0].level }.max()!
            }
        }
        // The quietest playing: full intensity, silence.
        snapshot.loudness = Bands()
        let floor = run(90).suffix(30).reduce(0, +) / 30
        let barFloor = bars.suffix(30).reduce(0, +) / 30
        snapshot.loudness = Bands(low: 0.8, mid: 0.8, high: 0.8)
        let playing = run(60)
        glow.playing = false
        bars = []
        let paused = run(360)
        // Paused keeps the light at the quietest playing level, breathing gently around it.
        let settled = paused.suffix(180).reduce(0, +) / 180
        let barSettled = bars.suffix(180).reduce(0, +) / 180
        #expect(abs(settled - floor) < 0.02, "floor \(floor) paused \(settled)")
        #expect(abs(barSettled - barFloor) < 0.02, "bar floor \(barFloor) paused \(barSettled)")
        #expect(settled < playing.last!)
        let steps = zip([playing.last!] + paused, paused).map { abs($1 - $0) / playing.last! }
        #expect(steps.max()! < 0.08, "largest step \(steps.max()!)")
    }
}
