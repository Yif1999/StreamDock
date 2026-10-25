@preconcurrency import AVFoundation
import DockKit
import Foundation

/// Reads a slow-motion video of `dock-probe ledwalk` and reports, per rate, how many frames the
/// strip actually showed. Nothing is taken on trust from the video file: the camera's frame rate
/// comes from the calibration lap (sent at exactly 8 Hz), and each LED's spot in the picture
/// comes from that lap too.
///
/// Per video frame each seen LED is lit or not (the frame split into the LEDs' calibration
/// pictures). An LED turning on is an arrival; in a walk consecutive arrivals should be
/// neighbours among the seen LEDs. A jump of d positions means d − 1 frames the strip never showed.
/// The camera needs to see only part of the ring.
enum LEDScan {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Video frames cropped to the strip, in luma, at a coarse step.
    struct Footage {
        var width = 0, height = 0
        var frames: [[UInt8]] = []
        /// Each frame's capture time in seconds. Cameras miss frames (an iPhone at "240 fps"
        /// keeps about 205 a second), so time comes from here, never from frame counts.
        var times: [Double] = []
    }

    static func run(video url: URL, rates: [Double]) throws {
        let asset = AVURLAsset(url: url)
        let track = try blocking { try await asset.loadTracks(withMediaType: .video).first }
        guard let track else { throw Failure("视频里没有画面轨道") }
        let nominal = try blocking { try await track.load(.nominalFrameRate) }
        print(String(format: "video: %@, file says %.2f fps", url.lastPathComponent, nominal))

        // Pass 1: where the strip is (the brightest area over the whole video).
        let coarse = 4
        var peak: [UInt8] = [], peakWidth = 0, peakHeight = 0
        try readLuma(asset, track) { luma, width, height, stride, _ in
            if peak.isEmpty {
                peakWidth = width / coarse; peakHeight = height / coarse
                peak = [UInt8](repeating: 0, count: peakWidth * peakHeight)
            }
            for y in 0..<peakHeight {
                let row = luma + (y * coarse) * stride
                for x in 0..<peakWidth {
                    let value = row[x * coarse]
                    if value > peak[y * peakWidth + x] { peak[y * peakWidth + x] = value }
                }
            }
        }
        guard let brightest = peak.max(), brightest > 60 else { throw Failure("画面里找不到亮起的灯带") }
        var box = (minX: Int.max, minY: Int.max, maxX: -1, maxY: -1)
        for y in 0..<peakHeight { for x in 0..<peakWidth where Int(peak[y * peakWidth + x]) * 2 > Int(brightest) {
            box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
        } }
        let pad = 6
        let x0 = max(0, box.minX - pad) * coarse, y0 = max(0, box.minY - pad) * coarse
        let x1 = min(peakWidth - 1, box.maxX + pad) * coarse, y1 = min(peakHeight - 1, box.maxY + pad) * coarse
        let step = max(1, (x1 - x0) / 240)

        // Pass 2: the strip's area of every frame.
        var footage = Footage(width: (x1 - x0) / step, height: (y1 - y0) / step)
        try readLuma(asset, track) { luma, _, _, stride, time in
            footage.times.append(time)
            var frame = [UInt8](repeating: 0, count: footage.width * footage.height)
            for y in 0..<footage.height {
                let row = luma + (y0 + y * step) * stride + x0
                for x in 0..<footage.width { frame[y * footage.width + x] = row[x * step] }
            }
            footage.frames.append(frame)
        }
        print("strip area \(x1 - x0)×\(y1 - y0) px, read at 1/\(step): \(footage.width)×\(footage.height), \(footage.frames.count) frames")
        try analyse(footage, rates: rates)
    }

