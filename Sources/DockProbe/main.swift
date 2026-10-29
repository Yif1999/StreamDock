// Hardware smoke test for DockKit + DockCore, without the menu bar app.
//
//   dock-probe run [seconds]   three numbered test scenes; round keys switch, presses are logged
//   dock-probe preview <dir>   write sample key renders as PNGs
//   dock-probe list            list attached M18s
//   dock-probe ledmap          static light-strip patterns, held still for checking by eye
//   dock-probe rhythm-eval <trace>  replay a rhythm trace and score it against tapped beats
//   dock-probe ddc             read brightness / volume from the external monitor over DDC
//   dock-probe cpa <base-url>  read-only: CPA accounts and the Claude / Codex quota replies (key in CPA_KEY)
//   dock-probe fpstest [rate…] [--all]  frame numbers at each rate, for a slow-motion video
//   dock-probe agentlight [codex|claude|both]  light-strip reminders, as a narrated story
//   dock-probe ledbench [seconds]  light-strip frames at 60 Hz: dropped frames and send lateness
//   dock-probe ledwalk [rate…]  one lit LED walking the ring at each rate, for a slow-motion video
//   dock-probe ledscan <video> [rate…]  read an ledwalk video: frames the strip actually showed
//   dock-probe bandcompare <trace>  current vs proposed spectrum split for kick / snare / cymbals
//   dock-probe obslight        OBS recording + streaming split light, red/green and amber/green
//   dock-probe ledcorners [fl fr br bl]  find the four corners on the ring with the round keys (calibration)
//   dock-probe satsteps [hue] [percent…]  one hue at falling saturation (100 % … 40 %), announced aloud
//   dock-probe glowdemo high  the music light's high-frequency glints on their own, then under drums
//   dock-probe digitdemo       numbers counting in place (volume, brightness, a percentage)
//   dock-probe pressdemo       the press feedback on typical keys (release build)
//   dock-probe quotademo       the quota gauges gliding to new readings, then cut in hard for comparison
//   dock-probe holddemo        the long-press ring on three keys: held through, and let go early (release build)
//   dock-probe keyease [scene…]  the shared motion curve on the keys: linear vs ease, stretch, drop, pop
//   dock-probe keyglide [path…]  a disc gliding across the keys on the real key layout (KeyField)
//   dock-probe keywindows      a ruler on every key, photographed to measure the key layout (calibration)
//   dock-probe hookpreview   what loading the Codex / Claude hooks would write (writes nothing)

import AppKit
import ImageIO
import UniformTypeIdentifiers
import ControlModules
import DockCore
import DockKit
import RhythmKit

final class ProbeModule: DockModule {
    let keyCount = 15
    private let sceneName: String

    init(sceneName: String) {
        self.sceneName = sceneName
    }

    func face(forSlot slot: Int) -> KeyFace {
        KeyFace(title: "\(slot + 1)", caption: slot == 0 ? sceneName : nil)
    }

    func keyDown(slot: Int) { print("[\(sceneName)] key \(slot + 1) down") }
    func keyUp(slot: Int) { print("[\(sceneName)] key \(slot + 1) up") }
    func sceneDidActivate() { print("scene -> \(sceneName)") }
}

@MainActor func probeScene(_ id: String, _ led: RGB) -> DockScene {
    let scene = DockScene(id: id, name: id, defaultLEDColor: led)
    scene.place(ProbeModule(sceneName: id), keys: Array(1...15))
    return scene
}

@MainActor func preview(into directory: String) throws {
    let faces: [(String, KeyFace)] = [
        ("value", KeyFace(title: "45", caption: "Volume")),
        ("symbol", KeyFace(symbol: "pause.fill")),
        ("symbol-caption", KeyFace(symbol: "mic.fill", caption: "Mic")),
        ("on", KeyFace(symbol: "star.fill", caption: "Loved", tone: .on)),
        ("alert", KeyFace(symbol: "mic.slash.fill", caption: "Muted", tone: .alert)),
    ]
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for (name, face) in faces {
        for pressed in [false, true] {
            guard let image = KeyRenderer.image(for: face, press: pressed ? 1 : 0) else { continue }
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            let path = "\(directory)/\(name)\(pressed ? "-pressed" : "").png"
            try png.write(to: URL(fileURLWithPath: path))
            print(path)
        }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "list":
    for identity in M18Device.attached() {
        print(identity.path, identity.serialNumber, String(identity.productID, radix: 16))
    }
case "ledmap":
    // Static light-strip test: each pattern holds still so it can be checked by eye.
    guard let identity = M18Device.attached().first else {
        print("no M18 attached")
        break
    }
    let device = try M18Device(opening: identity) { _ in }
    let count = Int(M18Layout.ledCount)
    device.setLEDBrightness(100)
    func hold(_ label: String, seconds: Double) {
        device.waitUntilIdle()
        print(label)
        Thread.sleep(forTimeInterval: seconds)
    }
    let segments: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]
    device.setLEDColors((0..<count).map { segments[$0 * segments.count / count] })
    hold("B) 0-5 red, 6-11 green, 12-17 blue, 18-23 white (10s)", seconds: 10)
    device.setLEDColors((0..<count).map { $0 == 0 ? (255, 255, 255) : (0, 0, 0) })
    hold("C) only LED 0 white (8s)", seconds: 8)
    device.setLEDColors((0..<count).map { $0 < 12 ? (255, 0, 0) : (0, 0, 255) })
    hold("D) LEDs 0-11 red, 12-23 blue (8s)", seconds: 8)
    device.setLEDColor(red: 0, green: 0, blue: 0)
    device.waitUntilIdle()
    device.close(notifyDevice: false)
    print("done")
case "keysheet":
    // dock-probe keysheet <out.png> [artwork]: the three general-control pages in the key
    // design system, 3× nearest-neighbour.
    let positional = arguments.dropFirst().filter { !$0.hasPrefix("--") }
    let output = positional.first ?? "build/keysheet.png"
    let art = positional.dropFirst().first.flatMap { FileManager.default.contents(atPath: $0) }
    // --pressed: every key as shown while held down.
    try writeKeySheet(to: output, artwork: art, pressed: arguments.contains("--pressed"))
    print("wrote \(output)")
case "holdsheet":
    // dock-probe holdsheet <out.png> [artwork]: the long-press ring on the three hold keys,
    // pressed: closing in (0.1, 0.2), ½, full, then the response (flash) part way (3×).
    let positional = arguments.dropFirst().filter { !$0.hasPrefix("--") }
    let output = positional.first ?? "build/holdsheet.png"
    let art = positional.dropFirst().first.flatMap { FileManager.default.contents(atPath: $0) }
    let steps: [HoldPhase] = [.holding(0.1), .holding(0.2), .holding(0.5), .holding(0.999), .confirmed(0.3), .confirmed(0.7)]
    let rows: [(HoldPhase) -> CGImage?] = [
        { KeyDesign.image(symbol: "moon.fill", label: "Sleep", hold: $0, press: 1) },
        { KeyDesign.image(value: "86W", label: "PC", tone: .on, hold: $0, press: 1) },
        { KeyDesign.image(symbol: "music.note", label: art == nil ? "Music" : nil, artwork: art, hold: $0, press: 1) },
    ]
    let zoom = 3, cell = 64 * zoom, gap = 24
    let width = steps.count * cell + (steps.count + 1) * gap, height = rows.count * cell + (rows.count + 1) * gap
    let sheet = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    sheet.setFillColor(CGColor(gray: 0.12, alpha: 1)); sheet.fill(CGRect(x: 0, y: 0, width: width, height: height))
    sheet.interpolationQuality = .none
    for (r, render) in rows.enumerated() { for (c, step) in steps.enumerated() {
        guard let key = render(step) else { continue }
        sheet.draw(key, in: CGRect(x: gap + c * (cell + gap), y: height - (r + 1) * (cell + gap), width: cell, height: cell))
    } }
    let png = NSBitmapImageRep(cgImage: sheet.makeImage()!).representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: output))
    print("wrote \(output)")
