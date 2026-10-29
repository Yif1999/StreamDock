import ControlModules
import DockCore
import DockKit
import Foundation

/// `dock-probe quotademo`: the Vibe Coding quota gauges (Codex and Claude, 5h and Week) taking
/// new readings, announced aloud: first filling up from empty, then two new readings gliding
/// (`ValueTransitions`, as `AIQuotaModule` does), then the same two readings cut in hard, the old
/// way, for comparison.
@MainActor enum QuotaDemo {
    static func run() throws {
        guard let identity = M18Device.attached().first else { print("no M18 attached"); return }
        let device = try M18Device(opening: identity) { _ in }
        device.setScreenBrightness(80)
        device.clearKeys(Array(1...15))
        let keys: [(key: Int, service: AIService, label: String)] = [
            (7, .codex, "5h"), (8, .codex, "Week"), (12, .claude, "5h"), (13, .claude, "Week"),
        ]
        var targets: [Double] = [0, 0, 0, 0]
        var gliding = true
        var shown: [Int: KeyFace] = [:]
        let gauges = ValueTransitions<Int>()
        func draw() {
            var images: [Int: Data] = [:]
            for (index, key) in keys.enumerated() {
                let left = gliding ? gauges.value(key.key, target: targets[index]) : targets[index]
                let face = KeyFace(title: "\(Int((left * 100).rounded()))%", caption: key.label,
                                   meter: KeyMeter(fraction: left, color: key.service.color))
                guard shown[key.key] != face else { continue }
                shown[key.key] = face
                images[key.key] = KeyRenderer.jpeg(for: face)
            }
            device.setKeyImages(images)
        }
        gauges.redraw = draw
        func say(_ text: String) {
            print(text)
            let speech = try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: [text])
            while speech?.isRunning == true { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        func reading(_ values: [Double], hold: Double = 2.5) {
            targets = values
            draw()
            RunLoop.main.run(until: Date().addingTimeInterval(hold))
        }
        draw()
        say("缓动：第一次读数，从空填满")
        reading([0.97, 0.81, 0.62, 0.83])
        say("新读数")
        reading([0.41, 0.74, 0.18, 0.80])
        say("再一次")
        reading([0.88, 0.70, 0.95, 0.79])
        say("对比：旧做法，硬切")
        gliding = false
        reading([0.41, 0.74, 0.18, 0.80])
        reading([0.88, 0.70, 0.95, 0.79])
        device.clearKeys(Array(1...15))
        device.waitUntilIdle()
        device.close(notifyDevice: true)
    }
}
