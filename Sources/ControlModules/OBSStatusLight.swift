import DockCore
import Foundation

struct OBSOutputState: Equatable {
    var recording = false
    var paused = false
    var streaming = false
    var active: Bool { recording || streaming }
}

/// A quiet, persistent output indicator: red recording, green streaming, amber paused.
@MainActor
final class OBSStatusLight: LightAnimation {
    // Saturated LED colors: avoid the white component of UI-style pastel colors.
    static let recordingColor = RGB(hex: "#FF0000")
    static let streamingColor = RGB(hex: "#00FF00")
    static let pausedColor = RGB(hex: "#FF9C00")
    let state: OBSOutputState
    init(state: OBSOutputState) { self.state = state }

    var isActive: Bool { state.active }

    func pixels(at time: TimeInterval, ledCount: Int) -> [LightPixel] {
        colors(at: time, ledCount: ledCount).map(LightPixel.init)
    }

    func colors(at time: TimeInterval, ledCount: Int) -> [RGB] {
        let breath = 0.75 + 0.25 * sin(2 * .pi * time / 2)
        let recording = state.paused ? Self.pausedColor : Self.recordingColor.scaled(by: breath)
        let streaming = Self.streamingColor.scaled(by: breath)
        if state.recording && state.streaming {
            var colors = Array(repeating: streaming, count: ledCount)
            let ring = LightLayout.ring.filter { $0 < ledCount }
            for led in ring {
                // Split by where the LED actually sits: left of the middle records, right
                // streams, softly across the line (the line falls between LEDs 5/6 and 16/17).
                let horizontal = 2 * LightLayout.position(led).x - 1
                let weight = 0.5 - 0.5 * tanh(horizontal / 0.18)
                colors[led] = streaming.mixed(with: recording, amount: weight)
            }
            if LightLayout.leftBar < ledCount { colors[LightLayout.leftBar] = recording }
            if LightLayout.rightBar < ledCount { colors[LightLayout.rightBar] = streaming }
            return colors
        }
        return Array(repeating: state.recording ? recording : state.streaming ? streaming : .black, count: ledCount)
    }
}

/// Both outputs' split light, for `dock-probe obslight`: recording (or paused) and streaming.
public enum OBSLightPreview {
    @MainActor
    public static func pixels(paused: Bool, at time: TimeInterval, ledCount: Int) -> [LightPixel] {
        OBSStatusLight(state: OBSOutputState(recording: true, paused: paused, streaming: true))
            .pixels(at: time, ledCount: ledCount)
    }
}

/// Starts with the app, independent of whether the OBS page has ever been visited.
@MainActor
public final class OBSLightMonitor {
    private let client: OBSClient
    private let center: LightActivityCenter
    private var previous: OBSOutputState?
    public convenience init(center: LightActivityCenter) { self.init(center: center, client: .shared) }
    init(center: LightActivityCenter, client: OBSClient) {
        self.center = center
        self.client = client
    }
    public func start() {
        client.onOutputsChange = { [weak self] state in self?.update(state) }
        update(client.outputState)
        client.start()
    }
    public func stop() {
        client.onOutputsChange = nil
        center.set(nil, for: "obs")
        previous = nil
        client.disconnect()
    }
    private func update(_ state: OBSOutputState) {
        guard previous != state else { return }
        previous = state
        center.set(state.active ? OBSStatusLight(state: state) : nil, for: "obs")
    }
}