case "fpstest":
    // dock-probe fpstest [rate…] [--all]: frame numbers on key 1 (--all: every key) at each rate
    // (default 24 60 114), 5 s each, after a 2 s card naming the rate. Film it in slow motion and
    // count the numbers that appear: skipped numbers mean the screen shows fewer frames than it is
    // sent. Each run ends on a red END card printed as sent: the device sends no replies, so if the
    // link falls behind, the numbers keep running after "END sent" for as long as the backlog.
    guard let identity = M18Device.attached().first else {
        print("no M18 attached")
        break
    }
    let rates = arguments.dropFirst().compactMap(Double.init).filter { $0 > 0 }
    let side = M18Layout.keyImageSize
    func card(_ text: String, ink: NSColor, ground: NSColor, bar: Int?) -> Data {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(ground.cgColor); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // A bar that steps 4 px a frame along the top, so a torn or skipped frame shows as a jump.
        if let bar { context.setFillColor(NSColor.systemGreen.cgColor); context.fill(CGRect(x: bar * 4, y: side - 10, width: 4, height: 10)) }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: text.count > 2 ? 22 : 34, weight: .bold), .foregroundColor: ink,
        ])
        let size = label.size()
        label.draw(at: CGPoint(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - 10 - size.height) / 2))
        NSGraphicsContext.current = nil
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
    let numbers = (0..<100).map { card(String(format: "%02d", $0), ink: .white, ground: .black, bar: $0 % 16) }
    let device = try M18Device(opening: identity) { _ in }
    device.setScreenBrightness(80)
    device.clearKeys(Array(1...15))
    let keys = arguments.contains("--all") ? Array(1...15) : [1]
    func all(_ image: Data) -> [Int: Data] { Dictionary(uniqueKeysWithValues: keys.map { ($0, image) }) }
    let end = card("END", ink: .white, ground: .systemRed, bar: nil)
    for rate in rates.isEmpty ? [24, 60, 114] : rates {
        device.setKeyImages(all(card("\(Int(rate))/s", ink: .black, ground: .systemYellow, bar: nil)))
        print("\(Int(rate)) frames/s on \(keys.count) key(s): card for 2 s, then 5 s of numbers 00–99")
        Thread.sleep(forTimeInterval: 2)
        let start = Date()
        for frame in 0..<Int(rate * 5) {
            let due = start.addingTimeInterval(Double(frame) / rate)
            if due > Date() { Thread.sleep(until: due) }
            // Each key runs a few numbers ahead of the last, so every key changes every frame.
            device.setKeyImages(Dictionary(uniqueKeysWithValues: keys.map { ($0, numbers[(frame + $0 * 7) % numbers.count]) }))
        }
        device.setKeyImages(all(end))
        // Count the seconds out loud: the second at which END shows is the backlog.
        print("END sent; note the second at which END appears on the keys")
        for second in 1...30 {
            Thread.sleep(forTimeInterval: 1)
            print("END +\(second) s")
            // Spoken too, so the count can be followed while watching the keys.
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: ["\(second)"])
        }
    }
    device.close(notifyDevice: true)
case "agentlight":
    // dock-probe agentlight [codex|claude|both] [step…] [--sheet <out.png>]: one app's (or both apps') light-strip reminders
    // as a story, each step announced aloud before its light, states running into each other as
    // they would in use. Quit the app first; it holds the device. --sheet draws it offline instead
    // (narration taken as 1.5 s; columns of 20 s, time downwards, ring LEDs 0–21 then the bars).
    let service: AIService = arguments.contains("codex") ? .codex : .claude
    let color = AgentLight.color(for: service), name = service.name
    let leds = Int(M18Layout.ledCount)
    // Idle shows the scene color at the inactive half brightness, as the app does.
    let idle = AgentLight.crossfade(Array(repeating: .black, count: leds), Array(repeating: LightPixel(RGB(hex: "#BEFCA2")), count: leds), amount: 0.5)
    typealias Light = (_ time: Double, _ since: Double) -> [LightPixel]
    func motion(_ m: AgentLight.Motion) -> Light { { AgentLight.pixels(AgentLight.levels(m, at: $0, since: $1), color: color, ledCount: leds) } }
    let rest: Light = { _, _ in idle }
    func then(_ first: @escaping Light, after: Double, _ second: @escaping Light, fade: Double) -> Light {
        { t, since in
            let into = t - since - after
            guard into >= 0 else { return first(t, since) }
            return AgentLight.crossfade(first(t, since), second(t, since + after), amount: into / fade)
        }
    }
    // What happens, how long its light runs, how it fades in from the light before, the light.
    let cx = AgentLight.color(for: .codex), cl = AgentLight.color(for: .claude)
    func on(_ m: AgentLight.Motion, _ c: RGB) -> Light { { AgentLight.pixels(AgentLight.levels(m, at: $0, since: $1), color: c, ledCount: leds) } }
    func bars(_ light: @escaping Light, _ c: RGB) -> Light { { AgentLight.withBars(light($0, $1), color: c) } }
    let bothWorking: Light = { t, _ in AgentLight.twoComets(cx, cl, at: t, ledCount: leds) }
    let both: [(say: String, seconds: Double, fade: Double, light: Light)] = [
        ("Codex 和 Claude 都开始工作", 8, 0.6, bothWorking),
        ("Claude 需要你批准，Codex 还在工作", 8, 0.3, bars(on(.summon, cl), cx)),
        ("Codex 也需要你批准", 9, 0.3, { AgentLight.alternatingSummon([cx, cl], at: $0, since: $1, ledCount: leds) }),
        ("你批准了 Claude，它继续工作，Codex 还在等你", 7, 0.3, bars(on(.summon, cx), cl)),
        ("你也批准了 Codex，两个都在工作", 6, 0.6, bothWorking),
        ("Codex 完成了，Claude 还在工作", 8, 0.15, bars(on(.close, cx), cl)),
        ("Claude 出错了", 14, 0.15, then(bars(on(.fail, cl), cx), after: AgentLight.failDuration,
                                          { t, _ in AgentLight.alternatingHolds([(.hold, cx), (.fault, cl)], at: t, ledCount: leds) }, fade: 1)),
        ("你查看了 Codex，只剩 Claude 的错误", 6, 1, on(.fault, cl)),
        ("你查看了 Claude，提醒消失", 4, 1.2, rest),
    ]
    let single: [(say: String, seconds: Double, fade: Double, light: Light)] = [
        ("你给 \(name) 发了一条消息，它开始工作", 7, 0.6, motion(.cruise)),
        ("它需要你批准一个操作，你不在它的窗口", 7, 0.3, motion(.summon)),
        ("你切到 \(name) 的窗口，正在看批准提示", 7, 0.6, motion(.quietSummon)),
        ("你批准了，它继续工作", 5, 0.6, motion(.cruise)),
        ("它完成了，你不在它的窗口", 9, 0.15, motion(.close)),
        ("你切回 \(name)，提醒消失", 4, 1.2, rest),
        ("新任务开始", 5, 0.6, motion(.cruise)),
        ("工作中途出错了，你不在它的窗口", 10, 0.15, motion(.fail)),
        ("你切回 \(name)，提醒消失", 4, 1.2, rest),
        ("再来一个任务，这次你一直看着它的窗口", 5, 0.6, motion(.cruise)),
        ("它完成了，你正看着", 5, 0.15, then(motion(.close), after: 1.6, rest, fade: 1.2)),
        ("最后一个任务", 5, 0.6, motion(.cruise)),
        ("你按 Esc 打断了它", 4, 1.2, rest),
    ]
    let story = arguments.contains("both") ? both : single
    // The light at `t`: the step's own light, faded in from where the previous one stood.
    func frame(_ t: Double, step: Int, since: Double, previous: Light, previousSince: Double) -> [LightPixel] {
        let item = story[step]
        let now = item.light(t, since)
        guard t - since < item.fade else { return now }
        return AgentLight.crossfade(previous(t, previousSince), now, amount: (t - since) / item.fade)
    }

    if let index = arguments.firstIndex(of: "--sheet"), arguments.indices.contains(index + 1) {
        let rowsPerSecond = 15.0, columnSeconds = 20.0, cell = 6, gap = 14
        var rows: [[RGB]] = []
        var output = LEDOutput()
        var t = 0.0, previous: Light = rest, previousSince = 0.0
        for step in story.indices {
            let speechEnd = t + 1.5
            while t < speechEnd { rows.append(output.render(previous(t, previousSince))); t += 1 / rowsPerSecond }
            let since = t
            while t < since + story[step].seconds {
                rows.append(output.render(frame(t, step: step, since: since, previous: previous, previousSince: previousSince)))
                t += 1 / rowsPerSecond
            }
            previous = story[step].light; previousSince = since
        }
        let perColumn = Int(columnSeconds * rowsPerSecond)
        let columns = (rows.count + perColumn - 1) / perColumn
        let columnWidth = 24 * cell + 6
        let width = columns * (columnWidth + gap), height = perColumn * 2
        let sheet = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        sheet.setFillColor(CGColor(gray: 0.1, alpha: 1)); sheet.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (r, rgb) in rows.enumerated() {
            let column = r / perColumn, row = r % perColumn
            for (slot, led) in (Array(0...21) + [22, 23]).enumerated() {
                let c = rgb[led]
                sheet.setFillColor(CGColor(srgbRed: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255, alpha: 1))
                sheet.fill(CGRect(x: column * (columnWidth + gap) + slot * cell + (slot >= 22 ? 6 : 0), y: height - (row + 1) * 2, width: cell - 1, height: 2))
            }
        }
        let png = NSBitmapImageRep(cgImage: sheet.makeImage()!).representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: arguments[index + 1]))
        print("wrote \(arguments[index + 1])")
        break
    }

    guard let identity = M18Device.attached().first else {
        print("no M18 attached")
        break
    }
    let gain = Double(DockSettings(defaults: UserDefaults(suiteName: "dev.yif.StreamDock") ?? .standard).ledBrightness) / 100
    let device = try M18Device(opening: identity) { _ in }
    device.setLEDBrightness(100)
    var output = LEDOutput()
    let clock = Date()
    let grid = FrameGrid(framesPerSecond: LightLayout.framesPerSecond)
    func send(_ frame: [LightPixel]) {
        device.setLEDFrame(output.render(frame, gain: gain).map { ($0.red, $0.green, $0.blue) })
        Thread.sleep(forTimeInterval: ProbeClock.seconds(until: grid.next()))
    }
    // Step numbers on the command line play just those steps, in order.
    let picked = arguments.compactMap(Int.init).filter { story.indices.contains($0 - 1) }.map { $0 - 1 }
    var previous: Light = rest, previousSince = 0.0
    for step in picked.isEmpty ? Array(story.indices) : picked {
        print("\(step + 1). \(story[step].say)")
        // The previous light keeps going while the next step is read out.
        let speech = try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: [story[step].say])
        while speech?.isRunning == true { send(previous(Date().timeIntervalSince(clock), previousSince)) }
        let since = Date().timeIntervalSince(clock)
        while Date().timeIntervalSince(clock) < since + story[step].seconds {
            send(frame(Date().timeIntervalSince(clock), step: step, since: since, previous: previous, previousSince: previousSince))
        }
        previous = story[step].light; previousSince = since
    }
    for _ in 0..<2 { send(idle) }
    device.waitUntilIdle()
    print("LED frames dropped (transport busy): \(device.droppedLEDFrames)")
    device.close(notifyDevice: true)
