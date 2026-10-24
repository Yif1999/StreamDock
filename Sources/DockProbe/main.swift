// Hardware smoke test for DockKit + DockCore, without the menu bar app.
//
//   dock-probe run [seconds]   three numbered test scenes; round keys switch, presses are logged
//   dock-probe preview <dir>   write sample key renders as PNGs
//   dock-probe list            list attached M18s
//   dock-probe ddc             read brightness / volume from the external monitor over DDC

import AppKit
import ControlModules
import DockCore
import DockKit

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

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "list":
    for identity in M18Device.attached() {
        print(identity.path, identity.serialNumber, String(identity.productID, radix: 16))
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
    print("usage: dock-probe run [seconds] | preview <dir> | list | ddc")
}
