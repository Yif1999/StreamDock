import CoreGraphics
import DockCore
import DockKit
import Foundation

/// `dock-probe keyease [scene…]`: the shared motion curve (`Motion`) on the keys, each scene
/// announced aloud. `linear` (hops along the middle row at constant speed, for comparison),
/// `ease` (the same hops on `Motion.ease`), `stretch` (plus squash and stretch from speed),
/// `drop` (key 3 down to key 13, squashing on landing and springing back with `Motion.settle`),
/// `pop` (a disc popping up on key 8 with `settle`, then easing away). Default: all.
@MainActor enum KeyEase {
    typealias Point = (x: Double, y: Double)
    static let radius = 20.0

    static func center(_ key: Int) -> Point {
        let origin = M18Layout.keyOrigin(key), half = Double(M18Layout.keyImageSize) / 2
        return (Double(origin.x) + half, Double(origin.y) + half)
    }

    /// Hops between key centers, a short rest at each; returns where the disc is and its velocity
    /// (field pixels per unit of hop time) at `elapsed`.
    struct Hops {
        let stops: [Point]
        let curve: (Double) -> Double
        let speed: (Double) -> Double
        static let rest = 0.3
        var legs: [(from: Point, to: Point, seconds: Double)] {
            zip(stops, stops.dropFirst()).map { a, b in (a, b, Motion.duration(distance: hypot(b.x - a.x, b.y - a.y))) }
        }
        var seconds: Double { legs.reduce(Hops.rest) { $0 + $1.seconds + Hops.rest } }

        func at(_ elapsed: Double) -> (point: Point, direction: Double, speed: Double) {
            var time = elapsed - Hops.rest
            for leg in legs {
                let direction = atan2(leg.to.y - leg.from.y, leg.to.x - leg.from.x)
                if time < 0 { return (leg.from, direction, 0) }
                if time < leg.seconds {
                    let t = time / leg.seconds, f = curve(t)
                    return ((leg.from.x + (leg.to.x - leg.from.x) * f, leg.from.y + (leg.to.y - leg.from.y) * f), direction, speed(t))
                }
                time -= leg.seconds + Hops.rest
            }
            return (stops.last!, 0, 0)
        }
    }

    static func disc(_ field: KeyField, at p: Point, along: Double = 1, across: Double = 1, angle: Double = 0) {
        let context = field.context
        context.saveGState()
        context.translateBy(x: p.x, y: p.y)
        context.rotate(by: angle)
        context.scaleBy(x: along, y: across)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        context.restoreGState()
    }

    static func run(_ arguments: [String]) throws {
        guard let identity = M18Device.attached().first else { print("no M18 attached"); return }
        let row = [6, 8, 10, 9, 6].map(center)
        let linear = Hops(stops: row, curve: { $0 }, speed: { _ in 1 })
        let eased = Hops(stops: row, curve: Motion.ease, speed: Motion.speed)
        let drop = Hops(stops: [center(3), center(13)], curve: Motion.ease, speed: Motion.speed)
        let landing = 0.35
        let scenes: [(name: String, say: String, seconds: Double, draw: (KeyField, Double) -> Void)] = [
            ("linear", "对比：匀速", linear.seconds, { field, elapsed in disc(field, at: linear.at(elapsed).point) }),
            ("ease", "统一缓动曲线：起步缓，中段快，结尾缓", eased.seconds, { field, elapsed in disc(field, at: eased.at(elapsed).point) }),
            ("stretch", "加上挤压拉伸：越快拉得越长", eased.seconds, { field, elapsed in
                let now = eased.at(elapsed)
                let shape = Motion.stretch(speed: now.speed)
                disc(field, at: now.point, along: shape.along, across: shape.across, angle: now.direction)
            }),
            ("drop", "落下：着地压扁再弹回", drop.seconds + landing, { field, elapsed in
                let now = drop.at(elapsed), landed = elapsed - (drop.seconds - Hops.rest)
                if landed > 0 {
                    // Lands squashed (wide, flat) and springs back through a little too tall.
                    let squash = 0.3 * (1 - Motion.settle(landed / landing))
                    let wide = 1 + squash, flat = 1 / wide
                    disc(field, at: (now.point.x, now.point.y + radius * (1 - flat)), along: wide, across: flat)
                } else {
                    let shape = Motion.stretch(speed: now.speed)
                    disc(field, at: now.point, along: shape.along, across: shape.across, angle: now.direction)
                }
            }),
            ("pop", "弹出再收起", 1.6, { field, elapsed in
                let grow = 0.35, hold = 0.8, shrink = 0.3
                let scale: Double
                if elapsed < grow { scale = Motion.settle(elapsed / grow) }
                else if elapsed < grow + hold { scale = 1 }
                else { scale = 1 - Motion.ease(min(1, (elapsed - grow - hold) / shrink)) }
                if scale > 0.01 { disc(field, at: center(8), along: scale, across: scale) }
            }),
        ]
        let chosen = scenes.filter { arguments.isEmpty || arguments.contains($0.name) }
        let device = try M18Device(opening: identity) { _ in }
        device.setScreenBrightness(80)
        device.clearKeys(Array(1...15))
        let player = FieldPlayer(device: device)
        for scene in chosen {
            print("\(scene.name): \(scene.say)")
            let speech = try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: [scene.say])
            speech?.waitUntilExit()
            for _ in 0..<2 { player.play(seconds: scene.seconds, draw: scene.draw); Thread.sleep(forTimeInterval: 0.4) }
            Thread.sleep(forTimeInterval: 0.4)
        }
        device.clearKeys(Array(1...15))
        device.waitUntilIdle()
        device.close(notifyDevice: true)
    }
}
