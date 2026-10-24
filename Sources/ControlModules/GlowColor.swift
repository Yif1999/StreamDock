import DockCore
import Foundation

/// A color in OKLab (Björn Ottosson, 2020): perceptually uniform, so averages and blends look
/// like what the eye expects — two hues mix through a clean in-between instead of the grey,
/// muddy middle a plain RGB average gives.
struct OKLab: Equatable {
    var l: Double, a: Double, b: Double

    static let white = OKLab(l: 1, a: 0, b: 0)

    var chroma: Double { (a * a + b * b).squareRoot() }
    /// Hue angle in radians.
    var hue: Double { atan2(b, a) }

    init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    init(l: Double, chroma: Double, hue: Double) {
        self.init(l: l, a: chroma * cos(hue), b: chroma * sin(hue))
    }

    /// From an sRGB-encoded color (as artwork pixels and `RGB` palettes are).
    init(srgb color: RGB) {
        self.init(linear: (Self.decode(color.red), Self.decode(color.green), Self.decode(color.blue)))
    }

    init(linear rgb: (Double, Double, Double)) {
        let (r, g, b) = rgb
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        self.init(
            l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    /// Linear-light RGB (may fall outside 0...1 for colors outside sRGB).
    var linear: (Double, Double, Double) {
        let l = pow(self.l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(self.l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(self.l - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    var isInGamut: Bool {
        let (r, g, b) = linear
        return [r, g, b].allSatisfy { (-1e-4...1.0001).contains($0) }
    }

    /// sRGB-encoded, clipped.
    var srgb: RGB {
        let (r, g, b) = linear
        return RGB(Self.encode(r), Self.encode(g), Self.encode(b))
    }

    /// The color's channel proportions for an LED: linear light, the brightest channel at 1.
    /// How bright the LED shines is decided separately (`GlowBudget`), so lightness is dropped.
    var ledChannels: (Double, Double, Double) {
        let (r, g, b) = linear
        let clipped = (max(0, r), max(0, g), max(0, b))
        let peak = max(clipped.0, clipped.1, clipped.2, 1e-6)
        return (clipped.0 / peak, clipped.1 / peak, clipped.2 / peak)
    }

    func mixed(with other: OKLab, amount: Double) -> OKLab {
        OKLab(l: l + (other.l - l) * amount, a: a + (other.a - a) * amount, b: b + (other.b - b) * amount)
    }

    /// Weighted average that keeps colors vivid: plain OKLab averaging of two distant hues still
    /// loses chroma in between; `keepChroma` of that loss is put back (hue unchanged).
    static func blend(_ colors: [OKLab], weights: [Double], keepChroma: Double) -> OKLab {
        let total = max(weights.reduce(0, +), 1e-9)
        var mean = OKLab(l: 0, a: 0, b: 0)
        var chroma = 0.0
        for (color, weight) in zip(colors, weights) {
            mean.l += color.l * weight / total
            mean.a += color.a * weight / total
            mean.b += color.b * weight / total
            chroma += color.chroma * weight / total
        }
        let current = mean.chroma
        guard current > 1e-4 else { return mean }
        let restored = current + keepChroma * (chroma - current)
        return OKLab(l: mean.l, a: mean.a * restored / current, b: mean.b * restored / current)
    }

    private static func decode(_ value: UInt8) -> Double {
        let c = Double(value) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func encode(_ value: Double) -> UInt8 {
        let c = min(1, max(0, value))
        let encoded = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt8((encoded * 255).rounded())
    }
}
