import DockCore
import DockKit
import Foundation

/// `dock-probe pressdemo`: the press feedback on a row of typical keys (a glyph, a value, a white
/// "on" key, green live, red alert, a quota meter, an app icon), pressed and released one after
/// another, then all together, drawn as the controller does (`KeyDesign.pressTime` on
/// `Motion.ease`, 60 frames a second). Run the release build.
@MainActor enum PressDemo {
    static func run() throws {
        guard let identity = M18Device.attached().first else { print("no M18 attached"); return }
        var faces: [Int: KeyFace] = [
            1: KeyFace(symbol: "speaker.wave.2.fill"),
            2: KeyFace(title: "45", caption: "Volume"),
            3: KeyFace(symbol: "power", caption: "PC", tone: .on),
            4: KeyFace(symbol: "dot.radiowaves.left.and.right", caption: "Live", tone: .live),
            5: KeyFace(symbol: "mic.slash.fill", caption: "Muted", tone: .alert),
            7: KeyFace(title: "83%", caption: "5h", meter: KeyMeter(fraction: 0.83, color: RGB(hex: "#E4643F"))),
            8: KeyFace(symbol: "moon.fill", caption: "Sleep"),
        ]
        if let icon = KeyRenderer.jpeg(for: KeyFace(symbol: "sparkle", tone: .alert)) { faces[6] = KeyFace(artwork: icon) }
        let device = try M18Device(opening: identity) { _ in }
        device.setScreenBrightness(80)
        device.clearKeys(Array(1...15))
        var shown: [Int: Double] = [:]
        func show(_ press: [Int: Double]) {
            var images: [Int: Data] = [:]
            for (key, face) in faces {
                let value = press[key] ?? 0
                guard shown[key] != value else { continue }
                shown[key] = value
                images[key] = KeyRenderer.jpeg(for: face, press: value)
            }
            device.setKeyImages(images)
        }
        /// Down, held, up on `keys`.
        func press(_ keys: [Int], hold: Double = 0.35) {
            let time = KeyDesign.pressTime, total = time + hold + time
            let grid = FrameGrid(framesPerSecond: 60)
            while true {
                let t = min(total, ProbeClock.seconds(since: grid.start))
                let value = t < time ? Motion.ease(t / time) : t < time + hold ? 1 : 1 - Motion.ease((t - time - hold) / time)
                show(Dictionary(uniqueKeysWithValues: keys.map { ($0, value) }))
                if t >= total { return }
                Thread.sleep(forTimeInterval: ProbeClock.seconds(until: grid.next()))
            }
        }
        func say(_ text: String) {
            print(text)
            (try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: [text]))?.waitUntilExit()
        }
        show([:])
        say("逐个按下")
        for _ in 0..<2 {
            for key in faces.keys.sorted() { press([key]); Thread.sleep(forTimeInterval: 0.25) }
        }
        say("快速连点")
        for _ in 0..<4 { press([2], hold: 0.05); Thread.sleep(forTimeInterval: 0.1) }
        say("一起按住")
        press(Array(faces.keys), hold: 1.2)
        Thread.sleep(forTimeInterval: 0.8)
        device.clearKeys(Array(1...15))
        device.waitUntilIdle()
        device.close(notifyDevice: true)
    }
}
