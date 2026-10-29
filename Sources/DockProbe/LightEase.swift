import DockCore
import DockKit
import Foundation

/// `dock-probe lightease`: the light strip's cross-fades on three curves, each announced aloud:
/// the strip's own `Motion.light` (smoothstep, 1.5× average speed at the middle), the keys'
/// `Motion.keys` (5×), and one between them (2.5×) — all one formula (`Motion.Curve`). Each plays a
/// scene switch (blue ↔ amber, 0.5 s), a page turn to a new color (1.5 s) and a fade in from dark
/// and out (0.8 s). Quit the app first.
@MainActor enum LightEase {
    static func run() throws {
        guard let identity = M18Device.attached().first else { print("no M18 attached"); return }
        let curves: [(say: String, curve: (Double) -> Double)] = [
            ("一：灯带现在的曲线", Motion.light.ease),
            ("二：按键的统一曲线", Motion.ease),
            ("三：更柔和的同族曲线", Motion.Curve(peak: 2.5).ease),
        ]
        let gain = Double(DockSettings(defaults: UserDefaults(suiteName: "dev.yif.StreamDock") ?? .standard).ledBrightness) / 100
        let device = try M18Device(opening: identity) { _ in }
        device.setLEDBrightness(100)
        var output = LEDOutput()
        let count = Int(M18Layout.ledCount)
        var shown = LightPixel.black
        func send(_ pixel: LightPixel) {
            device.setLEDFrame(output.render(Array(repeating: pixel, count: count), gain: gain).map { ($0.red, $0.green, $0.blue) })
        }
        /// Cross-fades from what is shown to `target` over `seconds`, then holds it `hold` seconds.
        func fade(to target: LightPixel, _ seconds: Double, hold: Double, _ curve: (Double) -> Double) {
            let from = shown, grid = FrameGrid(framesPerSecond: 60)
            while true {
                let elapsed = ProbeClock.seconds(since: grid.start)
                let t = min(1, elapsed / seconds)
                shown = from.mixed(with: target, amount: curve(t))
                send(shown)
                if elapsed >= seconds + hold { return }
                Thread.sleep(forTimeInterval: ProbeClock.seconds(until: grid.next()))
            }
        }
        func say(_ text: String) {
            print(text)
            let speech = try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: [text])
            while speech?.isRunning == true { send(shown); Thread.sleep(forTimeInterval: 1.0 / 60) }
        }
        let blue = LightPixel(RGB(hex: "#0A84FF")), amber = LightPixel(RGB(hex: "#FF9F0A")), green = LightPixel(RGB(hex: "#30D158"))
        shown = blue
        send(shown)
        for (words, curve) in curves {
            say(words)
            for _ in 0..<2 {
                fade(to: amber, 0.5, hold: 1, curve)   // scene switch
                fade(to: blue, 0.5, hold: 1, curve)
            }
            fade(to: green, 1.5, hold: 1, curve)       // page turn
            fade(to: blue, 1.5, hold: 0.6, curve)
            fade(to: .black, 0.8, hold: 0.5, curve)    // fade out, then in
            fade(to: blue, 0.8, hold: 1, curve)
        }
        for _ in 0..<2 { send(.black) }
        device.waitUntilIdle()
        device.close(notifyDevice: true)
    }
}