    static func analyse(_ footage: Footage, rates: [Double]) throws {
        let frames = footage.frames
        let level = Int(frames.lazy.map { $0.max() ?? 0 }.max() ?? 0)
        let bright = UInt8(level / 2)
        let litCounts = frames.map { $0.reduce(0) { $1 > bright ? $0 + 1 : $0 } }
        let full = litCounts.max() ?? 0

        // Markers: the whole strip lit. Segment i runs from the end of marker i to the next one.
        var markers: [Range<Int>] = []
        var start: Int?
        for (index, count) in litCounts.enumerated() {
            let on = count * 2 > full
            if on, start == nil { start = index }
            if !on, let begun = start { markers.append(begun..<index); start = nil }
        }
        if let begun = start { markers.append(begun..<frames.count) }
        markers = markers.filter { $0.count >= 10 }
        guard markers.count == rates.count + 1 else {
            throw Failure("找到 \(markers.count) 个全亮标记，应有 \(rates.count + 1) 个（校准 + \(rates.count) 档）：视频是否拍全，速率参数是否和 ledwalk 一致？")
        }
        print("markers at frames: " + markers.map { "\($0.lowerBound)–\($0.upperBound) (\($0.count))" }.joined(separator: ", "))
        let segments = markers.indices.map { i in markers[i].upperBound..<(i + 1 < markers.count ? markers[i + 1].lowerBound : frames.count) }

        // Calibration. Runs of frames with one spot lit; which LED a run is follows from when it
        // happens: LED k has the k-th slot of 1/8 s after the gap.
        let times = footage.times
        let markerEnd = times[markers[0].upperBound]
        let span = times.last! - times.first!
        print(String(format: "camera: %.1f frames/s on average over %.1f s; longest gap %.1f ms", Double(times.count - 1) / span, span,
                     zip(times, times.dropFirst()).map { ($1 - $0) * 1000 }.max() ?? 0))
        // Markers must last their half second: a slow-motion clip exported from Photos speeds back
        // up at its ends and its time no longer matches the strip's.
        let lengths = markers.map { times[$0.upperBound] - times[$0.lowerBound] }
        print("marker lengths (s): " + lengths.map { String(format: "%.3f", $0) }.joined(separator: " "))
        if lengths.contains(where: { abs($0 / LEDWalk.markerSeconds - 1) > 0.1 }) {
            print("⚠️ 视频时间和实际时间对不上（慢动作导出的成片会把慢放做进时间里，头尾还会加速丢帧），以下结果不可信：请用原片（隔空投送时在“选项”里打开“所有照片数据”）。")
        }
        var runs: [[Int]] = []
        var last: (Double, Double)?
        for index in segments[0] where litCounts[index] > 0 && litCounts[index] * 4 < full {
            let spot = centroid(frames[index], width: footage.width, above: bright)
            if let previous = last, hypot(spot.0 - previous.0, spot.1 - previous.1) < 2, let end = runs.last?.last, end == index - 1 {
                runs[runs.count - 1].append(index)
            } else {
                runs.append([index])
            }
            last = spot
        }
        let slot = 1 / LEDWalk.calibrationRate
        var byLED: [Int: [Int]] = [:]
        for run in runs where times[run.last!] - times[run[0]] > slot / 2 {
            let middle = (times[run[0]] + times[run.last!]) / 2
            let k = Int(((middle - markerEnd - LEDWalk.gapSeconds) / slot - 0.5).rounded())
            if LEDWalk.ring.indices.contains(k), run.count > byLED[k]?.count ?? 0 { byLED[k] = run }
        }
        guard byLED.count >= 3 else { throw Failure("校准圈只认出 \(byLED.count) 颗灯，至少要看到 3 颗") }
        let slotErrors = byLED.map { k, run in (times[run[0]] - markerEnd - LEDWalk.gapSeconds - Double(k) * slot) * 1000 }
        print(String(format: "calibration: LEDs light %.0f–%.0f ms after their slot starts", slotErrors.min() ?? 0, slotErrors.max() ?? 0))

        // Each seen LED's picture over the dark background, and the least-squares split of any frame
        // into those pictures: the light guide spreads each LED into its neighbours' spots, so a
        // frame is read as a mix, not spot by spot.
        let pixels = footage.width * footage.height
        let darkFrames = segments[0].filter { times[$0] > markerEnd + 0.1 && times[$0] < markerEnd + LEDWalk.gapSeconds - 0.1 }
        var dark = [Double](repeating: 0, count: pixels)
        for index in darkFrames { for p in 0..<pixels { dark[p] += Double(frames[index][p]) } }
        for p in 0..<pixels { dark[p] /= Double(darkFrames.count) }
        var pictures: [(led: Int, values: [Double])] = byLED.keys.sorted().map { k in
            let run = byLED[k]!
            let middle = run.dropFirst(run.count / 4).dropLast(run.count / 4)
            var mean = [Double](repeating: 0, count: pixels)
            for index in middle { for p in 0..<pixels { mean[p] += Double(frames[index][p]) } }
            return (k, (0..<pixels).map { max(0, mean[$0] / Double(middle.count) - dark[$0]) })
        }
        // LEDs only glimpsed (glow from round the corner) would make the split unstable.
        let strongest = pictures.map { $0.values.max() ?? 0 }.max() ?? 1
        pictures = pictures.filter { ($0.values.max() ?? 0) >= strongest * 0.35 }
        let seen = pictures.map(\.led)
        print("LEDs seen: \(seen.map(String.init).joined(separator: " ")) (\(seen.count) of \(LEDWalk.ring.count))")
        let support = pictures.map { picture in picture.values.indices.filter { picture.values[$0] > strongest * 0.02 } }
        let m = pictures.count
        var gram = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        for i in 0..<m { for j in 0..<m { gram[i][j] = support[i].reduce(0) { $0 + pictures[i].values[$1] * pictures[j].values[$1] } } }
        let inverse = try invert(gram)
        func amounts(_ frame: [UInt8]) -> [Double] {
            let b = (0..<m).map { i in support[i].reduce(0) { $0 + pictures[i].values[$1] * (Double(frame[$1]) - dark[$1]) } }
            return (0..<m).map { i in (0..<m).reduce(0) { $0 + inverse[i][$1] * b[$1] } }
        }

        // Walks: positions are counted among the seen LEDs only, in ring order.
        for (rate, segment) in zip(rates, segments.dropFirst()) {
            var arrivals: [(frame: Int, position: Int)] = []
            var previous: Set<Int> = []
            var doubles = 0
            // Only the walk itself: from the end of the gap after its marker, for `walkSeconds`.
            let begins = times[segment.lowerBound] + LEDWalk.gapSeconds
            for index in segment where times[index] > begins - 0.05 && times[index] < begins + LEDWalk.walkSeconds + 0.05 {
                let mix = amounts(frames[index])
                let lit = Set((0..<m).filter { mix[$0] > 0.4 })
                if lit.count > 1 { doubles += 1 }
                // New LEDs in walk order (two can arrive together when an exposure straddles a step).
                let new = lit.subtracting(previous).sorted { a, b in
                    guard let from = arrivals.last?.position else { return a < b }
                    return (a - from + m) % m < (b - from + m) % m
                }
                for position in new { arrivals.append((index, position)) }
                previous = lit
            }
            guard arrivals.count > 2 else { print("\(Int(rate)) Hz: no walk seen"); continue }
            // A step is judged only where the camera could not have missed a whole position: a
            // shown position stays lit at least 1/rate, and it can hide only in the dark time
            // between two exposures. Exposures are taken as at least half a 240 fps frame
            // (slow motion in a dim room); missed camera frames make the dark time longer.
            let hides = { (gap: Double) in gap - 0.5 / 240 >= 1 / rate }
            var jumps: [Int: Int] = [:], gaps: [Int: Int] = [:]
            var covered = 0, skipped = 0, blind = 0
            for (a, b) in zip(arrivals, arrivals.dropFirst()) {
                let step = (b.position - a.position + m) % m
                gaps[Int(((times[b.frame] - times[a.frame]) * 1000).rounded()), default: 0] += 1
                if (a.frame..<b.frame).contains(where: { hides(times[$0 + 1] - times[$0]) }) { blind += 1; continue }
                jumps[step, default: 0] += 1
                covered += step; skipped += max(0, step - 1)
            }
            let shown = rate * Double(covered - skipped) / Double(covered)
            func histogram(_ counts: [Int: Int]) -> String { counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ") }
            print(String(format: "%3d Hz sent → %.1f frames/s shown: %d of %d positions shown on the seen LEDs, %d skipped (%.1f%%); %d steps not judged (the camera could have missed a position)",
                         Int(rate), shown, covered - skipped, covered, skipped, Double(skipped) / Double(covered) * 100, blind))
            print("        steps between arrivals, in seen LEDs (step×count): \(histogram(jumps))")
            print("        ms between arrivals (ms×count; long ones cross the unseen LEDs): \(histogram(gaps)); frames with two LEDs lit: \(doubles)")
        }
    }

    /// Gauss–Jordan inverse of a small symmetric matrix.
    private static func invert(_ matrix: [[Double]]) throws -> [[Double]] {
        let n = matrix.count
        var a = matrix.enumerated().map { i, row in row + (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }), abs(a[pivot][column]) > 1e-9 else {
                throw Failure("灯位画面无法分开（两颗灯在画面里重叠）")
            }
            a.swapAt(column, pivot)
            let lead = a[column][column]
            a[column] = a[column].map { $0 / lead }
            for row in 0..<n where row != column {
                let factor = a[row][column]
                if factor != 0 { a[row] = zip(a[row], a[column]).map { $0 - factor * $1 } }
            }
        }
        return a.map { Array($0[n...]) }
    }

