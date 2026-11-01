import CoreGraphics
import DockKit

/// Changing what the keys show: the page on screen slides away as the next follows it in, one
/// key pitch behind, across the real key layout (`KeyField`), on `Motion.ease`. `toward` is
/// where the new page comes from: a scene on a round key further right from the right (1, 0),
/// one further left from the left (−1, 0) — the round keys sit side by side — and the next page
/// of the same scene from below (0, 1), pages stacking under one another.
///
/// The page does not move as one stiff sheet: its lines (rows when it slides up or down,
/// columns when it slides across) start one after another, `lag` apart, the leading edge first,
/// so the page stretches as it gets going and closes up again as it lands — springy (the user
/// asked for it, 2026-11-01). The arriving page's first line starts with the leaving page's
/// last, so lines only ever draw apart and never run into one another.
///
/// Each line moves for 0.3 s, at 60 frames a second, its frames in motion as small JPEGs
/// (`KeyRenderer.motionQuality`); the controller redraws the landed page at full quality.
/// Checked on the device with `dock-probe slidetest` (2026-10-29): smooth. At 30 frames and
/// 0.6 s it was slow, and keys flickered as they passed the black gap between the pages.
///
/// Each frame is motion-blurred over its whole time (`shutter` 1, a 360° shutter): at the
/// fastest the pages move more than a key pitch a frame, and blurred the jumps read as one
/// motion. The user compared none, 180° and 360° on the device and chose 360° (2026-10-29); it
/// costs 4 ms a frame on average, 9 ms at worst, and about the same bytes as none.
public struct PageSlide {
    public static let seconds = 0.3, framesPerSecond = 60.0, shutter = 1.0, lag = 0.015
    /// How long one frame's blur spans, in seconds.
    public static var exposure: Double { shutter / framesPerSecond }

    let leaving: [Int: CGImage], arriving: [Int: CGImage]
    let shift: (x: Double, y: Double)
    let curve: Motion.Curve
    /// When each key's line starts, in seconds, on the leaving page and on the arriving one.
    let leavingDelays: [Int: Double], arrivingDelays: [Int: Double]
    /// From the first line starting to the last landing.
    public let duration: Double
    private let field = KeyField()

    public init(leaving: [Int: CGImage], arriving: [Int: CGImage], toward: (x: Double, y: Double),
                lag: Double = PageSlide.lag, curve: Motion.Curve = Motion.keys) {
        self.leaving = leaving
        self.arriving = arriving
        self.curve = curve
        shift = (toward.x * Double(M18Layout.columns * M18Layout.keyPitch), toward.y * Double(M18Layout.rows * M18Layout.keyPitch))
        let lines = toward.y == 0 ? M18Layout.columns : M18Layout.rows
        var leavingDelays: [Int: Double] = [:], arrivingDelays: [Int: Double] = [:]
        for key in 1...M18Layout.lcdKeyCount {
            let row = (key - 1) / M18Layout.columns, column = (key - 1) % M18Layout.columns
            // Lines counted from the leading edge: the pages move against `toward`.
            let line = toward.y > 0 ? row : toward.y < 0 ? M18Layout.rows - 1 - row
                : toward.x > 0 ? column : M18Layout.columns - 1 - column
            leavingDelays[key] = lag * Double(line)
            arrivingDelays[key] = lag * Double(lines - 1 + line)
        }
        self.leavingDelays = leavingDelays
        self.arrivingDelays = arrivingDelays
        duration = Self.seconds + lag * Double(2 * lines - 2)
    }

    /// Every key's picture `time` seconds in. `exposure` (seconds) blurs it the way a camera
    /// shutter open that long would: the pages are drawn at moments across it, about every 3 px
    /// of the fastest line's travel, and averaged — sharp where the slide is slow, streaked
    /// where it is fast.
    public func frame(at time: Double, exposure: Double = 0) -> [Int: CGImage] {
        let travel = Set(leavingDelays.values).union(arrivingDelays.values).map { delay in
            abs(progress(time, delay) - progress(time - exposure, delay))
        }.max()! * hypot(shift.x, shift.y)
        let samples = min(16, max(1, Int((travel / 3).rounded(.up))))
        guard samples > 1, let data = field.context.data else {
            draw(at: time)
            return field.keyImages()
        }
        let bytes = field.context.bytesPerRow * field.height
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytes)
        var sum = [UInt32](repeating: 0, count: bytes)
        for sample in 0..<samples {
            draw(at: time - exposure * Double(sample) / Double(samples - 1))
            for i in 0..<bytes { sum[i] += UInt32(pixels[i]) }
        }
        for i in 0..<bytes { pixels[i] = UInt8((sum[i] + UInt32(samples / 2)) / UInt32(samples)) }
        return field.keyImages()
    }

    /// How far (eased) a line starting at `delay` has gone `time` seconds in.
    private func progress(_ time: Double, _ delay: Double) -> Double {
        curve.ease((time - delay) / Self.seconds)
    }

    /// Both pages, `time` seconds in.
    private func draw(at time: Double) {
        field.clear()
        for key in 1...M18Layout.lcdKeyCount {
            let origin = M18Layout.keyOrigin(key)
            let gone = progress(time, leavingDelays[key] ?? 0), come = progress(time, arrivingDelays[key] ?? 0)
            if let image = leaving[key] { field.draw(image, x: Double(origin.x) - shift.x * gone, y: Double(origin.y) - shift.y * gone) }
            if let image = arriving[key] {
                field.draw(image, x: Double(origin.x) + shift.x * (1 - come), y: Double(origin.y) + shift.y * (1 - come))
            }
        }
    }
}
