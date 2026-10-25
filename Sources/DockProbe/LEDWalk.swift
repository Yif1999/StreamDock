import DockKit
import Foundation

/// The light-strip refresh test played by `dock-probe ledwalk` and read back by `LEDScan`.
///
/// Timeline (both sides rely on it):
///   off 1 s · marker · off · calibration lap · off
///   then per rate: marker · off · walk for `walkSeconds` · off
/// A marker is the whole strip white for `markerSeconds`; "off" is `gapSeconds` dark.
/// A walk lights ring LED `n % 22` alone on frame `n`. The calibration lap lights LED k alone
/// for the k-th eighth of a second after its gap, sent again at 30 Hz like the still frames, so
/// it shows within 1/30 s of its slot and the video can tell which LED is which by time alone:
/// the camera need not see the whole ring.
enum LEDWalk {
    static let defaultRates: [Double] = [30, 60, 120, 240]
    static let calibrationRate = 8.0
    static let walkSeconds = 4.0
    static let markerSeconds = 0.5
    static let gapSeconds = 0.5
    static let ring = M18Layout.ringLEDs
    static let white: (UInt8, UInt8, UInt8) = (255, 255, 255)

    static func frame(lighting lit: Set<Int>) -> [(UInt8, UInt8, UInt8)] {
        (0..<Int(M18Layout.ledCount)).map { lit.contains($0) ? white : (0, 0, 0) }
    }

    static func play(on device: M18Device, rates: [Double]) {
        hold(frame(lighting: []), seconds: 1, on: device)
        print("marker + calibration lap (\(ring.count) LEDs at \(Int(calibrationRate)) Hz)")
        marker(on: device)
        let lap = ContinuousClock.now
        for (k, led) in ring.enumerated() {
            hold(frame(lighting: [led]), until: lap + .seconds(Double(k + 1) / calibrationRate), on: device)
        }
        hold(frame(lighting: []), seconds: gapSeconds, on: device)
        for rate in rates {
            marker(on: device)
            let report = walk(rate: rate, frames: Int(rate * walkSeconds), on: device)
            hold(frame(lighting: []), seconds: gapSeconds, on: device)
            print(report)
        }
        hold(frame(lighting: []), seconds: 0.2, on: device)
    }

    private static func marker(on device: M18Device) {
        hold(frame(lighting: Set(0..<Int(M18Layout.ledCount))), seconds: markerSeconds, on: device)
        hold(frame(lighting: []), seconds: gapSeconds, on: device)
    }

    /// A still frame, sent again at 30 Hz while it shows (the strip shows a frame once the next
    /// one arrives, so a lone send can stay invisible).
    private static func hold(_ frame: [(UInt8, UInt8, UInt8)], seconds: Double, on device: M18Device) {
        hold(frame, until: ContinuousClock.now + .seconds(seconds), on: device)
    }
    private static func hold(_ frame: [(UInt8, UInt8, UInt8)], until end: ContinuousClock.Instant, on device: M18Device) {
        while ContinuousClock.now < end {
            device.setLEDFrame(frame)
            device.waitUntilIdle()
            Thread.sleep(forTimeInterval: min(1.0 / 30, ProbeClock.seconds(until: end)))
        }
    }

    /// Sends every walk frame once, on a fixed grid, each send waiting for its USB write.
    private static func walk(rate: Double, frames: Int, on device: M18Device) -> String {
        let dropped = device.droppedLEDFrames
        var writes: [Double] = [], late: [Double] = []
        let start = ContinuousClock.now
        for n in 0..<frames {
            let due = start + .seconds(Double(n) / rate)
            Thread.sleep(forTimeInterval: ProbeClock.seconds(until: due))
            late.append(millisecondsPast(due))
            let sent = ContinuousClock.now
            device.setLEDFrame(frame(lighting: [ring[n % ring.count]]))
            device.waitUntilIdle()
            writes.append(millisecondsPast(sent))
        }
        let elapsed = ProbeClock.seconds(since: start)
        writes.sort(); late.sort()
        func p(_ values: [Double], _ q: Double) -> Double { values[min(values.count - 1, Int(Double(values.count) * q))] }
        return String(format: "%3d Hz: %d frames in %.3f s (%.1f/s sent), host skipped %d; USB write ms median %.2f p99 %.2f max %.2f; lateness p99 %.2f ms",
                      Int(rate), frames, elapsed, Double(frames) / elapsed, device.droppedLEDFrames - dropped,
                      p(writes, 0.5), p(writes, 0.99), writes.last ?? 0, p(late, 0.99))
    }
}

extension ProbeClock {
    static func seconds(since instant: ContinuousClock.Instant) -> Double {
        let gap = (ContinuousClock.now - instant).components
        return Double(gap.seconds) + Double(gap.attoseconds) / 1e18
    }
}
