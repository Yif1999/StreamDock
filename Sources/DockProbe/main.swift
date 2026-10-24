// Hardware smoke test for DockKit + DockCore, without the menu bar app.
//
//   dock-probe run [seconds]   three numbered test scenes; round keys switch, presses are logged
//   dock-probe preview <dir>   write sample key renders as PNGs
//   dock-probe list            list attached M18s
//   dock-probe ledmap          static light-strip patterns, held still for checking by eye
//   dock-probe rhythm-eval <trace>  replay a rhythm trace and score it against tapped beats
//   dock-probe ddc             read brightness / volume from the external monitor over DDC

import AppKit
import ControlModules
import DockCore
import DockKit
import RhythmKit

final class ProbeModule: DockModule {
    let keyCount = 15
    private let sceneName: String
    private let background: RGB

    init(sceneName: String, background: RGB) {
        self.sceneName = sceneName
        self.background = background
    }

    func face(forSlot slot: Int) -> KeyFace {
        KeyFace(title: "\(slot + 1)", caption: slot == 0 ? sceneName : nil, background: background)
    }

    func keyDown(slot: Int) { print("[\(sceneName)] key \(slot + 1) down") }
    func keyUp(slot: Int) { print("[\(sceneName)] key \(slot + 1) up") }
    func sceneDidActivate() { print("scene -> \(sceneName)") }
}

@MainActor func probeScene(_ id: String, _ led: RGB, _ background: RGB) -> DockScene {
    let scene = DockScene(id: id, name: id, defaultLEDColor: led)
    scene.place(ProbeModule(sceneName: id, background: background), keys: Array(1...15))
    return scene
}

@MainActor func preview(into directory: String) throws {
    let faces: [(String, KeyFace)] = [
        ("number", KeyFace(title: "12")),
        ("symbol", KeyFace(symbol: "playpause.fill")),
        ("symbol-caption", KeyFace(symbol: "speaker.wave.2.fill", caption: "45%")),
        ("tinted", KeyFace(symbol: "sun.max.fill", caption: "亮度", foreground: RGB(hex: "#FFD60A"))),
        ("long-title", KeyFace(title: "VibeCoding")),
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
        probeScene("A", RGB(255, 0, 0), RGB(hex: "#5A1F1F")),
        probeScene("B", RGB(0, 255, 0), RGB(hex: "#1F5A2A")),
        probeScene("C", RGB(0, 0, 255), RGB(hex: "#1F2F5A")),
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
