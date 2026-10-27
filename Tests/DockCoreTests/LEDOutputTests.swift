import Foundation
import Testing
@testable import DockCore

struct LEDOutputTests {
    /// Dim, a pale color keeps its small channels lit — never rounded off into its pure hue —
    /// while a pure color's missing channels stay off.
    @Test func dimColorsKeepTheirSmallChannels() {
        var output = LEDOutput()
        let dim = 0.15   // the brightest channel ≈ 4/255
        let pale = output.render([LightPixel(channels: (1, 0.1, 0.1), level: dim)])[0]
        #expect(pale.red >= 1 && pale.green >= 1 && pale.blue >= 1, "\(pale)")
        let pure = output.render([LightPixel(channels: (1, 0, 0), level: dim)])[0]
        #expect(pure.red >= 1 && pure.green == 0 && pure.blue == 0, "\(pure)")
        let off = output.render([LightPixel(channels: (1, 0.1, 0.1), level: 0)])[0]
        #expect(off.red == 0 && off.green == 0 && off.blue == 0)
    }

    /// A value hovering between two 8-bit steps at the dim end must not flicker.
    @Test func dimLightDoesNotFlicker() {
        var output = LEDOutput()
        let hover = pow(2.5 / 255, 1 / LEDOutput.gamma)
        var shown: [UInt8] = []
        for index in 0..<60 {
            let level = hover * (1 + 0.004 * sin(Double(index)))
            shown.append(output.render([LightPixel(channels: (1, 1, 1), level: level)])[0].red)
        }
        #expect(Set(shown.dropFirst()).count == 1, "values \(Set(shown))")
    }

    /// Perceived brightness is gamma-mapped: half perceived is far less than half drive.
    @Test func brightnessIsPerceptual() {
        var output = LEDOutput()
        #expect(output.render([LightPixel(channels: (1, 1, 1), level: 1)])[0].red == 255)
        #expect(output.render([LightPixel(channels: (1, 1, 1), level: 0.5)])[0].red < 64)
    }

    @Test func combinedGainIsMappedOnceAndKeepsChannelRatios() {
        var output = LEDOutput()
        let pixel = LightPixel(channels: (1, 0.5, 0), level: 0.5)
        let color = output.render([pixel], gain: 0.5)[0]
        #expect(color == RGB(12, 6, 0)) // pow(0.5 × 0.5, 2.2), not repeated gamma.
        #expect(output.render([pixel], gain: 0)[0] == .black)
        #expect(output.render([LightPixel(.white)], gain: 1)[0] == .white)
    }
    /// A color code lights the LEDs in the proportions a screen shows it: sRGB decoded first.
    @Test func colorsAreDecodedLikeAScreen() {
        let orange = LightPixel(RGB(255, 128, 0))
        #expect(orange.channels.0 == 1 && abs(orange.channels.1 - 0.2158) < 0.001 && orange.channels.2 == 0)
        #expect(orange.level == 1)
        // Pure colors are unaffected.
        #expect(LightPixel(RGB(0, 255, 0)).channels == (0, 1, 0))
    }

    /// Colors tuned when codes were raw proportions convert to codes that drive the strip the same.
    @Test func convertedColorsLookTheSameOnTheStrip() {
        #expect(RGB.fromRawLEDProportions(RGB(hex: "#FF2400")) == RGB(hex: "#FF6900"))
        #expect(RGB.fromRawLEDProportions(RGB(hex: "#FF0000")) == RGB(hex: "#FF0000"))
        for old in [RGB(hex: "#85FC5E"), RGB(hex: "#FF5700"), RGB(hex: "#3048FF"), RGB(hex: "#806040")] {
            let peak = Double(max(old.red, old.green, old.blue))
            // What the strip used to be driven with: the codes as proportions.
            let drive = LEDOutput.drive(peak / 255) * 255
            let before = [old.red, old.green, old.blue].map { Double($0) / peak * drive }
            var output = LEDOutput()
            let now = output.render([LightPixel(RGB.fromRawLEDProportions(old))])[0]
            let after = [Double(now.red), Double(now.green), Double(now.blue)]
            #expect(zip(before, after).allSatisfy { abs($0 - $1) <= 1.5 }, "\(old.hex): \(before) vs \(after)")
        }
    }
}

@MainActor struct LEDColorMigrationTests {
    @Test func savedSceneColorsConvertOnce() throws {
        // Settings in a temporary file, not ~/Library/Preferences (a removed named suite still
        // leaves an empty plist there).
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("StreamDock.Tests.\(UUID())").path
        let defaults = try #require(UserDefaults(suiteName: path))
        defer {
            defaults.removePersistentDomain(forName: path)
            try? FileManager.default.removeItem(atPath: path + ".plist")
        }
        defaults.set(try JSONEncoder().encode(["vibecoding": RGB(hex: "#85FC5E")]), forKey: "ledColorOverrides")
        #expect(DockSettings(defaults: defaults).ledColorOverrides["vibecoding"] == RGB(hex: "#BEFCA2"))
        // Already converted: loading again leaves it alone.
        #expect(DockSettings(defaults: defaults).ledColorOverrides["vibecoding"] == RGB(hex: "#BEFCA2"))
    }
}
