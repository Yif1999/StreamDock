import DockCore
import DockKit
import Foundation

/// `dock-probe digitdemo`: numbers changing in place — volume counting up and down a step at a
/// time as if the key were held, brightness and a percentage alongside — to check that only the
/// digits change and nothing shifts sideways or up and down.
@MainActor enum DigitDemo {
    static func run() throws {
        guard let identity = M18Device.attached().first else { print("no M18 attached"); return }
        let device = try M18Device(opening: identity) { _ in }
        device.setScreenBrightness(80)
        device.clearKeys(Array(1...15))
        var shown: [Int: KeyFace] = [:]
        func show(_ faces: [Int: KeyFace]) {
            var images: [Int: Data] = [:]
            for (key, face) in faces where shown[key] != face {
                shown[key] = face
                images[key] = KeyRenderer.jpeg(for: face)
            }
            device.setKeyImages(images)
        }
        print("volume 40 → 69 → 40, brightness and percent alongside")
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: ["数字原地变化"])
        Thread.sleep(forTimeInterval: 1.5)
        let steps = Array(40...69) + Array((40...68).reversed())
        for _ in 0..<2 {
            for (index, volume) in steps.enumerated() {
                show([
                    7: KeyFace(title: "\(volume)", caption: "Volume"),
                    8: KeyFace(title: "\(100 - volume)", caption: "Brightness"),
                    9: KeyFace(title: "\(volume + index % 7)%", caption: "5h"),
                ])
                Thread.sleep(forTimeInterval: 0.12)
            }
        }
        device.clearKeys(Array(1...15))
        device.waitUntilIdle()
        device.close(notifyDevice: true)
    }
}
