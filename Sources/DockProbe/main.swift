// Hardware smoke test for DockKit + DockCore, without the menu bar app.
//
//   dock-probe run [seconds]   three numbered test scenes; round keys switch, presses are logged
//   dock-probe preview <dir>   write sample key renders as PNGs
//   dock-probe list            list attached M18s
//   dock-probe ledmap          static light-strip patterns, held still for checking by eye
//   dock-probe rhythm-eval <trace>  replay a rhythm trace and score it against tapped beats
//   dock-probe ddc             read brightness / volume from the external monitor over DDC

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
            guard let image = KeyRenderer.image(for: face, pressed: pressed) else { continue }
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
    print(ArtworkPalette.colors(from: data).map(\.hex).joined(separator: " "))
case "glowsim":
    // dock-probe glowsim <rhythm trace> <out> <#RRGGBB ...>: the light show for a recorded trace.
    let input = arguments.dropFirst().first ?? ""
    let output = arguments.dropFirst(2).first ?? ""
    let palette = arguments.dropFirst(3).map { RGB(hex: $0) }
    guard let text = try? String(contentsOfFile: input, encoding: .utf8), let trace = RhythmTrace(text: text), !palette.isEmpty else {
        print("usage: dock-probe glowsim <rhythm trace> <out> <#RRGGBB ...>")
        break
    }
    let lines = GlowReplay.replay(trace: trace, palette: palette)
    try lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
    print("wrote \(lines.count) frames to \(output)")
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

extension RhythmState {
    static let allCasesForReport: [RhythmState] = [.calm, .seeking, .locked]
}


/// One key in the preview sheet.
struct SheetKey {
    var symbol: String? = nil, value: String? = nil, label: String? = nil, tone: KeyTone = .normal, artwork: Bool = false
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
    func render(_ key: SheetKey) -> CGImage? {
        KeyDesign.image(symbol: key.symbol, value: key.value, label: key.label, tone: key.tone,
                        artwork: key.artwork ? artwork : nil, pressed: pressed)
    }
    let panels: [(String, [CGImage?])] = [
        ("第 1 页 · 日常控制", daily.map(render)),
        ("第 2 页 · 智能家居", home.map(render)),
        ("第 3 页 · OBS", obs.map(render)),
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
