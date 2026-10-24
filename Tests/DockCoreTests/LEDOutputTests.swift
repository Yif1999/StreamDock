import Foundation
import Testing
@testable import DockCore

struct LEDOutputTests {
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
}
