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

    /// User-confirmed physical order (2026-10-24): 0–10 lower half, 11–21 upper half,
    /// counterclockwise when viewed from above. Left end is 21/0, right end 10/11;
    /// lower and upper midpoints are 5 and 16. This supersedes the earlier corner mapping.
    /// The light guide spreads each LED's light into its neighbours and the short bars.
    public static let ringLEDs = Array(0...21)
    /// The short bars beside the round keys; not part of the ring.
    public static let leftBarLED = 22
    public static let rightBarLED = 23

    /// Where an LED sits seen from above, in a unit square (x 0 left → 1 right, y 0 front →
    /// 1 back; the base is square, 2026-10-27). The ring runs evenly round the edge from the
    /// middle of the left side, down and counterclockwise: 0 just below that middle, 5 the
    /// middle of the front, 10 and 11 either side of the right side's middle, 16 the middle of
    /// the back, 21 just above the left side's middle — each side holds 5.5 LEDs, the corners
    /// falling between two. The short bars are level strips `barLength` long, centred 0.17 and
    /// 0.83 across, 0.22 in from the front, either side of the round keys (from a photo,
    /// 2026-10-27; the base is about 1.1 wide to 1 deep, taken as square).
    public static let barLength = 0.12
    public static func position(ofLED index: Int) -> (x: Double, y: Double) {
        switch index {
        case leftBarLED: return (0.17, 0.22)
        case rightBarLED: return (0.83, 0.22)
        default: return edgePoint(lap: (Double(index) + 0.5) / Double(ringLEDs.count))
        }
    }

    /// The point `lap` of the way round the edge (0...1), in the ring's order and square.
    public static func edgePoint(lap: Double) -> (x: Double, y: Double) {
        let s = (lap - lap.rounded(.down)) * 4   // distance round the edge, in sides
        switch s {
        case ..<0.5: return (0, 0.5 - s)
        case ..<1.5: return (s - 0.5, 0)
        case ..<2.5: return (1, s - 1.5)
        case ..<3.5: return (3.5 - s, 1)
        default: return (0, 4.5 - s)
        }
    }

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
