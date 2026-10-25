import Foundation

public struct RGB: Hashable, Codable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "#RRGGBB" or "RRGGBB".
    public init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF))
    }

    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// Linear blend: `amount` 0 is self, 1 is `other`.
    public func mixed(with other: RGB, amount: Double) -> RGB {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) * (1 - amount) + Double(b) * amount).rounded()) }
        return RGB(mix(red, other.red), mix(green, other.green), mix(blue, other.blue))
    }

    /// Dims (or brightens, clamped) by a factor.
    public func scaled(by factor: Double) -> RGB {
        func scale(_ value: UInt8) -> UInt8 { UInt8(min(255, max(0, (Double(value) * factor).rounded()))) }
        return RGB(scale(red), scale(green), scale(blue))
    }

    public static let black = RGB(0, 0, 0)
    public static let white = RGB(255, 255, 255)
}

/// A gauge that fills the key from the left: what is left of a quota, in the service's own color.
public struct KeyMeter: Hashable, Sendable {
    /// 0 (empty, all black) ... 1 (full).
    public var fraction: Double
    public var color: RGB
    public init(fraction: Double, color: RGB) { self.fraction = fraction; self.color = color }
}

/// What one LCD key shows. Modules say what the key is and what state it is in; how that
/// looks (colors, sizes, grid) is decided once, by `KeyDesign`.
public struct KeyFace: Hashable, Sendable {
    /// SF Symbol name.
    public var symbol: String?
    /// Encoded album artwork, drawn edge to edge.
    public var artwork: Data?
    /// A value (a number, a short word) shown large instead of a glyph.
    public var title: String?
    /// The label under the glyph or value: short English.
    public var caption: String?
    /// What the key's state means; the only say a module has over color.
    public var tone: KeyTone
    /// A quota gauge behind the value (the one place a service's own color appears).
    public var meter: KeyMeter?

    public init(
        symbol: String? = nil,
        artwork: Data? = nil,
        title: String? = nil,
        caption: String? = nil,
        tone: KeyTone = .normal,
        meter: KeyMeter? = nil
    ) {
        self.symbol = symbol
        self.artwork = artwork
        self.title = title
        self.caption = caption
        self.tone = tone
        self.meter = meter
    }

    public static let blank = KeyFace()
}
