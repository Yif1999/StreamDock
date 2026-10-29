import CoreGraphics
import DockKit

/// Changing what the keys show: the page on screen slides away as the next follows it in, one
/// key pitch behind, across the real key layout (`KeyField`), on `Motion.ease`. `toward` is
/// where the new page comes from: a scene on a round key further right from the right (1, 0),
/// one further left from the left (−1, 0) — the round keys sit side by side — and the next page
/// of the same scene from below (0, 1), pages stacking under one another.
///
/// A 0.3 s burst on all 15 keys at 60 frames a second, its frames in motion as small JPEGs
/// (`KeyRenderer.motionQuality`); the controller redraws the landed page at full quality.
/// Checked on the device with `dock-probe slidetest` (2026-10-29): smooth. At 30 frames and
/// 0.6 s it was slow, and keys flickered as they passed the black gap between the pages.
public struct PageSlide {
    public static let seconds = 0.3, framesPerSecond = 60.0

    let leaving: [Int: CGImage], arriving: [Int: CGImage]
    let shift: (x: Double, y: Double)
    private let field = KeyField()

    public init(leaving: [Int: CGImage], arriving: [Int: CGImage], toward: (x: Double, y: Double)) {
        self.leaving = leaving
        self.arriving = arriving
        shift = (toward.x * Double(M18Layout.columns * M18Layout.keyPitch), toward.y * Double(M18Layout.rows * M18Layout.keyPitch))
    }

    /// Every key's picture `t` (0...1) of the way through.
    public func frame(at t: Double) -> [Int: CGImage] {
        let f = Motion.ease(t)
        field.clear()
        for key in 1...M18Layout.lcdKeyCount {
            let origin = M18Layout.keyOrigin(key)
            let x = Double(origin.x) - shift.x * f, y = Double(origin.y) - shift.y * f
            if let image = leaving[key] { field.draw(image, x: x, y: y) }
            if let image = arriving[key] { field.draw(image, x: x + shift.x, y: y + shift.y) }
        }
        return field.keyImages()
    }
}
