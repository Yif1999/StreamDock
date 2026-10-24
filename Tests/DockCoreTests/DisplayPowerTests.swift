import AppKit
import Testing
@testable import DockCore
@testable import DockKit

@MainActor struct DisplayPowerTests {
    @Test func firmwareWakeReleaseRequestsMacWakeButPreSleepReleaseDoesNot() {
        for key in [DockKey.lcd(6), .round(1)] {
            var gate = WakeKeyGate()
            let up = DockInputEvent(key: key, pressed: false)
            let firmwareWake = gate.route(up, asleep: true)
            #expect(firmwareWake.consume && firmwareWake.wake)
            gate.suppress([key])
            let heldRelease = gate.route(up, asleep: true)
            #expect(heldRelease.consume && !heldRelease.wake)
            _ = gate.route(DockInputEvent(key: key, pressed: true), asleep: true)
            let normalRelease = gate.route(up, asleep: true)
            #expect(normalRelease.consume && !normalRelease.wake)
            #expect(!gate.route(up, asleep: false).wake)
        }
    }
    @Test func followsDisplaysAndSystemSleepWithoutPrematureWake() {
        var asleep: Bool? = false
        var changes: [Bool] = []
        let monitor = DisplayPowerMonitor(center: NotificationCenter(), readAsleep: { asleep }, changed: { changes.append($0) })
        monitor.start()
        defer { monitor.stop() }
        #expect(changes == [false])
        monitor.receive(NSWorkspace.screensDidSleepNotification)
        monitor.receive(NSWorkspace.willSleepNotification)
        monitor.refresh() // Stale awake display query cannot defeat system sleep.
        #expect(changes == [false, true])
        asleep = true
        monitor.receive(NSWorkspace.didWakeNotification)
        #expect(changes == [false, true])
        monitor.receive(NSWorkspace.screensDidWakeNotification)
        #expect(changes == [false, true, false])
        asleep = nil; monitor.refresh()
        #expect(changes == [false, true, false])
    }
    @Test func firstPressIsConsumedThroughReleaseForLCDAndRoundKeys() {
        for key in [DockKey.lcd(5), .round(1)] {
            var gate = WakeKeyGate()
            let down = DockInputEvent(key: key, pressed: true)
            let up = DockInputEvent(key: key, pressed: false)
            let first = gate.route(down, asleep: true)
            #expect(first.consume && first.wake)
            let repeatDown = gate.route(down, asleep: false)
            #expect(repeatDown.consume && !repeatDown.wake)
            #expect(gate.route(up, asleep: false).consume)
            #expect(!gate.route(down, asleep: false).consume)
            #expect(!gate.route(up, asleep: false).consume)
        }
    }
    @Test func preSleepHeldKeyCannotBecomeAnActionAfterWake() {
        var earlyWake = WakeKeyGate()
        earlyWake.screenDidWake(at: 10)
        let wakePress = earlyWake.route(DockInputEvent(key: .lcd(5), pressed: true), asleep: false, at: 10.1)
        #expect(wakePress.consume && !wakePress.wake)
        #expect(earlyWake.route(DockInputEvent(key: .lcd(5), pressed: false), asleep: false, at: 10.2).consume)
        #expect(!earlyWake.route(DockInputEvent(key: .lcd(5), pressed: true), asleep: false, at: 10.3).consume)
        var gate = WakeKeyGate()
        gate.suppress([.lcd(5)])
        #expect(gate.route(DockInputEvent(key: .lcd(5), pressed: true), asleep: false).consume)
        #expect(gate.route(DockInputEvent(key: .lcd(5), pressed: false), asleep: false).consume)
        #expect(!gate.route(DockInputEvent(key: .lcd(5), pressed: true), asleep: false).consume)
    }
    @Test func suspendedLightsIgnoreUpdatesAndResumeLatestSourceAndBrightness() {
        var time = 0.0
        let engine = LightEngine(clock: { time }, automaticTicks: false)
        var writes = 0
        var color = RGB.black
        var masters: [Int] = []
        engine.sendBrightness = { masters.append($0); writes += 1 }
        engine.sendSolid = { color = $0; writes += 1 }
        engine.sendFrame = { color = $0[0]; writes += 1 }
        engine.show(.solid(.white), fade: 0.6)
        time = 1; engine.render()
        engine.suspend()
        let before = writes
        engine.show(.solid(RGB(255, 0, 0), active: true), fade: 0.6)
        engine.setBrightness(40)
        time = 2; engine.render()
        #expect(writes == before)
        engine.resume()
        time = 3; engine.render()
        #expect(color == RGB(34, 0, 0))
        #expect(masters == [100, 100])
    }
}
