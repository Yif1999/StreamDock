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
///
/// Each frame is motion-blurred over its whole time (`shutter` 1, a 360° shutter): at the
/// middle the pages move more than a key pitch a frame, and blurred the jumps read as one
/// motion. The user compared none, 180° and 360° on the device and chose 360° (2026-10-29); it
/// costs 4 ms a frame on average, 9 ms at worst, and about the same bytes as none.
public struct PageSlide {
    public static let seconds = 0.3, framesPerSecond = 60.0, shutter = 1.0
    /// The share of the slide one frame's blur spans.
    public static var exposure: Double { shutter / framesPerSecond / seconds }

    let leaving: [Int: CGImage], arriving: [Int: CGImage]
    let shift: (x: Double, y: Double)
    private let field = KeyField()

    public init(leaving: [Int: CGImage], arriving: [Int: CGImage], toward: (x: Double, y: Double)) {
        self.leaving = leaving
        self.arriving = arriving
        shift = (toward.x * Double(M18Layout.columns * M18Layout.keyPitch), toward.y * Double(M18Layout.rows * M18Layout.keyPitch))
    }

    /// Every key's picture `t` (0...1) of the way through. `exposure` (a share of the whole
    /// slide) blurs it the way a camera shutter open that long would: the pages are drawn at
    /// moments across it, about every 3 px of travel, and averaged — sharp where the slide is
    /// slow, streaked where it is fast.
    public func frame(at t: Double, exposure: Double = 0) -> [Int: CGImage] {
        let travel = abs(Motion.ease(t) - Motion.ease(max(0, t - exposure))) * hypot(shift.x, shift.y)
        let samples = min(16, max(1, Int((travel / 3).rounded(.up))))
        guard samples > 1, let data = field.context.data else {
            draw(at: Motion.ease(t))
            return field.keyImages()
        }
        let bytes = field.context.bytesPerRow * field.height
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytes)
        var sum = [UInt32](repeating: 0, count: bytes)
        for sample in 0..<samples {
            draw(at: Motion.ease(t - exposure * Double(sample) / Double(samples - 1)))
            for i in 0..<bytes { sum[i] += UInt32(pixels[i]) }
        }
        for i in 0..<bytes { pixels[i] = UInt8((sum[i] + UInt32(samples / 2)) / UInt32(samples)) }
        return field.keyImages()
    }

    /// Both pages, `f` (eased) of the way.
    private func draw(at f: Double) {
        field.clear()
        for key in 1...M18Layout.lcdKeyCount {
            let origin = M18Layout.keyOrigin(key)
            let x = Double(origin.x) - shift.x * f, y = Double(origin.y) - shift.y * f
            if let image = leaving[key] { field.draw(image, x: x, y: y) }
            if let image = arriving[key] { field.draw(image, x: x + shift.x, y: y + shift.y) }
        }
    }
}
