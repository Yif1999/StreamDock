/// A physical key on the M18.
public enum DockKey: Hashable, Sendable {
    /// LCD key 1–15, numbered row by row from the top-left.
    case lcd(Int)
    /// Round key 1–3 under the screen, left to right.
    case round(Int)
}

public struct DockInputEvent: Sendable {
    public let key: DockKey
    public let pressed: Bool
}

/// Hardware facts and key-number translation for the StreamDock M18.
///
/// The firmware uses two different numberings: image slots 11–15 are the top row,
/// but key events report the top row as codes 1–5. The vendor SDK maps both
/// through one table and gets events upside down, so we keep the two maps apart.
public enum M18Layout {
    public static let rows = 3
    public static let columns = 5
    public static let lcdKeyCount = rows * columns
    public static let roundKeyCount = 3
    public static let keyImageSize = 64
    public static let ledCount: UInt16 = 24

    /// The light ring around the base, in physical order: LED 0 at the front-left, along the
    /// front edge to the right (0–5), up the right side (5–11), across the back (12–16) and down
    /// the left side (16–21), closing back at 0. Roughly evenly spaced.
    /// Mapped by lighting one LED at a time on video (2026-10-24). The light guide spreads
    /// each LED's light to its neighbours and into the short bars, so single LEDs look smeared.
    public static let ringLEDs = Array(0...21)
    /// The short bars beside the round keys; not part of the ring.
    public static let leftBarLED = 22
    public static let rightBarLED = 23

    static let vendorID: UInt16 = 0x6603
    /// 0x1009 = M18 (CN firmware), 0x1012 = M18EN.
    static let productIDs: [UInt16] = [0x1009, 0x1012]
    /// The vendor-defined HID interface used for commands and key events.
    static let usagePage: UInt16 = 0xFFA0
    static let usage: UInt16 = 1

    private static let roundKeyCodes: [UInt8] = [0x25, 0x30, 0x31]

    /// Logical LCD key (1–15) -> firmware image slot.
    static func imageSlot(forKey key: Int) -> UInt8 {
        precondition((1...lcdKeyCount).contains(key), "LCD key \(key) out of range")
        let row = (key - 1) / columns
        let column = (key - 1) % columns
        return UInt8((rows - 1 - row) * columns + column + 1)
    }

    /// Firmware event code -> key. Codes 1–15 already run row by row from the top-left.
    static func key(forEventCode code: UInt8) -> DockKey? {
        if (1...UInt8(lcdKeyCount)).contains(code) { return .lcd(Int(code)) }
        if let index = roundKeyCodes.firstIndex(of: code) { return .round(index + 1) }
        return nil
    }
}