case "obslight":
    // dock-probe obslight: OBS recording and streaming together — red/green, then paused
    // (amber)/green — each announced aloud and held 8 s, rendered as the app renders it. Quit the
    // app first; it holds the device.
    guard let identity = M18Device.attached().first else { print("no M18 attached"); break }
    let gain = Double(DockSettings(defaults: UserDefaults(suiteName: "dev.yif.StreamDock") ?? .standard).ledBrightness) / 100
    let leds = Int(M18Layout.ledCount)
    let device = try M18Device(opening: identity) { _ in }
    device.setLEDBrightness(100)
    var output = LEDOutput()
    let clock = Date()
    let grid = FrameGrid(framesPerSecond: LightLayout.framesPerSecond)
    func send(_ frame: [LightPixel]) {
        device.setLEDFrame(output.render(frame, gain: gain).map { ($0.red, $0.green, $0.blue) })
        Thread.sleep(forTimeInterval: ProbeClock.seconds(until: grid.next()))
    }
    let cases: [(say: String, paused: Bool)] = [("红绿", false), ("黄绿", true)]
    var previous = cases[0]
    for item in cases {
        print(item.say)
        let speech = try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: [item.say])
        while speech?.isRunning == true {
            send(OBSLightPreview.pixels(paused: previous.paused, at: Date().timeIntervalSince(clock), ledCount: leds))
        }
        let since = Date().timeIntervalSince(clock)
        while Date().timeIntervalSince(clock) < since + 8 {
            send(OBSLightPreview.pixels(paused: item.paused, at: Date().timeIntervalSince(clock), ledCount: leds))
        }
        previous = item
    }
    send(Array(repeating: LightPixel(.black), count: leds))
    device.waitUntilIdle()
    device.close(notifyDevice: true)
case "ledcorners":
    // dock-probe ledcorners: find where the base's four corners fall on the ring. For each corner
    // (front-left, front-right, back-right, back-left, announced aloud) a bright marker sits on
    // the ring: the left and right round keys move it left and right as seen from the front, in
    // half-LED steps — one LED lit means the corner is at that LED, two lit that it falls between
    // them — and the middle round key confirms. Prints the four corners as ring positions.
    // Four positions on the command line (an earlier run's) start the markers there, for fine-tuning.
    // Quit the app first; it holds the device.
    guard let identity = M18Device.attached().first else { print("no M18 attached"); break }
    final class Presses: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [Int] = []
        func add(_ key: Int) { lock.lock(); keys.append(key); lock.unlock() }
        func take() -> [Int] { lock.lock(); defer { keys = []; lock.unlock() }; return keys }
    }
    let presses = Presses()
    let device = try M18Device(opening: identity) { event in
        if event.pressed, case .round(let key) = event.key { presses.add(key) }
    }
    device.setLEDBrightness(100)
    let leds = Int(M18Layout.ledCount), ring = M18Layout.ringLEDs.count
    let grid = FrameGrid(framesPerSecond: LightLayout.framesPerSecond)
    // Name, which way "left" runs round the ring there, where the even layout puts it.
    let corners: [(name: String, left: Double, guess: Double)] = [
        ("左前角", -1, 0.125), ("右前角", -1, 0.375), ("右后角", 1, 0.625), ("左后角", 1, 0.875),
    ]
    let earlier = arguments.dropFirst().compactMap(Double.init)
    var found: [Double] = []
    for (index, corner) in corners.enumerated() {
        var marker = earlier.count == 4 ? earlier[index] : (corner.guess * Double(ring) * 2 - 1).rounded() / 2
        print("\(corner.name): left/right round keys move, middle confirms")
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: ["\(corner.name)，用左右圆键把亮点移到角上，中间圆键确认"])
        var confirmed = false
        while !confirmed {
            for key in presses.take() {
                switch key {
                case 1: marker += 0.5 * corner.left
                case 3: marker -= 0.5 * corner.left
                default: confirmed = true
                }
                marker = (marker + Double(ring)).truncatingRemainder(dividingBy: Double(ring))
                if !confirmed { print("  \(marker)") }
            }
            let lit = marker == marker.rounded(.down) ? [Int(marker)] : [Int(marker), (Int(marker) + 1) % ring]
            device.setLEDFrame((0..<leds).map { lit.contains($0) ? (255, 255, 255) : $0 < ring ? (0, 0, 40) : (0, 0, 0) })
            Thread.sleep(forTimeInterval: ProbeClock.seconds(until: grid.next()))
        }
        print("  \(corner.name) = \(marker)")
        found.append(marker)
    }
    print("corners (front-left, front-right, back-right, back-left):", found.map { String($0) }.joined(separator: ", "))
    _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: ["校准完成"])
    for _ in 0..<2 { device.setLEDFrame(Array(repeating: (0, 0, 0), count: leds)) }
    device.waitUntilIdle()
    device.close(notifyDevice: true)
