import Foundation

/// Color proportions and perceived brightness, before hardware mapping.
public struct LightPixel: Sendable {
    public var channels: (Double, Double, Double)
    public var level: Double
    public init(channels: (Double, Double, Double), level: Double) {
        self.channels = (min(1, max(0, channels.0)), min(1, max(0, channels.1)), min(1, max(0, channels.2)))
        self.level = min(1, max(0, level))
    }
    public init(_ color: RGB) {
        let peak = Double(max(color.red, color.green, color.blue))
        channels = peak == 0 ? (0, 0, 0) : (Double(color.red) / peak, Double(color.green) / peak, Double(color.blue) / peak)
        level = peak / 255
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
