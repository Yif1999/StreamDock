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
    /// counterclockwise when viewed from above. Where each sits: `position(ofLED:)`.
    /// The light guide spreads each LED's light into its neighbours and the short bars.
    public static let ringLEDs = Array(0...21)
    /// The short bars beside the round keys; not part of the ring.
    public static let leftBarLED = 22
    public static let rightBarLED = 23

    /// Where the base's corners fall on the ring, in LED positions (LED i is at i; .5 is between
    /// two LEDs): front-left, front-right, back-right, back-left. Measured with
    /// `dock-probe ledcorners`, twice (2026-10-27): 6 LEDs along the front and back, 5 along the
    /// left and right — the middles fall at 5.5 (front), 11 (right), 16.5 (back) and 0 (left).
    public static let corners: [Double] = [2.5, 8.5, 13.5, 19.5]

    /// Where an LED sits seen from above, in a unit square (x 0 left → 1 right, y 0 front →
    /// 1 back; the base is about 1.1 wide to 1 deep, taken as square). The ring runs round the
    /// edge from the left side, down and counterclockwise, the LEDs between two corners spread
    /// evenly along that side (`corners`). The short bars are level strips `barLength` long,
    /// centred 0.21 and 0.79 across, 0.17 in from the front, either side of the round keys (from
    /// a photo, then set by eye against the strip in 律动可视化, symmetric, 2026-10-27).
    public static let barLength = 0.12
    public static func position(ofLED index: Int) -> (x: Double, y: Double) {
        switch index {
        case leftBarLED: return (0.21, 0.17)
        case rightBarLED: return (0.79, 0.17)
        default: return edgePoint(lap: (Double(index) + 0.5) / Double(ringLEDs.count))
        }
    }

    /// The point `lap` of the way round the ring (0...1, LED i at (i + 0.5) / 22), in the same
    /// square: between two corners it moves evenly along their side.
    public static func edgePoint(lap: Double) -> (x: Double, y: Double) {
        let count = Double(ringLEDs.count)
        var at = (lap - lap.rounded(.down)) * count - 0.5   // in LED positions
        while at < corners[0] { at += count }
        let squareCorners: [(x: Double, y: Double)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
        for side in 0..<4 {
            let start = corners[side], end = side < 3 ? corners[side + 1] : corners[0] + count
            guard at < end || side == 3 else { continue }
            let f = (at - start) / (end - start)
            let a = squareCorners[side], b = squareCorners[(side + 1) % 4]
            return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
        }
        return squareCorners[0]
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