case "glowdemo":
    // dock-probe glowdemo [high|drums|dense]: scripted drums through the music light, rendered as
    // the app renders it and heard at the same time (synthesised kick, snare and hi-hat, from the
    // one script the light plays), each part announced aloud. high: hi-hats on their own
    // (glints), then with kick and snare (the glints stop, the drums take over), then on their
    // own again. drums: the standard kick, snare and hi-hat each on its own, then all three
    // together. dense: chimes on their own (tinkling, 7–12 kHz), 4 a second up to 16. mixed:
    // chimes 12 a second throughout — alone, over held chords (a plain mid sound, neither bass nor
    // a beat: the glints go on), with kick and snare added (they stop), over the chords again.
    // dense and mixed are heard as the app hears music: the sound goes through FeatureExtractor
    // and RhythmAnalyzer, nothing scripted reaches the light.
    // Quit the app first; it holds the device.
    guard let identity = M18Device.attached().first else { print("no M18 attached"); break }
    let gain = Double(DockSettings(defaults: UserDefaults(suiteName: "dev.yif.StreamDock") ?? .standard).ledBrightness) / 100
    let leds = Int(M18Layout.ledCount)
    let device = try M18Device(opening: identity) { _ in }
    device.setLEDBrightness(100)
    var output = LEDOutput()
    let grid = FrameGrid(framesPerSecond: LightLayout.framesPerSecond)
    let driver = MusicGlowDriver(palette: [Swatch(RGB(hex: "#2F6BFF"), share: 0.55), Swatch(RGB(hex: "#FF8A2A"), share: 0.3), Swatch(RGB(hex: "#F2F2F2"), share: 0.15)])
    // The script, at 120 BPM: a kick every beat, a snare on 2 and 4, hi-hats `hats` a second
    // (accented every other) — in the parts that have them.
    let mode = arguments.dropFirst().first ?? "high"
    var parts: [(say: String, seconds: Double, kick: Bool, snare: Bool, hats: Double, pad: Bool)] = []
    let plain: [(say: String, seconds: Double, kick: Bool, snare: Bool, hats: Double)] = switch mode {
    case "drums": [("底鼓", 8, true, false, 0), ("军鼓", 8, false, true, 0), ("高频踩镲", 8, false, false, 4),
                   ("三个一起：闪点停下", 10, true, true, 4)]
    case "dense": [("风铃，每秒四下", 7, false, false, 4), ("每秒八下", 7, false, false, 8),
                   ("每秒十二下", 7, false, false, 12), ("每秒十六下", 7, false, false, 16)]
    case "mixed": []
    default: [("只有高频：踩镲", 10, false, false, 4), ("加上底鼓和军鼓：闪点停下", 10, true, true, 4), ("又只剩高频", 8, false, false, 4)]
    }
    parts = mode == "mixed"
        ? [("风铃", 7, false, false, 12, false), ("加上和弦：闪点继续", 8, false, false, 12, true),
           ("再加底鼓和军鼓：闪点停下", 8, true, true, 12, true), ("回到风铃和和弦", 8, false, false, 12, true)]
        : plain.map { ($0.say, $0.seconds, $0.kick, $0.snare, $0.hats, false) }
    let listens = mode == "dense" || mode == "mixed"
    let chimes = listens
    var script: [DrumHit] = [], partStarts: [Double] = []
    var start = 0.0
    for part in parts {
        partStarts.append(start)
        for step in 0..<Int(part.seconds / 0.25) {
            let t = start + Double(step) * 0.25
            if part.kick, step % 2 == 0 { script.append(DrumHit(time: t, kind: .kick)) }
            if part.snare, step % 4 == 2 { script.append(DrumHit(time: t, kind: .snare)) }
            // Held chords, C–Am–F–G, a new one every 2 s.
            if part.pad, step % 8 == 0 { script.append(DrumHit(time: t, kind: .pad(pitches: DrumHit.chords[step / 8 % 4]))) }
        }
        if part.hats > 0 {
            for step in 0..<Int(part.seconds * part.hats) {
                let time = start + Double(step) / part.hats
                // dense and mixed ring chimes, a random note each, for the tinkling; the others play hi-hats.
                script.append(DrumHit(time: time, kind: chimes ? .chime(pitch: DrumHit.chimeNotes.randomElement()!) : .hat(accent: step % 2 == 0)))
            }
        }
        // A beat of silence after each part, so the next announcement is heard on its own.
        start += part.seconds + 1
    }
    script.sort { $0.time < $1.time }
    let player = try DrumPlayer(script: script, duration: start + 1)
    // Listening: the app's own analysis, fed the synthesised sound as it plays.
    let extractor = FeatureExtractor(sampleRate: DrumPlayer.sampleRate)
    extractor.computesDetail = false
    let analyzer = RhythmAnalyzer(frameRate: extractor.frameRate)
    analyzer.reportsBeats = false
    var fed = 0, heard = Array(repeating: 0, count: parts.count), open = Array(repeating: 0, count: parts.count)
    var lastLowMid = -Double.infinity
    player.play()
    let clock = Date()
    var pending = script[...], lastKick = -10.0, spoken = 0
    while Date().timeIntervalSince(clock) < start {
        let t = Date().timeIntervalSince(clock)
        if spoken < parts.count, t >= partStarts[spoken] {
            print(parts[spoken].say)
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: [parts[spoken].say])
            spoken += 1
        }
        var events: [RhythmEvent] = []
        var snapshot = RhythmSnapshot()
        if listens {
            let upTo = min(player.samples.count, Int(t * DrumPlayer.sampleRate))
            if upTo > fed {
                let frames = player.samples[fed..<upTo].withUnsafeBufferPointer { extractor.process($0, endTime: t) }
                fed = upTo
                for frame in frames { events += analyzer.process(frame) }
            }
            // High hits the light would let glint (MusicGlow eases the draw; this takes it as heard).
            for event in events {
                switch event {
                case .lift(let time, .high, _, _):
                    heard[max(0, spoken - 1)] += 1
                    if time - lastLowMid >= 0.6, analyzer.snapshot.lowDraw < 0.15 { open[max(0, spoken - 1)] += 1 }
                case .kick(let time, _), .lift(let time, .mid, _, true): lastLowMid = time
                default: break
                }
            }
            snapshot.intensity = analyzer.snapshot.intensity
            snapshot.loudness = analyzer.snapshot.loudness
            snapshot.lowDraw = analyzer.snapshot.lowDraw
        } else {
            while let hit = pending.first, hit.time <= t {
                pending = pending.dropFirst()
                switch hit.kind {
                case .chime: events.append(.lift(time: t, band: .high, strength: 0.8, heavy: false))
                case .hat(let accent): events.append(.lift(time: t, band: .high, strength: accent ? 1 : 0.55, heavy: false))
                case .kick:
                    events += [.hit(Hit(time: t, band: .low, strength: 8)), .kick(time: t, strength: 1)]
                    lastKick = t
                case .snare: events.append(.lift(time: t, band: .mid, strength: 1, heavy: true))
                case .bass, .pad: break
                }
            }
            let part = parts[max(0, spoken - 1)]
            snapshot.intensity = 0.85
            snapshot.loudness = Bands(low: part.kick ? 0.7 : 0.3, mid: part.snare ? 0.6 : 0.4, high: part.hats > 0 ? 0.6 : 0.3)
            snapshot.lowDraw = exp(-(t - lastKick) / 0.2)
        }
        let frame = driver.frame(at: t, ledCount: leds, events: events, snapshot: snapshot)
        device.setLEDFrame(output.render(frame, gain: gain).map { ($0.red, $0.green, $0.blue) })
        Thread.sleep(forTimeInterval: ProbeClock.seconds(until: grid.next()))
    }
    player.stop()
    if listens {
        for index in parts.indices {
            print(String(format: "%@: played %d, heard %d, free to glint %d", parts[index].say, Int(parts[index].seconds * parts[index].hats), heard[index], open[index]))
        }
    }
    device.setLEDFrame(Array(repeating: (0, 0, 0), count: leds))
    device.waitUntilIdle()
    device.close(notifyDevice: true)
case "bandshare":
    // dock-probe bandshare: synthesised scenes through the analysis offline — for each, how much
    // of the mix's energy each band holds, and how the low and mid hits rise against what their
    // band holds (raw rise per bin ÷ the band's level per bin over the last 0.5 s).
    let chords = DrumHit.chords
    func scene(_ name: String, chimes: Bool = false, pad: Bool = false, kick: Bool = false, snare: Bool = false, bass: Bool = false) -> (String, [DrumHit]) {
        var script: [DrumHit] = []
        for step in 0..<40 {   // 10 s of eighths at 120 BPM
            let t = Double(step) * 0.25
            if kick, step % 2 == 0 { script.append(DrumHit(time: t, kind: .kick)) }
            if snare, step % 4 == 2 { script.append(DrumHit(time: t, kind: .snare)) }
            if bass, step % 2 == 0 { script.append(DrumHit(time: t, kind: .bass(pitch: [55, 55, 65.4, 73.4][step / 2 % 4]))) }
            if pad, step % 8 == 0 { script.append(DrumHit(time: t, kind: .pad(pitches: chords[step / 8 % 4]))) }
        }
        if chimes { script += (0..<120).map { DrumHit(time: Double($0) / 12, kind: .chime(pitch: DrumHit.chimeNotes.randomElement()!)) } }
        return (name, script.sorted { $0.time < $1.time })
    }
    let scenes = [scene("chimes", chimes: true), scene("pad", pad: true), scene("chimes+pad", chimes: true, pad: true),
                  scene("kick", kick: true), scene("snare", snare: true), scene("bass", bass: true),
                  scene("kick+snare+bass+pad", pad: true, kick: true, snare: true, bass: true),
                  scene("all+chimes", chimes: true, pad: true, kick: true, snare: true, bass: true),
                  scene("kick+snare+pad+chimes", chimes: true, pad: true, kick: true, snare: true),
                  scene("kick+snare", kick: true, snare: true)]
    func median(_ values: [Double]) -> Double { values.isEmpty ? .nan : values.sorted()[values.count / 2] }
    for (name, script) in scenes {
        let samples = try DrumPlayer(script: script, duration: 10.5).samples
        let extractor = FeatureExtractor(sampleRate: DrumPlayer.sampleRate)
        extractor.computesDetail = false
        let bins = extractor.binCounts
        var total = Bands(), recent: [Bands] = []
        var rises: [Bands.Band: [Double]] = [.low: [], .mid: []], shares: [Double] = []
        var at = 0
        while at + 512 <= samples.count {
            for frame in samples[at..<at + 512].withUnsafeBufferPointer({ extractor.process($0, endTime: Double(at + 512) / DrumPlayer.sampleRate) }) {
                recent.append(frame.energy)
                if recent.count > 47 { recent.removeFirst() }
                if frame.time > 2 {
                    for band in Bands.Band.allCases { total[band] += frame.energy[band] }
                    let sum = frame.energy.low + frame.energy.mid + frame.energy.high
                    if sum > 0 { shares.append(frame.energy.low / sum) }
                }
            }
            at += 512
        }
        // Hits, as the analyzer picks them.
        let extractor2 = FeatureExtractor(sampleRate: DrumPlayer.sampleRate)
        extractor2.computesDetail = false
        let analyzer = RhythmAnalyzer(frameRate: extractor2.frameRate)
        analyzer.reportsBeats = false
        var history: [Bands] = []
        var lifts: [(time: Double, heavy: Bool, strength: Double)] = [], kicks = 0, midHits: [Double] = []
        at = 0
        while at + 512 <= samples.count {
            for frame in samples[at..<at + 512].withUnsafeBufferPointer({ extractor2.process($0, endTime: Double(at + 512) / DrumPlayer.sampleRate) }) {
                history.append(frame.energy)
                if history.count > 47 { history.removeFirst() }
                for event in analyzer.process(frame) where event.time > 2 {
                    switch event {
                    case .hit(let hit) where hit.band != .high:
                        let level = sqrt(history.reduce(0) { $0 + $1[hit.band] } / Double(history.count) / bins[hit.band])
                        rises[hit.band]!.append(hit.magnitude / max(level, 1e-12))
                        if hit.band == .mid { midHits.append(hit.time) }
                    case .lift(let time, .mid, let strength, let heavy): lifts.append((time, heavy, strength))
                    case .kick: kicks += 1
                    default: break
                    }
                }
            }
            at += 512
        }
        let sum = total.low + total.mid + total.high
        print(String(format: "%-20@ share low %.2e mid %.2e high %.2e | low hits %2d rise median %.3f | mid hits %2d rise median %.3f",
                     name as NSString, total.low / sum, total.mid / sum, total.high / sum,
                     rises[.low]!.count, median(rises[.low]!), rises[.mid]!.count, median(rises[.mid]!)))
        if name.contains("snare") {
            print("    kicks \(kicks); mid lifts:", lifts.map { String(format: "%.2f%@ %.2f", $0.time, $0.heavy ? "H" : "", $0.strength) }.joined(separator: "  "))
        }
    }
