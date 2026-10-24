import Foundation
import Testing
@testable import DockCore

@MainActor
struct LightActivityTests {
    final class Animation: LightAnimation {
        var isActive = true
        func pixels(at time: TimeInterval, ledCount: Int) -> [LightPixel] { Array(repeating: LightPixel(.white), count: ledCount) }
    }

    @Test func idleHalfActiveFullAndPauseIsDetectedWithoutReplacingAnimation() {
        var now = 0.0
        let engine = LightEngine(clock: { now }, automaticTicks: false)
        var shown = RGB.black
        engine.sendSolid = { shown = $0 }
        engine.sendFrame = { shown = $0[0] }
        engine.setBrightness(80)
        engine.show(.solid(.white), fade: 0.6)
        now = 1; engine.render()
        #expect(shown.red == 34) // (0.8 × 0.5)^2.2 × 255
        let music = Animation()
        engine.show(.animation(music), fade: 0.6)
        now = 1.3; engine.render()
        #expect(shown.red == 83)
        now = 2; engine.render()
        #expect(shown.red == 156)
        music.isActive = false
        engine.render()
        now = 3; engine.render()
        #expect(shown.red == 34)
        music.isActive = true
        engine.render()
        now = 4; engine.render()
        #expect(shown.red == 156)
    }

    @Test func userBrightnessChangesAndReconnectPreserveActivityGain() {
        var now = 0.0
        let engine = LightEngine(clock: { now }, automaticTicks: false)
        var masters: [Int] = []
        var shown = RGB.black
        engine.sendBrightness = { masters.append($0) }
        engine.sendSolid = { shown = $0 }
        engine.sendFrame = { shown = $0[0] }
        engine.setBrightness(30)
        engine.show(.solid(.white), fade: 0.6)
        now = 1; engine.render()
        #expect(shown.red == 4)
        let count = masters.count
        engine.fadeInFromBlack()
        now = 2; engine.render()
        #expect(masters.count == count + 1 && masters.last == 100)
        #expect(shown.red == 4)
        engine.show(.solid(.white, active: true), fade: 0.6)
        now = 3; engine.render()
        #expect(shown.red == 18)
        engine.setBrightness(0)
        #expect(shown == .black)
        now = 4; engine.render()
        #expect(shown == .black)
    }

    @Test func notificationThenOBSRestoreThenMusicThenScene() {
        let center = LightActivityCenter()
        let obs = Animation(), music = Animation()
        center.set(obs, for: "obs")
        var source = center.source(alert: RGB(255, 0, 0), sceneAnimation: music, sceneColor: .white)
        if case .solid(let color, let active) = source { #expect(color == RGB(255, 0, 0) && active) }
        else { Issue.record("Notification must take priority") }
        source = center.source(alert: nil, sceneAnimation: music, sceneColor: .white)
        if case .animation(let selected) = source { #expect(selected === obs) }
        else { Issue.record("OBS must return after notification") }
        // Switching to a page with no animation still leaves OBS visible.
        if case .animation(let selected) = center.source(alert: nil, sceneAnimation: nil, sceneColor: .black) {
            #expect(selected === obs)
        } else { Issue.record("OBS must survive page and scene changes") }
        center.set(nil, for: "obs")
        if case .animation(let selected) = center.source(alert: nil, sceneAnimation: music, sceneColor: .white) {
            #expect(selected === music)
        } else { Issue.record("Music must return when OBS stops") }
        source = center.source(alert: nil, sceneAnimation: nil, sceneColor: .white)
        if case .solid(let color, let active) = source { #expect(color == .white && !active) }
        else { Issue.record("Idle must use scene color") }
    }

    @Test func brightnessRampRetargetsContinuously() {
        var ramp = LightBrightness()
        ramp.setTarget(100, at: 0)
        let before = ramp.level(at: 0.2)
        ramp.setTarget(20, at: 0.2)
        #expect(abs(ramp.level(at: 0.2) - before) < 0.00001)
        #expect(ramp.level(at: 1) == 20)
    }
}
