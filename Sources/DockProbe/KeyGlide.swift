import CoreGraphics
import DockCore
import DockKit
import Foundation

/// `dock-probe keyglide [path…] [--black]`: a white disc gliding across the keys at a steady speed, drawn on
/// the real key layout (`KeyField`): it should read as one object moving behind the faceplate,
/// spending as long in a gap as its width there takes. Paths, each announced aloud: `across`
/// (the middle row, left to right and back), `down` (the middle column), `diagonal` (key 1 to 15
/// and back), `circle` (round key 8, through 3, 9, 13, 7), `naive` (the middle row again, but with
/// the keys pushed together as if there were no gaps — the old way, for comparison). Default: all.
@MainActor enum KeyGlide {
    struct Path { let name: String; let say: String; let seconds: Double; let gapless: Bool; let at: (Double) -> (x: Double, y: Double) }

    static let radius = 20.0
    static var paths: [Path] {
        let w = Double(M18Layout.keyFieldWidth), h = Double(M18Layout.keyFieldHeight), pitch = Double(M18Layout.keyPitch)
        let midY = h / 2, midX = w / 2
        // Out past the edge and back, at one speed.
        func there(_ t: Double) -> Double { t < 0.5 ? t * 2 : 2 - t * 2 }
        return [
            Path(name: "across", say: "中间一排，从左到右再回来", seconds: 6, gapless: false) { t in
                (-radius + there(t) * (w + 2 * radius), midY) },
            Path(name: "down", say: "中间一列，从上到下再回来", seconds: 4, gapless: false) { t in
                (midX, -radius + there(t) * (h + 2 * radius)) },
            Path(name: "diagonal", say: "对角线，一号键到十五号键再回来", seconds: 6, gapless: false) { t in
                (32 + there(t) * (w - 64), 32 + there(t) * (h - 64)) },
            Path(name: "circle", say: "绕八号键转两圈", seconds: 8, gapless: false) { t in
                let angle = t * 4 * .pi - .pi / 2
                return (midX + pitch * cos(angle), midY + pitch * sin(angle)) },
            Path(name: "naive", say: "对比：旧做法，当作键和键之间没有间隔", seconds: 6, gapless: true) { t in
                let field = Double(M18Layout.columns * M18Layout.keyImageSize)
                return (-radius + there(t) * (field + 2 * radius), Double(M18Layout.keyImageSize) * 1.5) },
        ]
    }

    static func run(_ arguments: [String]) throws {
        guard let identity = M18Device.attached().first else { print("no M18 attached"); return }
        let names = arguments.filter { !$0.hasPrefix("--") }
        let chosen = paths.filter { names.isEmpty || names.contains($0.name) }
        var device = try M18Device(opening: identity) { _ in }
        if arguments.contains("--black") {
            // Clears a test picture left in the window rims by `keywindows --seam`.
            device.setBackgroundImage(KeyWindows.fullScreen { _ in })
            device.waitUntilIdle()
            device = try KeyWindows.reopen(after: device) { _ in }
        }
        device.setScreenBrightness(80)
        device.clearKeys(Array(1...15))
        let player = FieldPlayer(device: device)
        for path in chosen {
            print("\(path.name): \(path.say)")
            let speech = try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: [path.say])
            speech?.waitUntilExit()
            player.play(seconds: path.seconds) { field, elapsed in
                let t = min(1, elapsed / path.seconds)
                let p = path.at(t)
                field.context.setFillColor(CGColor(gray: 1, alpha: 1))
                if path.gapless {
                    // Draw on keys pushed together: key column c spans 64c..<64(c+1), mapped onto its real place.
                    let size = Double(M18Layout.keyImageSize)
                    for column in 0..<M18Layout.columns {
                        let shift = Double(column * M18Layout.keyGap)
                        field.context.saveGState()
                        field.context.clip(to: CGRect(x: Double(column * M18Layout.keyPitch), y: 0, width: size, height: Double(field.height)))
                        field.context.fillEllipse(in: CGRect(x: p.x + shift - radius, y: p.y + 32 - radius, width: radius * 2, height: radius * 2))
                        field.context.restoreGState()
                    }
                } else {
                    field.context.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
                }
            }
            Thread.sleep(forTimeInterval: 0.6)
        }
        device.clearKeys(Array(1...15))
        device.waitUntilIdle()
        device.close(notifyDevice: true)
    }
}

/// Plays a drawing on the key field at 60 frames a second, sending only the keys that changed.
@MainActor final class FieldPlayer {
    let device: M18Device
    let field = KeyField()
    private var shown: [Int: Data] = [:]

    init(device: M18Device) { self.device = device }

    /// Calls `draw` with a cleared field and the seconds since the start, every frame for `seconds`.
    func play(seconds: Double, draw: (KeyField, Double) -> Void) {
        let grid = FrameGrid(framesPerSecond: 60)
        while true {
            let elapsed = min(seconds, ProbeClock.seconds(since: grid.start))
            field.clear()
            draw(field, elapsed)
            var changed: [Int: Data] = [:]
            for (key, image) in field.keyImages() {
                guard let jpeg = KeyRenderer.jpeg(image), shown[key] != jpeg else { continue }
                changed[key] = jpeg
                shown[key] = jpeg
            }
            device.setKeyImages(changed)
            if elapsed >= seconds { return }
            Thread.sleep(forTimeInterval: ProbeClock.seconds(until: grid.next()))
        }
    }
}