case "bandstats":
    // dock-probe bandstats <trace>…: per band, its share of the mix and its hits' sizes against
    // itself and against the mix (10th / 25th / 50th / 75th / 90th percentiles).
    for path in arguments.dropFirst() {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), let trace = RhythmTrace(text: text) else { continue }
        print(URL(fileURLWithPath: path).lastPathComponent)
        print(BandStats.report(trace))
    }
case "midorigin":
    // dock-probe midorigin <trace>…: which parts of the mid band each mid lift came from, and
    // whether a low hit came with it (traces with detail bands).
    for path in arguments.dropFirst() {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), let trace = RhythmTrace(text: text) else { continue }
        print(URL(fileURLWithPath: path).lastPathComponent)
        print(BandStats.midOrigins(trace))
    }
case "eventdump":
    // dock-probe eventdump <trace>: every event the live analysis makes from a recorded song,
    // one per line, and the draw every 0.1 s — to compare two versions of the analysis
    // (scripts diff two dumps): "K t strength" kick, "M t strength heavy" mid lift, "H t strength"
    // high lift, "L t" low hit, "D t draw intensity".
    guard let path = arguments.dropFirst().first, let text = try? String(contentsOfFile: path, encoding: .utf8),
          let trace = RhythmTrace(text: text) else { print("usage: dock-probe eventdump <trace>"); break }
    let analyzer = RhythmAnalyzer(frameRate: trace.frameRate)
    analyzer.reportsBeats = false
    let start = trace.frames.first?.time ?? 0
    var nextDraw = 0.0
    for frame in trace.frames {
        for event in analyzer.process(frame) {
            switch event {
            case .kick(let time, let strength): print(String(format: "K %.3f %.3f", time - start, strength))
            case .lift(let time, .mid, let strength, let heavy): print(String(format: "M %.3f %.3f %d", time - start, strength, heavy ? 1 : 0))
            case .lift(let time, _, let strength, _): print(String(format: "H %.3f %.3f", time - start, strength))
            case .hit(let hit) where hit.band == .low: print(String(format: "L %.3f", hit.time - start))
            default: break
            }
        }
        if frame.time - start >= nextDraw {
            print(String(format: "D %.2f %.3f %.3f", frame.time - start, analyzer.snapshot.lowDraw, analyzer.snapshot.intensity))
            nextDraw += 0.1
        }
    }
case "sharecompare":
    // dock-probe sharecompare <trace>: a recorded song through the analysis twice — as recorded,
    // and with the band energies left out (the rules before BandShares) — to see what the
    // shares change on real music: low hits and kicks, mid lifts and heavy ones, the draw.
    guard let path = arguments.dropFirst().first, let text = try? String(contentsOfFile: path, encoding: .utf8),
          let trace = RhythmTrace(text: text) else { print("usage: dock-probe sharecompare <trace>"); break }
    var kickTimes: [[Double]] = [[], []]
    for withShares in [false, true] {
        let analyzer = RhythmAnalyzer(frameRate: trace.frameRate)
        analyzer.reportsBeats = false
        var low = 0, kicks = 0, mids = 0, heavy = 0, highs = 0, draw = 0.0, frames = 0, bigMids = 0
        for var frame in trace.frames {
            if !withShares { frame.energy = Bands() }
            for event in analyzer.process(frame) {
                switch event {
                case .hit(let hit) where hit.band == .low: low += 1
                case .kick(let time, _): kicks += 1; kickTimes[withShares ? 1 : 0].append(time)
                case .lift(_, .mid, let strength, let isHeavy):
                    mids += 1
                    if isHeavy { heavy += 1 }
                    if strength >= 0.7 { bigMids += 1 }
                case .lift(_, .high, _, _): highs += 1
                default: break
                }
            }
            draw += analyzer.snapshot.lowDraw
            frames += 1
        }
        print(String(format: "%@: low hits %d, kicks %d | mid lifts %d, heavy %d, ≥0.7 of big hits %d | high %d | draw mean %.2f",
                     withShares ? "with shares   " : "without shares", low, kicks, mids, heavy, bigMids, highs, draw / Double(max(1, frames))))
    }
    // Kicks only one of the two finds, with the low band's share and the hit's rise against it.
    let start = trace.frames.first?.time ?? 0
    var shares = BandShares(frameRate: trace.frameRate)
    var lost: [String] = [], gained: [String] = []
    for frame in trace.frames {
        shares.push(frame.energy)
        for (index, times) in kickTimes.enumerated() {
            for time in times where abs(time - frame.time) < 1e-6 && !kickTimes[1 - index].contains(where: { abs($0 - time) < 0.05 }) {
                let entry = String(format: "%.2f s (low share %.2f)", time - start, shares.share(.low))
                if index == 0 { lost.append(entry) } else { gained.append(entry) }
            }
        }
    }
    print("kicks lost:", lost.joined(separator: ", "))
    print("kicks gained:", gained.joined(separator: ", "))
case "chimelisten":
    // dock-probe chimelisten: synthesised chimes on their own, 4 to 16 a second, through the
    // app's analysis offline (nothing played): per part, the hits each band hears and how many
    // high hits would glint (no kick or heavy mid in the last 0.6 s, the low end not drawing).
    let rates = [4.0, 8, 12, 16]
    var script: [DrumHit] = []
    for (index, rate) in rates.enumerated() {
        for step in 0..<Int(7 * rate) { script.append(DrumHit(time: Double(index) * 8 + Double(step) / rate, kind: .chime(pitch: DrumHit.chimeNotes.randomElement()!))) }
    }
    // chimelisten pad: over held chords (C–Am–F–G, a new one every 2 s, swelling in).
    if arguments.dropFirst().first == "pad" {
        script += stride(from: 0.0, to: 32, by: 2).enumerated().map { DrumHit(time: $1, kind: .pad(pitches: DrumHit.chords[$0 % 4])) }
    }
    let samples = try DrumPlayer(script: script, duration: 33).samples
    let extractor = FeatureExtractor(sampleRate: DrumPlayer.sampleRate)
    extractor.computesDetail = false
    let analyzer = RhythmAnalyzer(frameRate: extractor.frameRate)
    analyzer.reportsBeats = false
    var counts = Array(repeating: (high: 0, mid: 0, heavy: 0, low: 0, kicks: 0, glints: 0), count: rates.count)
    var lastLowMid = -Double.infinity
    var draws = Array(repeating: [Double](), count: rates.count)
    var at = 0
    while at + 512 <= samples.count {
        let frames = samples[at..<at + 512].withUnsafeBufferPointer { extractor.process($0, endTime: Double(at + 512) / DrumPlayer.sampleRate) }
        at += 512
        for frame in frames {
            for event in analyzer.process(frame) {
                let part = min(rates.count - 1, Int(event.time / 8))
                switch event {
                case .lift(let time, .high, _, _):
                    counts[part].high += 1
                    // As MusicGlow lets a glint through (draw left out: the light's own easing of it).
                    if time - lastLowMid >= 0.6, analyzer.snapshot.lowDraw < 0.15 { counts[part].glints += 1 }
                    draws[part].append(analyzer.snapshot.lowDraw)
                case .lift(let time, .mid, _, let heavy):
                    counts[part].mid += 1
                    if heavy { counts[part].heavy += 1; lastLowMid = time }
                case .hit(let hit) where hit.band == .low: counts[part].low += 1
                case .kick(let time, _): counts[part].kicks += 1; lastLowMid = time
                default: break
                }
            }
        }
    }
    for ((rate, c), draw) in zip(zip(rates, counts), draws) { print(String(format: "%2.0f/s played %3d: high %3d → glints %3d; mid %3d (heavy %d), low %d (kicks %d); draw at high hits mean %.2f", rate, Int(7 * rate), c.high, c.glints, c.mid, c.heavy, c.low, c.kicks, draw.reduce(0, +) / Double(max(1, draw.count)))) }
case "satsteps":
    // dock-probe satsteps [red|green|blue|#RRGGBB] [percent…]: the whole strip in one hue at
    // falling saturation (or the percentages given), each step announced aloud and held 5 s, rendered as the app renders it.
    // Saturation as the music light measures it on the LEDs: (highest − lowest) / highest
    // channel — 100 % is the hue with no white in it, lower steps add white. Quit the app first;
    // it holds the device.
    guard let identity = M18Device.attached().first else { print("no M18 attached"); break }
    let gain = Double(DockSettings(defaults: UserDefaults(suiteName: "dev.yif.StreamDock") ?? .standard).ledBrightness) / 100
    let leds = Int(M18Layout.ledCount)
    let device = try M18Device(opening: identity) { _ in }
    device.setLEDBrightness(100)
    var output = LEDOutput()
    let grid = FrameGrid(framesPerSecond: LightLayout.framesPerSecond)
    let name = arguments.dropFirst().first ?? "red"
    let hue: RGB = switch name {
    case "green": RGB(0, 255, 0)
    case "blue": RGB(0, 0, 255)
    case "red": RGB(255, 0, 0)
    default: RGB(hex: name)
    }
    let pure = LightPixel(hue).channels
    let low = min(pure.0, pure.1, pure.2), high = max(pure.0, pure.1, pure.2)
    let vivid = ((pure.0 - low) / (high - low), (pure.1 - low) / (high - low), (pure.2 - low) / (high - low))
    let picked = arguments.dropFirst(2).compactMap { Int($0) }
    for percent in picked.isEmpty ? [100, 90, 80, 70, 60, 50, 40] : picked {
        let s = Double(percent) / 100
        // White added until the lowest channel is (1 − s) of the highest.
        let channels = (1 - s + s * vivid.0, 1 - s + s * vivid.1, 1 - s + s * vivid.2)
        let say = "饱和度百分之\(percent)"
        print(say)
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: [say])
        let until = Date().addingTimeInterval(5)
        while Date() < until {
            let frame = Array(repeating: LightPixel(channels: channels, level: 0.7), count: leds)
            device.setLEDFrame(output.render(frame, gain: gain).map { ($0.red, $0.green, $0.blue) })
            Thread.sleep(forTimeInterval: ProbeClock.seconds(until: grid.next()))
        }
    }
    device.setLEDFrame(Array(repeating: (0, 0, 0), count: leds))
    device.waitUntilIdle()
    device.close(notifyDevice: true)
