import Foundation

/// Color proportions and perceived brightness, before hardware mapping.
public struct LightPixel: Sendable {
    public var channels: (Double, Double, Double)
    public var level: Double
    public init(channels: (Double, Double, Double), level: Double) {
        self.channels = (min(1, max(0, channels.0)), min(1, max(0, channels.1)), min(1, max(0, channels.2)))
        self.level = min(1, max(0, level))
    }
    /// A color as a screen shows it: proportions in linear light (sRGB decoded, so a color code
    /// looks on the strip as it does on screen), brightness from its largest channel, perceived.
    /// Until 2026-10-25 the codes themselves were the proportions, which lit small channels several
    /// times too strongly (pinkish whites, yellowish oranges); colors tuned that way were converted
    /// with `RGB.fromRawLEDProportions`.
    public init(_ color: RGB) {
        let linear = (SRGB.decode(color.red), SRGB.decode(color.green), SRGB.decode(color.blue))
        let peak = max(linear.0, linear.1, linear.2)
        channels = peak == 0 ? (0, 0, 0) : (linear.0 / peak, linear.1 / peak, linear.2 / peak)
        level = Double(max(color.red, color.green, color.blue)) / 255
    }
    public static let black = LightPixel(.black)
    func mixed(with other: LightPixel, amount: Double) -> LightPixel {
        let t = min(1, max(0, amount))
        let r = channels.0 * level * (1 - t) + other.channels.0 * other.level * t
        let g = channels.1 * level * (1 - t) + other.channels.1 * other.level * t
        let b = channels.2 * level * (1 - t) + other.channels.2 * other.level * t
        let peak = max(r, g, b)
        return peak == 0 ? .black : LightPixel(channels: (r / peak, g / peak, b / peak), level: peak)
    }
}

/// Turns perceived brightness into LED drive levels and 8-bit values.
///
/// LEDs are driven linearly but the eye is not: all animation and global brightness levels are *perceived*
/// brightness, raised to `gamma` only here, so fades look even and dim light stays fine-grained.
/// At the dim end 8 bits leave few steps (1, 2, 3 …), and a value hovering between two of them
/// would flicker; each channel therefore only moves once the wanted value is `hysteresis`
/// steps away from what it shows.
public struct LEDOutput {
    public init() {}
    public static let gamma = 2.2
    public static func drive(_ level: Double) -> Double { pow(min(1, max(0, level)), gamma) }
    static let hysteresis = 0.7
    private var held: [Double] = []

    public mutating func render(_ pixels: [LightPixel], gain: Double = 1) -> [RGB] {
        if held.count != pixels.count * 3 { held = Array(repeating: 0, count: pixels.count * 3) }
        return pixels.enumerated().map { index, pixel in
            let drive = Self.drive(pixel.level * min(1, max(0, gain))) * 255
            let wanted = [pixel.channels.0 * drive, pixel.channels.1 * drive, pixel.channels.2 * drive]
            for channel in 0..<3 where abs(wanted[channel] - held[index * 3 + channel]) >= Self.hysteresis {
                held[index * 3 + channel] = wanted[channel].rounded()
            }
            return RGB(UInt8(held[index * 3]), UInt8(held[index * 3 + 1]), UInt8(held[index * 3 + 2]))
        }
    }
}

/// The sRGB transfer curve.
public enum SRGB {
    public static func decode(_ value: UInt8) -> Double {
        let v = Double(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    public static func encode(_ linear: Double) -> UInt8 {
        let x = min(1, max(0, linear))
        let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return UInt8((v * 255).rounded())
    }
}

public extension RGB {
    /// The color code that looks on the strip as `old` did when codes were used as raw LED
    /// proportions (before 2026-10-25): same largest channel, the others re-encoded so their
    /// share of the light is unchanged. Pure colors (only 0 and 255) stay as they are.
    static func fromRawLEDProportions(_ old: RGB) -> RGB {
        let peak = max(old.red, old.green, old.blue)
        guard peak > 0 else { return old }
        let light = SRGB.decode(peak)
        func convert(_ value: UInt8) -> UInt8 { SRGB.encode(light * Double(value) / Double(peak)) }
        return RGB(convert(old.red), convert(old.green), convert(old.blue))
    }
}
