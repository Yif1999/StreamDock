import Foundation
import DockCore
import DockKit

/// `dock-probe chordtest [--guide [rows|cols]] [seconds]`: what the M18 reports when several keys are
/// held. Every press and release is printed with its time and the keys the device then reports held;
/// an LCD key is white on screen while the device reports it held, so a key lost under a finger shows
/// up as one that stays dark.
///
/// Without `--guide` it ends after the given time (default 180 s) or on the middle round key pressed
/// with nothing else held. With `--guide` it reads out a set of steps — keys in one row (`rows`, the
/// default) or in one column and across the diagonal (`cols`); the middle round key, with nothing
/// else held, moves on to the next step.
enum ChordTest {
    static let rows = [
        "按住 1，再按 3。先松开 3，再松开 1。做三次",
        "按住 1，再按 3。这次先松开 1，再松开 3。做三次",
        "按住 1 不放，依次点 3、5、3、5，最后松开 1",
        "按住 1，再按住 3，再按 5。然后按 5、3、1 的顺序松开",
        "按住 1，再按住 3，再按 5。然后按 1、3、5 的顺序松开",
        "用两根手指同时拍下 6 和 8，再一起松开。做五次",
        "1 和 3 交替快速点，尽量不要同时按住。点十几下",
        "按住左边圆键，再按 8。然后按住 8，再按右边圆键",
    ]
    static let cols = [
        "同一列：按住 2，再按 12。先松开 2，再松开 12。做三次",
        "同一列相邻：按住 3，再按 8。先松开 3，再松开 8。做三次",
        "对角相邻：按住 1，再按 7。先松开 1，再松开 7。做三次",
        "对角最远：按住 1，再按 15。先松开 1，再松开 15。做三次",
        "不同行也不同列：按住 5，再按 11。先松开 5，再松开 11。做三次",
        "同一列三个键：依次按住 3、8、13。然后按 3、8、13 的顺序松开。做两次",
        "同一列：用两根手指同时拍下 2 和 12，再一起松开。做五次",
    ]

    @MainActor static func run(_ arguments: [String]) throws {
        final class Events: @unchecked Sendable {
            private let lock = NSLock()
            private var queue: [(Double, DockInputEvent)] = []
            func add(_ event: DockInputEvent) {
                let now = ProcessInfo.processInfo.systemUptime
                lock.lock(); queue.append((now, event)); lock.unlock()
            }
            func take() -> [(Double, DockInputEvent)] { lock.lock(); defer { queue = []; lock.unlock() }; return queue }
        }
        let guided = arguments.contains("--guide")
        let steps = arguments.contains("cols") ? cols : rows
        let events = Events()
        guard let identity = M18Device.attached().first else { print("no M18 attached"); return }
        let device = try M18Device(opening: identity) { events.add($0) }
        device.setScreenBrightness(80)
        func face(_ key: Int, held: Bool) -> Data {
            KeyRenderer.jpeg(for: KeyFace(title: "\(key)", tone: held ? .on : .normal))!
        }
        device.setKeyImages(Dictionary(uniqueKeysWithValues: (1...15).map { ($0, face($0, held: false)) }))
        var speech: Process?
        func say(_ text: String) {
            speech?.terminate()
            speech = try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: [text])
        }

        let seconds = arguments.lazy.compactMap(Double.init).first ?? (guided ? 1800 : 180)
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + seconds
        var held: [DockKey] = []
        var mostHeld = 0, anomalies = 0, lastPress: Double?
        var step = 0
        func name(_ key: DockKey) -> String {
            switch key { case .lcd(let n): "键\(n)"; case .round(let n): "圆\(n)" }
        }
        func announce() {
            if step < steps.count {
                print("\n=== 第 \(step + 1) 步：\(steps[step])")
                say("第\(step + 1)步。\(steps[step])。做完单独按中间圆键")
            } else {
                print("\n=== 全部完成")
                say("测试完成")
            }
        }
        if guided {
            print("chordtest --guide: \(steps.count) steps; the middle round key alone moves on")
            announce()
        } else {
            print("chordtest: press keys together (two, then three, then more); middle round key alone ends")
            say("开始测试。请同时按住两个键、三个键，再试更多。单独按中间圆键结束")
        }
        loop: while ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.005)
            var changed: [Int: Bool] = [:]
            for (time, event) in events.take() {
                let ms = Int((time - start) * 1000)
                var note = ""
                if event.pressed {
                    if held.contains(event.key) { note = "  ⚠ 重复按下"; anomalies += 1 } else { held.append(event.key) }
                    if let lastPress { note += "  距上次按下 \(Int((time - lastPress) * 1000)) ms" }
                    lastPress = time
                } else {
                    if let index = held.firstIndex(of: event.key) { held.remove(at: index) } else { note = "  ⚠ 松开了没按下的键"; anomalies += 1 }
                }
                mostHeld = max(mostHeld, held.count)
                print(String(format: "%7d ms  %@ %@   按住: [%@]%@", ms, event.pressed ? "↓" : "↑", name(event.key),
                             held.map(name).joined(separator: " "), note))
                if case .lcd(let n) = event.key { changed[n] = event.pressed }
                if event.pressed, event.key == .round(2), held == [.round(2)] {
                    guard guided else { break loop }
                    step += 1
                    announce()
                    if step >= steps.count { break loop }
                }
            }
            if !changed.isEmpty {
                device.setKeyImages(Dictionary(uniqueKeysWithValues: changed.map { ($0.key, face($0.key, held: $0.value)) }))
            }
        }
        Thread.sleep(forTimeInterval: guided ? 1.5 : 0)
        print("最多同时按住 \(mostHeld) 个键；异常 \(anomalies) 次；结束时仍按住: [\(held.map(name).joined(separator: " "))]")
        device.clearKeys(Array(1...15))
        device.waitUntilIdle()
        device.close(notifyDevice: true)
    }
}