case "ledbench":
    // dock-probe ledbench [seconds]: light-strip frames at 60 Hz on the frame grid, timed: how
    // many the transport dropped, and how late each send went out.
    guard let identity = M18Device.attached().first else { print("no M18 attached"); break }
    let seconds = arguments.dropFirst().first.flatMap(Double.init) ?? 5
    let device = try M18Device(opening: identity) { _ in }
    let grid = FrameGrid(framesPerSecond: LightLayout.framesPerSecond)
    var late: [Double] = []
    let start = Date()
    var frame = 0
    while Date().timeIntervalSince(start) < seconds {
        let due = grid.next()
        Thread.sleep(forTimeInterval: ProbeClock.seconds(until: due))
        late.append(millisecondsPast(due))
        let level: UInt8 = frame % 60 < 30 ? 80 : 20
        device.setLEDFrame(Array(repeating: (level, 0, 0), count: Int(M18Layout.ledCount)))
        frame += 1
    }
    device.waitUntilIdle()
    late.sort()
    print(String(format: "%d frames in %.1f s, dropped %d; send lateness median %.1f ms, p99 %.1f ms, max %.1f ms",
                 frame, seconds, device.droppedLEDFrames, late[late.count / 2], late[late.count * 99 / 100], late.last ?? 0))
    device.close(notifyDevice: true)
case "ledwalk":
    // dock-probe ledwalk [rate…]: measures the light strip's refresh with a camera, not by eye.
    // One white LED walks the ring, one LED per frame sent, so every frame the strip shows is a
    // distinct position and every frame it skips is a missing position. Timeline (`LEDWalk`):
    // all-white marker, a slow calibration lap that locates each LED in the video, then for each
    // rate (default 30 60 120 240) a marker and 4 s of walking. Each send waits for its USB write,
    // so the host side is measured too. Film at 240 fps; read the video with `ledscan`.
    guard let identity = M18Device.attached().first else { print("no M18 attached"); break }
    let rates = arguments.dropFirst().compactMap(Double.init).filter { $0 > 0 }
    let device = try M18Device(opening: identity) { _ in }
    device.setLEDBrightness(100)
    LEDWalk.play(on: device, rates: rates.isEmpty ? LEDWalk.defaultRates : rates)
    device.close(notifyDevice: true)
case "ledscan":
    // dock-probe ledscan <video> [rate…]: reads a 240 fps video of `ledwalk` (same rates).
    // `ledscan --simulate <strip Hz> [rate…]` reads a made-up video of a strip with that refresh instead.
    guard let path = arguments.dropFirst().first else { print("usage: dock-probe ledscan <video> [rate…]"); break }
    if path == "--simulate", let strip = arguments.dropFirst(2).first.flatMap(Double.init) {
        let rates = arguments.dropFirst(3).compactMap(Double.init).filter { $0 > 0 }
        print("simulated strip refreshing at \(strip) Hz")
        try LEDScan.analyse(LEDScan.simulate(stripRate: strip, rates: rates.isEmpty ? LEDWalk.defaultRates : rates), rates: rates.isEmpty ? LEDWalk.defaultRates : rates)
        break
    }
    let rates = arguments.dropFirst(2).compactMap(Double.init).filter { $0 > 0 }
    try LEDScan.run(video: URL(fileURLWithPath: path), rates: rates.isEmpty ? LEDWalk.defaultRates : rates)
case "hookpreview":
    // dock-probe hookpreview: what Settings → 加载 would write into each app's config, computed
    // from the files as they are now. Writes nothing.
    for service in AIService.allCases {
        let url = AgentHooks.configFile(for: service)
        print("== \(url.path)\(FileManager.default.fileExists(atPath: url.path) ? "" : "（新建）")")
        print(try AgentHooks.preview(service))
    }
case "keytest":
    // Pixel test patterns on the top row, to see whether the firmware shows 64×64 key images
    // 1:1 or scales them: 1-px stripes stay crisp only at 1:1.
    guard let identity = M18Device.attached().first else {
        print("no M18 attached")
        break
    }
    let seconds = arguments.dropFirst().first.flatMap(Double.init) ?? 600
    let side = M18Layout.keyImageSize
    func pattern(_ white: (Int, Int) -> Bool) -> Data {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side { for x in 0..<side where white(x, y) {
            let i = (y * side + x) * 4
            pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 255
        } }
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
    let last = side - 1
    let patterns: [Int: Data] = [
        1: pattern { x, _ in x % 2 == 0 },                       // 1-px vertical stripes
        2: pattern { _, y in y % 2 == 0 },                       // 1-px horizontal stripes
        3: pattern { x, y in (x + y) % 2 == 0 },                 // 1-px checkerboard
        4: pattern { x, _ in x / 2 % 2 == 0 },                   // 2-px vertical stripes
        5: pattern { x, y in x == 0 || y == 0 || x == last || y == last || x == side / 2 || y == side / 2 }, // edge frame + cross
    ]
    let device = try M18Device(opening: identity) { _ in }
    device.setScreenBrightness(80)
    device.clearKeys(Array(1...15))
    device.setKeyImages(patterns)
    print("showing pixel test on the top row for \(Int(seconds)) s")
    Thread.sleep(forTimeInterval: seconds)
    device.close(notifyDevice: true)
case "ledset":
    // Sets one light-strip pattern and leaves it on, for step-by-step checks by eye.
    guard let identity = M18Device.attached().first else {
        print("no M18 attached")
        break
    }
    let count = Int(M18Layout.ledCount)
    let segments: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]
    let pattern = arguments.dropFirst().first ?? ""
    let device = try M18Device(opening: identity) { _ in }
    var lastFrame: [(UInt8, UInt8, UInt8)] = []
    func show(_ frame: [(UInt8, UInt8, UInt8)]) {
        lastFrame = frame
        device.setLEDColors(frame)
    }
    device.setLEDBrightness(100)
    switch pattern {
    case "green": device.setLEDColor(red: 0, green: 255, blue: 0)
    case "quarters": show((0..<count).map { segments[$0 * segments.count / count] })
    case "half": show((0..<count).map { $0 < count / 2 ? (255, 0, 0) : (0, 0, 255) })
    case "off": device.setLEDColor(red: 0, green: 0, blue: 0)
    default:
        if let index = Int(pattern), (0..<count).contains(index) {
            show((0..<count).map { $0 == index ? (255, 255, 255) : (0, 0, 0) })
        } else {
            print("patterns: green | quarters | half | off | <LED index 0-\(count - 1)>")
        }
    }
    if CommandLine.arguments.contains("--twice") {
        // Per-LED frames only show when the next per-LED frame arrives; repeat to show it now.
        device.setLEDColors(lastFrame)
    }
    device.waitUntilIdle()
    // Keep the connection open while the pattern is being looked at; stop with Ctrl+C / kill.
    let holdSeconds = arguments.dropFirst(2).first.flatMap(Double.init) ?? 600
    print("set \(pattern), holding \(Int(holdSeconds))s")
    let until = Date().addingTimeInterval(holdSeconds)
    var lastPath = identity.path
    while Date() < until {
        Thread.sleep(forTimeInterval: 1)
        let path = M18Device.attached().first?.path ?? "GONE"
        if path != lastPath {
            print("device changed: \(lastPath) -> \(path)")
            lastPath = path
        }
    }
    device.close(notifyDevice: false)
case "canwrite":
    guard let identity = M18Device.attached().first else { print("no M18 attached"); break }
    let device = try M18Device(opening: identity) { _ in }
    print("idle: can_write =", device.canWrite().map(String.init) ?? "call failed")
    device.setLEDColor(red: 0, green: 0, blue: 80)
    print("right after a command: can_write =", device.canWrite().map(String.init) ?? "call failed")
    device.waitUntilIdle()
    Thread.sleep(forTimeInterval: 0.5)
    print("0.5s later: can_write =", device.canWrite().map(String.init) ?? "call failed")
    device.close(notifyDevice: false)
case "palette":
    let path = arguments.dropFirst().first ?? ""
    guard let data = FileManager.default.contents(atPath: path) else { print("cannot read \(path)"); break }
    print(ArtworkPalette.colors(from: data).map { "\($0.color.hex) \(Int(($0.share * 100).rounded()))%" }.joined(separator: " "))
