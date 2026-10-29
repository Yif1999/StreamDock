import DockCore
import DockKit
import Foundation

/// `dock-probe holddemo [--time]`: the long-press ring on three keys at once (a dark key, a white
/// "on" key, a red one): held through the second, when it fires and the key turns over (three
/// times), then let go early at a quarter and at two thirds, announced aloud. Drawn as `KeyHold` and `KeyDesign` do in the
/// app, at 60 frames a second. Run the release build: the debug one draws a frame in ~150 ms.
/// `--time`: how long a frame takes to draw, without the device.
@MainActor enum HoldDemo {
    static func run(_ arguments: [String]) throws {
        guard let identity = M18Device.attached().first else { print("no M18 attached"); return }
        var faces: [Int: KeyFace] = [
            7: KeyFace(symbol: "moon.fill", caption: "Sleep"),
            8: KeyFace(title: "86W", caption: "PC", tone: .on),
            9: KeyFace(symbol: "mic.slash.fill", caption: "Muted", tone: .alert),
        ]
        // An artwork key (like Music's cover): it sinks in step with the ring.
        if let cover = KeyRenderer.jpeg(for: KeyFace(symbol: "music.note", tone: .live)) { faces[10] = KeyFace(artwork: cover) }
        if arguments.contains("--time") {
            let start = ContinuousClock.now
            for i in 0..<30 { for (_, face) in faces { var f = face; f.hold = .holding(Double(i) / 30); _ = KeyRenderer.jpeg(for: f, press: 1) } }
            print("ms per frame (3 keys):", ProbeClock.seconds(since: start) / 30 * 1000)
            return
        }
        let device = try M18Device(opening: identity) { _ in }
        device.setScreenBrightness(80)
        device.clearKeys(Array(1...15))
        func show(_ phase: HoldPhase?, press: Double) {
            var images: [Int: Data] = [:]
            for (key, face) in faces {
                var face = face
                face.hold = phase
                images[key] = KeyRenderer.jpeg(for: face, press: press)
            }
            device.setKeyImages(images)
        }
        func say(_ text: String) {
            print(text)
            (try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: [text]))?.waitUntilExit()
        }
        /// Plays `seconds` of frames; `phase` maps elapsed seconds to what the keys show.
        func play(_ seconds: Double, _ phase: (Double) -> (HoldPhase?, Double)) {
            let grid = FrameGrid(framesPerSecond: 60)
            while true {
                let elapsed = min(seconds, ProbeClock.seconds(since: grid.start))
                let (hold, press) = phase(elapsed)
                show(hold, press: press)
                if elapsed >= seconds { return }
                Thread.sleep(forTimeInterval: ProbeClock.seconds(until: grid.next()))
            }
        }
        show(nil, press: 0)
        // The press as the controller draws it: turning over as the key goes down, back as it
        // comes up (or as the hold fires).
        let time = KeyDesign.pressTime
        func down(_ t: Double) -> Double { Motion.ease(t / time) }
        func up(_ t: Double, from start: Double) -> Double { 1 - Motion.ease((t - start) / time) }
        say("按满一秒：环收进来，走满后从环向内外扩散反色。右边封面键跟着环一起缩进去")
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.6)
            // Held for the second; it fires and turns back up; let go 0.4 s later (nothing changes).
            play(1 + KeyHold.confirmDuration + 0.3) { t in
                if t < 1 { return (.holding(t), down(t)) }
                if t < 1 + KeyHold.confirmDuration { return (.confirmed((t - 1) / KeyHold.confirmDuration), up(t, from: 1)) }
                return (nil, 0)
            }
        }
        for (at, words) in [(0.25, "按到四分之一松手"), (0.67, "按到三分之二松手")] {
            say(words)
            for _ in 0..<2 {
                Thread.sleep(forTimeInterval: 0.6)
                play(at + KeyHold.releaseDuration + 0.1) { t in
                    if t < at { return (.holding(t), down(t)) }
                    if t < at + KeyHold.releaseDuration { return (.released(from: at, (t - at) / KeyHold.releaseDuration), up(t, from: at)) }
                    return (nil, 0)
                }
            }
        }
        show(nil, press: 0)
        Thread.sleep(forTimeInterval: 1)
        device.clearKeys(Array(1...15))
        device.waitUntilIdle()
        device.close(notifyDevice: true)
    }
}
