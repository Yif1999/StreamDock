import CoreGraphics
import DockCore
import DockKit
import Foundation

/// `dock-probe slidetest [fps] [quality] [seconds] [shutter…]`: page turns between two typical
/// pages, as the controller plays them (`PageSlide`), at a given frame rate, JPEG quality in
/// motion and length (defaults: `PageSlide`'s). Prints the bytes a frame takes at a few
/// qualities, then for each shutter (a share of a frame's time the motion blur spans; default
/// 0, then 0.5 and 1) plays across (right, left) and down, announced aloud. Quit the app first;
/// release build. `--cost`: only what a slide costs at each shutter, without the device.
@MainActor enum SlideTest {
    static func run(_ arguments: [String]) throws {
        let numbers = arguments.compactMap(Double.init)
        let fps = numbers.count > 0 ? numbers[0] : PageSlide.framesPerSecond
        let quality = numbers.count > 1 ? numbers[1] : KeyRenderer.motionQuality
        let seconds = numbers.count > 2 ? numbers[2] : PageSlide.seconds
        let shutters = numbers.count > 3 ? Array(numbers[3...]) : [0, 0.5, 1]
        let daily: [KeyFace] = [
            KeyFace(symbol: "speaker.wave.1.fill"), KeyFace(title: "45", caption: "Volume"), KeyFace(symbol: "speaker.wave.3.fill"),
            KeyFace(symbol: "hifispeaker", caption: "LG Display"), KeyFace(symbol: "mic", caption: "DJI Mic"),
            KeyFace(symbol: "sun.min.fill"), KeyFace(title: "70", caption: "Brightness"), KeyFace(symbol: "sun.max.fill"),
            KeyFace(symbol: "moon.fill", caption: "Sleep"), KeyFace(symbol: "mic.slash.fill", caption: "Muted", tone: .alert),
            KeyFace(symbol: "backward.fill"), KeyFace(symbol: "pause.fill"), KeyFace(symbol: "forward.fill"),
            KeyFace(symbol: "music.note", caption: "Music"), KeyFace(symbol: "star.fill", caption: "Loved", tone: .on),
        ]
        let home: [KeyFace] = [
            KeyFace(title: "26°", caption: "A/C", tone: .on), KeyFace(symbol: "minus", caption: "A/C"), KeyFace(symbol: "plus", caption: "A/C"),
            KeyFace(title: "Cool", caption: "A/C"), KeyFace(title: "86W", caption: "PC", tone: .on),
            KeyFace(title: "40%", caption: "Fan", tone: .on), KeyFace(symbol: "minus", caption: "Fan"), KeyFace(symbol: "plus", caption: "Fan"),
            KeyFace(symbol: "arrow.left.and.right", caption: "Fan", tone: .on), KeyFace(title: "Natural", caption: "Fan"),
            KeyFace(symbol: "power", caption: "Light Bar"), KeyFace(symbol: "sun.min.fill", caption: "Light Bar", tone: .dim),
            KeyFace(symbol: "sun.max.fill", caption: "Light Bar", tone: .dim), KeyFace(symbol: "flame.fill", caption: "Light Bar", tone: .dim),
            KeyFace(symbol: "snowflake", caption: "Light Bar", tone: .dim),
        ]
        func images(_ faces: [KeyFace]) -> [Int: CGImage] {
            Dictionary(uniqueKeysWithValues: faces.enumerated().compactMap { i, face in KeyRenderer.image(for: face).map { (i + 1, $0) } })
        }
        let pages = [images(daily), images(home)]
        // What a mid-slide frame costs.
        let middle = PageSlide(leaving: pages[0], arriving: pages[1], toward: (1, 0)).frame(at: 0.5, exposure: 0.5 / fps / seconds)
        for q in [1.0, 0.8, 0.6, 0.4] {
            let bytes = middle.values.compactMap { KeyRenderer.jpeg($0, quality: q)?.count }.reduce(0, +)
            print(String(format: "quality %.1f: %d bytes a frame (15 keys), %.0f KB/s at %d fps", q, bytes, Double(bytes) * fps / 1000, Int(fps)))
        }
        // What a whole slide costs at each shutter: drawing time per frame and bytes sent.
        for shutter in [0, 0.5, 1.0] {
            let slide = PageSlide(leaving: pages[0], arriving: pages[1], toward: (1, 0))
            let frames = Int(seconds * fps)
            var worst = 0.0, total = 0.0, bytes = 0
            for frame in 1...frames {
                let start = ContinuousClock.now
                let images = slide.frame(at: Double(frame) / Double(frames), exposure: shutter / fps / seconds)
                bytes += images.values.compactMap { KeyRenderer.jpeg($0, quality: quality)?.count }.reduce(0, +)
                let ms = ProbeClock.seconds(since: start) * 1000
                worst = max(worst, ms); total += ms
            }
            print(String(format: "shutter %3d°: %.1f ms a frame on average, %.1f ms at worst (budget %.1f); %d KB over the slide",
                         Int(shutter * 360), total / Double(frames), worst, 1000 / fps, bytes / 1000))
        }
        if arguments.contains("--cost") { return }
        guard let identity = M18Device.attached().first else { print("no M18 attached"); return }
        let device = try M18Device(opening: identity) { _ in }
        device.setScreenBrightness(80)
        func show(_ page: [Int: CGImage]) {
            device.setKeyImages(Dictionary(uniqueKeysWithValues: page.compactMap { key, image in KeyRenderer.jpeg(image).map { (key, $0) } }))
        }
        func play(_ from: Int, _ toward: (x: Double, y: Double), shutter: Double) {
            let exposure = shutter / fps / seconds
            let slide = PageSlide(leaving: pages[from], arriving: pages[1 - from], toward: toward)
            let grid = FrameGrid(framesPerSecond: fps)
            var sent: [Int: Data] = [:]
            while true {
                let t = min(1, ProbeClock.seconds(since: grid.start) / seconds)
                if t >= 1 { break }
                var frame: [Int: Data] = [:]
                for (key, image) in slide.frame(at: t, exposure: exposure) {
                    guard let jpeg = KeyRenderer.jpeg(image, quality: quality), sent[key] != jpeg else { continue }
                    frame[key] = jpeg
                    sent[key] = jpeg
                }
                device.setKeyImages(frame)
                Thread.sleep(forTimeInterval: ProbeClock.seconds(until: grid.next()))
            }
            show(pages[1 - from])
            Thread.sleep(forTimeInterval: 1.2)
        }
        func say(_ text: String) {
            print(text)
            (try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: [text]))?.waitUntilExit()
        }
        show(pages[0])
        for shutter in shutters {
            say(shutter == 0 ? "不模糊" : "动态模糊，快门 \(Int(shutter * 360)) 度")
            play(0, (1, 0), shutter: shutter); play(1, (-1, 0), shutter: shutter)
            play(0, (0, 1), shutter: shutter); play(1, (0, 1), shutter: shutter)
        }
        device.clearKeys(Array(1...15))
        device.waitUntilIdle()
        device.close(notifyDevice: true)
    }
}