case "glowsim":
    // dock-probe glowsim <rhythm trace> <out> <#RRGGBB ...>: the light show for a recorded trace.
    let input = arguments.dropFirst().first ?? ""
    let output = arguments.dropFirst(2).first ?? ""
    let colors = arguments.dropFirst(3).map { RGB(hex: $0) }
    let palette = colors.map { Swatch($0, share: 1 / Double(colors.count)) }
    guard let text = try? String(contentsOfFile: input, encoding: .utf8), let trace = RhythmTrace(text: text), !palette.isEmpty else {
        print("usage: dock-probe glowsim <rhythm trace> <out> <#RRGGBB ...>")
        break
    }
    let lines = GlowReplay.replay(trace: trace, palette: palette)
    try lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
    print("wrote \(lines.count) frames to \(output)")
case "bandcompare":
    // dock-probe bandcompare <rhythm trace>: the current split of the spectrum against the
    // proposed one (see `BandComparison`) on a trace recorded with detail bands.
    guard let text = try? String(contentsOfFile: arguments.dropFirst().first ?? "", encoding: .utf8),
          let trace = RhythmTrace(text: text), let result = BandComparison.run(trace) else {
        print("usage: dock-probe bandcompare <rhythm trace with detail bands>")
        break
    }
    // Song time: the note says how far into the track it was at some uptime.
    var offset = 0.0
    if let note = trace.notes.first, let range = note.range(of: #"at uptime ([0-9.]+) the track was ([0-9.\-]+) s in"#, options: .regularExpression) {
        let numbers = note[range].split(separator: " ").compactMap { Double($0) }
        if numbers.count == 2, numbers[1] >= 0 { offset = numbers[1] - numbers[0] }
        print("note: \(note)")
    }
    func song(_ t: Double) -> String { let s = t + offset; return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60)) }
    let minutes = (result.end - result.start) / 60
    let tempo = result.bpm.map { BandComparison.refined($0, by: result.current.kick.times) }
    print(String(format: "%.0f s recorded (%@ – %@), tempo %@ (analyzer %@)", result.end - result.start, song(result.start), song(result.end),
                 tempo.map { String(format: "%.2f BPM", $0) } ?? "not locked", result.bpm.map { String(format: "%.1f", $0) } ?? "-"))
    for (label, set) in [("current", result.current), ("proposed", result.proposed)] {
        print("\n== \(label)")
        for stream in [set.kick, set.snare, set.cymbal] {
            print(String(format: "  %-28@ %4d  (%.0f/min)", stream.name as NSString, stream.times.count, Double(stream.times.count) / minutes))
        }
        let snare = set.snare.times
        print(String(format: "  snares landing with a kick (±40 ms): %.0f%%", BandComparison.matched(snare, in: result.proposed.kick.times, window: 0.04) * 100))
        if let bpm = tempo {
            print(String(format: "  snare gaps of 2 beats: %.0f%%, of 1 beat: %.0f%%", BandComparison.regular(snare, bpm: bpm, beats: 2) * 100, BandComparison.regular(snare, bpm: bpm, beats: 1) * 100))
            for stream in [set.kick, set.snare, set.cymbal] {
                let two = BandComparison.locking(stream.times, bpm: bpm, beats: 2), one = BandComparison.locking(stream.times, bpm: bpm, beats: 1)
                print(String(format: "  %-28@ locking to 2 beats %.2f, to 1 beat %.2f", stream.name as NSString, two.strength, one.strength))
                // Where in a two-beat cycle they fall: 16 slots (eighth-of-a-beat), counts as bars.
                let period = 120 / bpm
                var slots = [Int](repeating: 0, count: 16)
                for t in stream.times { slots[Int((t / period - (t / period).rounded(.down)) * 16) % 16] += 1 }
                let top = max(1, slots.max()!)
                print("      " + slots.map { String(" ▁▂▃▄▅▆▇█"[String.Index(utf16Offset: $0 * 8 / top, in: " ▁▂▃▄▅▆▇█")]) }.joined() + "  (two beats, eighth-beat slots; peak \(top))")
            }
        }
    }
    let current = result.current.snare.times, proposed = result.proposed.snare.times
    print(String(format: "\nproposed snares also found by current: %.0f%%; current mid lifts that are proposed snares: %.0f%%",
                 BandComparison.matched(proposed, in: current) * 100, BandComparison.matched(current, in: proposed) * 100))
    print("\nper 10 s (song time): current mid lifts / proposed snares / proposed cymbals")
    var window = result.start
    while window < result.end {
        let inside = { (list: [Double]) in list.filter { $0 >= window && $0 < window + 10 }.count }
        print(String(format: "  %@  %3d / %3d / %3d", song(window), inside(current), inside(proposed), inside(result.proposed.cymbal.times)))
        window += 10
    }
case "rhythm-eval":
    // dock-probe rhythm-eval <rhythm trace>: replays the analyzer and scores it against the taps.
    guard let text = try? String(contentsOfFile: arguments.dropFirst().first ?? "", encoding: .utf8),
          let trace = RhythmTrace(text: text), let first = trace.frames.first?.time else {
        print("usage: dock-probe rhythm-eval <rhythm trace>")
        break
    }
    let result = trace.replay()
    if CommandLine.arguments.contains("--dump-hits") {
        for (_, event) in result.events {
            switch event {
            case .hit(let hit): print(String(format: "HIT %.4f %@ %.3f %.4f", hit.time, hit.band.rawValue, hit.strength, hit.magnitude))
            case .accent(let time, let strength): print(String(format: "ACC %.4f %.3f", time, strength))
            default: break
            }
        }
    }
    if CommandLine.arguments.contains("--dump-beats") {
        print("BEATS " + result.beats.map { String(format: "%.3f", $0) }.joined(separator: " "))
    }
    print(String(format: "%d frames (%.0f s), %d taps, %d accents, %d grid beats", trace.frames.count, (trace.frames.last?.time ?? first) - first, trace.taps.count, result.accents.count, result.beats.count))
    // Time spent per state, and the tempo over time.
    var spent: [RhythmState: Double] = [:]
    for (previous, current) in zip(result.snapshots, result.snapshots.dropFirst()) {
        spent[previous.1.state, default: 0] += current.0 - previous.0
    }
    print("states:", RhythmState.allCasesForReport.map { String(format: "%@ %.0fs", $0.rawValue, spent[$0] ?? 0) }.joined(separator: "  "))
    for checkpoint in stride(from: first + 10, to: trace.frames.last?.time ?? first, by: 10) {
        guard let snapshot = result.snapshots.last(where: { $0.0 <= checkpoint })?.1 else { continue }
        print(String(format: "  t=%5.0fs  %-7@ bpm=%-5@ confidence=%.2f activity=%.2f intensity=%.2f",
                     checkpoint - first, snapshot.state.rawValue, snapshot.bpm.map { String(format: "%.0f", $0) } ?? "-",
                     snapshot.confidence, snapshot.activity, snapshot.intensity))
    }
    if trace.taps.count >= 8 {
        // Taps mark the hits the listener feels strongest, so accents are the main score.
        for (name, times) in [("accents", result.accents), ("grid", result.beats)] {
            let evaluation = RhythmEvaluation(beats: times, taps: trace.taps)
            print(String(format: "%@ vs taps: F=%.2f (precision %.2f, recall %.2f)  tap offset %+.0f ms",
                         name, evaluation.fMeasure, evaluation.precision, evaluation.recall, evaluation.tapOffset * 1000))
        }
    } else {
        print("(fewer than 8 taps: no accuracy score)")
    }
case "ddc":
    guard let display = DDCDisplay.firstExternal() else {
        print("no external display with an AV service")
        break
    }
    for feature in [DDCDisplay.Feature.brightness, .volume, .audioMute] {
        if let value = display.read(feature) {
            print("\(feature): \(value.current) / \(value.max)")
        } else {
            print("\(feature): no answer")
        }
    }
case "cpa":
    // Read-only look at what CPA returns, to settle the field names before building on them.
    // Sends GETs only; never consumes reset credits or touches credentials.
    guard let base = arguments.dropFirst().first.flatMap(URL.init(string:)),
          let key = ProcessInfo.processInfo.environment["CPA_KEY"], !key.isEmpty else {
        print("usage: CPA_KEY=<management key> dock-probe cpa https://cpa.example")
        break
    }
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { try await probeCPA(base: base, key: key) } catch { print("failed:", error.localizedDescription) }
        done.signal()
    }
    done.wait()
case "digitdemo":
    try DigitDemo.run()
case "pressdemo":
    try PressDemo.run()
case "quotademo":
    try QuotaDemo.run()
case "holddemo":
    try HoldDemo.run(Array(arguments.dropFirst()))
case "keyease":
    try KeyEase.run(Array(arguments.dropFirst()))
case "keyglide":
    try KeyGlide.run(Array(arguments.dropFirst()))
case "keywindows":
    try KeyWindows.run(Array(arguments.dropFirst()))
case "preview":
    try preview(into: arguments.dropFirst().first ?? "build/preview")
case "run":
    let seconds = arguments.dropFirst().first.flatMap(Double.init) ?? 30
    let controller = DockController(scenes: [
        probeScene("A", RGB(255, 0, 0)),
        probeScene("B", RGB(0, 255, 0)),
        probeScene("C", RGB(0, 0, 255)),
    ], settings: DockSettings(defaults: UserDefaults(suiteName: "StreamDock.probe")!))
    controller.start()
    print("Running for \(Int(seconds))s — press keys")
    let deadline = Date().addingTimeInterval(seconds)
    var lastConnection: DockController.Connection?
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if controller.connection != lastConnection {
            lastConnection = controller.connection
            print("connection: \(controller.connection)")
        }
    }
    controller.shutdown()
    print("closed")