    /// A made-up video of `ledwalk`, to check this reading against a known answer: a strip that
    /// shows the newest frame it has on its own clock of `stripRate`, filmed at 240 fps with
    /// each exposure as long as a frame, from the front left: LEDs 0–10 along the front, 17–21
    /// down the left side, 11–16 out of sight (16 and 11 glowing faintly round the corners), and
    /// every LED's light spread into its neighbours by the light guide.
    static func simulate(stripRate: Double, rates: [Double]) -> Footage {
        // What was sent: (from time, lit LEDs), in the order `LEDWalk.play` sends it.
        var sent: [(Double, Set<Int>)] = [], t = 1.0
        let all = Set(0..<Int(M18Layout.ledCount))
        func marker() { sent.append((t, all)); t += LEDWalk.markerSeconds; sent.append((t, [])); t += LEDWalk.gapSeconds }
        func walk(_ rate: Double, _ frames: Int) {
            for n in 0..<frames { sent.append((t + Double(n) / rate, [LEDWalk.ring[n % LEDWalk.ring.count]])) }
            t += Double(frames) / rate; sent.append((t, [])); t += LEDWalk.gapSeconds
        }
        sent.append((0, []))
        marker()
        for k in LEDWalk.ring.indices { sent.append((t + Double(k) / LEDWalk.calibrationRate, [LEDWalk.ring[k]])) }
        t += Double(LEDWalk.ring.count) / LEDWalk.calibrationRate; sent.append((t, [])); t += LEDWalk.gapSeconds
        for rate in rates { marker(); walk(rate, Int(rate * LEDWalk.walkSeconds)) }
        t += 0.5
        func sentAt(_ time: Double) -> Set<Int> { sent.last { $0.0 <= time }?.1 ?? [] }
        // The strip's own refresh, at an odd phase.
        func shownAt(_ time: Double) -> Set<Int> { sentAt(((time - 0.0037) * stripRate).rounded(.down) / stripRate + 0.0037) }
        let width = 200, height = 120
        // (x, y, strength) per LED; the bars sit inside.
        var spots: [Int: (Double, Double, Double)] = [:]
        for k in 0...10 { spots[k] = (40 + Double(k) * 14, 100, 1) }
        for k in 17...21 { spots[k] = (12 + Double(k - 17) * 4, 30 + Double(k - 17) * 13, 0.8) }
        spots[16] = (10, 22, 0.15); spots[11] = (190, 100, 0.15)
        spots[22] = (80, 60, 1); spots[23] = (120, 60, 1)
        var footage = Footage(width: width, height: height)
        let samples = 8
        var noise: UInt64 = 0x9E3779B97F4A7C15
        // The camera misses one frame in seven, about what an iPhone does.
        for frame in 0..<Int(t * 240) where frame % 7 != 3 {
            footage.times.append(Double(frame) / 240)
            var on = [Double](repeating: 0, count: Int(M18Layout.ledCount))
            for s in 0..<samples { for led in shownAt((Double(frame) + (Double(s) + 0.5) / Double(samples)) / 240) { on[led] += 1 / Double(samples) } }
            var light = [Double](repeating: 8, count: width * height)
            for (led, amount) in on.enumerated() where amount > 0 {
                guard let (cx, cy, strength) = spots[led] else { continue }
                for y in max(0, Int(cy) - 20)...min(height - 1, Int(cy) + 20) { for x in max(0, Int(cx) - 20)...min(width - 1, Int(cx) + 20) {
                    let d2 = pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2)
                    // A bright core and a wide glow reaching the neighbours.
                    light[y * width + x] += amount * strength * (200 * exp(-d2 / 10) + 60 * exp(-d2 / 200))
                } }
            }
            footage.frames.append(light.map { value in
                noise = noise &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(clamping: Int(value + Double(noise >> 61) - 3.5))
            })
        }
        return footage
    }

    private static func centroid(_ frame: [UInt8], width: Int, above bright: UInt8) -> (Double, Double) {
        var x = 0.0, y = 0.0, n = 0.0
        for (p, v) in frame.enumerated() where v > bright { x += Double(p % width); y += Double(p / width); n += 1 }
        return (x / n, y / n)
    }

    /// Calls `body` with each frame's luma plane (pointer, width, height, bytes per row, time).
    private static func readLuma(_ asset: AVURLAsset, _ track: AVAssetTrack,
                                 _ body: (UnsafePointer<UInt8>, Int, Int, Int, Double) -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw Failure("读不了视频：\(reader.error?.localizedDescription ?? "")") }
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
                body(base.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetWidthOfPlane(buffer, 0),
                     CVPixelBufferGetHeightOfPlane(buffer, 0), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                     CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        if reader.status == .failed { throw Failure("读视频出错：\(reader.error?.localizedDescription ?? "")") }
    }

    /// Runs an async load from this synchronous command.
    private static func blocking<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>(), done = DispatchSemaphore(value: 0)
        Task.detached { box.result = await Result { try await operation() }; done.signal() }
        done.wait()
        return try box.result!.get()
    }
}

private final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

private extension Result where Failure == Error {
    init(_ body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
