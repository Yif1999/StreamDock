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

    public static let black = RGB(0, 0, 0)
    public static let white = RGB(255, 255, 255)
}

/// What one LCD key shows. Modules describe keys with this; the core renders and uploads it.
public struct KeyFace: Hashable, Sendable {
    /// SF Symbol name.
    public var symbol: String?
    /// Large text, shown when there is no symbol.
    public var title: String?
    /// Small text along the bottom edge.
    public var caption: String?
    public var foreground: RGB
    public var background: RGB

    public init(
        symbol: String? = nil,
        title: String? = nil,
        caption: String? = nil,
        foreground: RGB = .white,
        background: RGB = RGB(0x1C, 0x1C, 0x1E)
    ) {
        self.symbol = symbol
        self.title = title
        self.caption = caption
        self.foreground = foreground
        self.background = background
    }

    public static let blank = KeyFace(background: .black)
}