default:
    print("usage: dock-probe run [seconds] | preview <dir> | list | ddc | ledmap | ledset <pattern> | ledwalk [seconds] | glowsim | rhythm-eval")
}

/// Masks e-mail addresses so the probe output can be shared.
func maskEmails(_ text: String) -> String {
    text.replacingOccurrences(of: #"([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+)"#, with: "$1***@$2", options: .regularExpression)
}

func probeCPA(base: URL, key: String) async throws {
    func management(_ path: String, body: Any? = nil) async throws -> Any {
        var request = URLRequest(url: base.appendingPathComponent("v0/management/" + path))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw NSError(domain: "CPA", code: status, userInfo: [NSLocalizedDescriptionKey: "\(path): HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"]) }
        return try JSONSerialization.jsonObject(with: data)
    }
    func pretty(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "\(value)" }
        return maskEmails(String(decoding: data, as: UTF8.self))
    }
    let files = (try await management("auth-files") as? [String: Any])?["files"] as? [[String: Any]] ?? []
    print("== auth-files: \(files.count)")
    for file in files {
        let shown = ["name", "provider", "auth_index", "label", "status", "disabled", "unavailable", "account_type", "account", "email"]
        print(pretty(file.filter { shown.contains($0.key) }), "\n  other fields:", file.keys.filter { !shown.contains($0) }.sorted().joined(separator: ", "))
    }
    let calls: [(provider: String, url: String, header: [String: String])] = [
        ("claude", "https://api.anthropic.com/api/oauth/usage", ["anthropic-beta": "oauth-2025-04-20"]),
        ("codex", "https://chatgpt.com/backend-api/wham/usage", [:]),
        ("codex", "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", [:]),
    ]
    for file in files where file["disabled"] as? Bool != true {
        let provider = (file["provider"] as? String ?? "").lowercased()
        guard let index = file["auth_index"] else { continue }
        for call in calls where provider.contains(call.provider) {
            var header = call.header
            header["Authorization"] = "Bearer $TOKEN$"
            if call.provider == "codex", let account = file["account"] as? String, !account.isEmpty, !account.contains("@") {
                header["chatgpt-account-id"] = account
            }
            print(maskEmails("\n== \(file["name"] ?? "?") GET \(call.url)"))
            do {
                let reply = try await management("api-call", body: ["auth_index": index, "method": "GET", "url": call.url, "header": header]) as? [String: Any] ?? [:]
                print("status:", reply["status_code"] ?? "?")
                if let body = reply["body"] as? String, let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
                    print(pretty(json))
                } else { print(maskEmails("\(reply["body"] ?? "")").prefix(1500)) }
            } catch { print("failed:", error.localizedDescription) }
        }
    }
}

extension RhythmState {
    static let allCasesForReport: [RhythmState] = [.calm, .seeking, .locked]
}


/// One key in the preview sheet.
struct SheetKey {
    var symbol: String? = nil, value: String? = nil, label: String? = nil, tone: KeyTone = .normal, artwork: Bool = false
    /// A service's icon as artwork.
    var app: AIService? = nil
    var meter: KeyMeter? = nil
}

@MainActor func writeKeySheet(to path: String, artwork: Data?, pressed: Bool) throws {
    // What the modules show, in a typical state (HA labels are the user's own names).
    let daily: [SheetKey] = [
        .init(symbol: "speaker.wave.1.fill"), .init(value: "45", label: "Volume"), .init(symbol: "speaker.wave.3.fill"),
        .init(symbol: "hifispeaker", label: "LG Display"), .init(symbol: "mic", label: "DJI Mic"),
        .init(symbol: "sun.min.fill"), .init(value: "70", label: "Brightness"), .init(symbol: "sun.max.fill"),
        .init(symbol: "moon.fill", label: "Sleep"), .init(symbol: "mic.slash.fill", label: "Muted", tone: .alert),
        .init(symbol: "backward.fill"), .init(symbol: "pause.fill"), .init(symbol: "forward.fill"),
        .init(symbol: "music.note", artwork: true), .init(symbol: "star.fill", label: "Loved", tone: .on),
    ]
    let home: [SheetKey] = [
        .init(value: "26°", label: "A/C", tone: .on), .init(symbol: "minus", label: "A/C"), .init(symbol: "plus", label: "A/C"),
        .init(value: "Cool", label: "A/C"), .init(value: "86W", label: "PC", tone: .on),
        .init(value: "40%", label: "Fan", tone: .on), .init(symbol: "minus", label: "Fan"), .init(symbol: "plus", label: "Fan"),
        .init(symbol: "arrow.left.and.right", label: "Fan", tone: .on), .init(value: "Natural", label: "Fan"),
        .init(symbol: "power", label: "Light Bar"), .init(symbol: "sun.min.fill", label: "Light Bar", tone: .dim),
        .init(symbol: "sun.max.fill", label: "Light Bar", tone: .dim), .init(symbol: "flame.fill", label: "Light Bar", tone: .dim),
        .init(symbol: "snowflake", label: "Light Bar", tone: .dim),
    ]
    let obs: [SheetKey] = [
        .init(symbol: "record.circle", label: "Recording", tone: .alert), .init(symbol: "pause.fill", label: "Pause"),
        .init(symbol: "dot.radiowaves.left.and.right", label: "Live", tone: .live), .init(symbol: "rectangle.split.2x1", label: "Studio"),
        .init(symbol: "arrow.right.square", label: "Transition", tone: .dim),
        .init(value: "1", label: "Main", tone: .on), .init(value: "2", label: "Desktop"), .init(value: "3", label: "Camera"),
        .init(value: "4", label: "Unset", tone: .dim), .init(value: "5", label: "Unset", tone: .dim),
        .init(symbol: "mic.fill", label: "Mic"), .init(symbol: "mic.slash.fill", label: "Desktop", tone: .alert),
        .init(symbol: "eye.fill", label: "Camera", tone: .on), .init(symbol: "eye.slash", label: "Captions"),
        .init(symbol: "square.and.arrow.down", label: "Save"),
    ]
    // Readings from the CPA probe of 2026-10-25.
    func left(_ percent: Double, _ service: AIService) -> KeyMeter { KeyMeter(fraction: percent / 100, color: service.color) }
    let vibe: [SheetKey] = [
        .init(app: .codex), .init(value: "97%", label: "5h", meter: left(97, .codex)),
        .init(value: "81%", label: "Week", meter: left(81, .codex)), .init(value: "2", label: "Resets"), .init(value: "73k", label: "Credits"),
        .init(app: .claude), .init(value: "83%", label: "5h", meter: left(83, .claude)),
        .init(value: "93%", label: "Week", meter: left(93, .claude)), .init(value: "3h40", label: "5h Reset"), .init(value: "6d12h", label: "Week Reset"),
    ]
    func render(_ key: SheetKey) -> CGImage? {
        let art = key.app.flatMap(AIQuotaModule.icon(for:)) ?? (key.artwork ? artwork : nil)
        return KeyDesign.image(symbol: key.symbol, value: key.value, label: key.label, tone: key.tone,
                               artwork: art, meter: key.meter, press: pressed ? 1 : 0)
    }
    let panels: [(String, [CGImage?])] = [
        ("第 1 页 · 日常控制", daily.map(render)),
        ("第 2 页 · 智能家居", home.map(render)),
        ("第 3 页 · OBS", obs.map(render)),
        ("VibeCoding · 额度", vibe.map(render) + Array(repeating: nil, count: 5)),
    ]
    let zoom = 3, key = 64 * zoom, gap = 10 * zoom, margin = 40, titleHeight = 56
    let panelWidth = 5 * key + 4 * gap, panelHeight = titleHeight + 3 * key + 2 * gap
    let width = 2 * panelWidth + 3 * margin, height = 2 * panelHeight + 3 * margin
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.12, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .none
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    for (index, panel) in panels.enumerated() {
        let originX = margin + (index % 2) * (panelWidth + margin)
        let top = height - margin - (index / 2) * (panelHeight + margin)
        NSAttributedString(string: panel.0, attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor(white: 0.85, alpha: 1)])
            .draw(at: NSPoint(x: originX, y: top - 36))
        for (slot, image) in panel.1.enumerated() {
            let x = originX + (slot % 5) * (key + gap)
            let y = top - titleHeight - (slot / 5 + 1) * key - (slot / 5) * gap
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: x - 8, y: y - 8, width: key + 16, height: key + 16))
            if let image { context.draw(image, in: CGRect(x: x, y: y, width: key, height: key)) }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

/// Seconds from now until a grid slot, for the probe's synchronous loops.
enum ProbeClock {
    static func seconds(until instant: ContinuousClock.Instant) -> Double {
        let gap = (instant - ContinuousClock.now).components
        return max(0, Double(gap.seconds) + Double(gap.attoseconds) / 1e18)
    }
}

/// How far past `instant` now is, in ms (0 if not yet).
func millisecondsPast(_ instant: ContinuousClock.Instant) -> Double {
    let gap = (ContinuousClock.now - instant).components
    return max(0, Double(gap.seconds) + Double(gap.attoseconds) / 1e18) * 1000
}
