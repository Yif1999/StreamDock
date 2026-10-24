import DockKit
import Foundation

/// Swallow the entire first press/release cycle, even if the display wakes mid-hold.
struct WakeKeyGate {
    private var consumed: Set<DockKey> = []
    private var wakeGraceUntil: TimeInterval = -.infinity
    mutating func screenDidWake(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // USB may wake macOS before its key event reaches our main actor.
        if consumed.isEmpty { wakeGraceUntil = time + 0.75 }
    }
    mutating func suppress(_ keys: [DockKey]) { consumed.formUnion(keys) }
    mutating func reset() { consumed.removeAll(); wakeGraceUntil = -.infinity }
    mutating func route(_ event: DockInputEvent, asleep: Bool, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> (consume: Bool, wake: Bool) {
        if !event.pressed {
            return (consumed.remove(event.key) != nil || asleep, false)
        }
        if consumed.contains(event.key) { return (true, false) }
        if asleep || time < wakeGraceUntil {
            consumed.insert(event.key)
            wakeGraceUntil = -.infinity
            return (true, asleep)
        }
        return (false, false)
    }
}
