import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import os

private let powerLog = Logger(subsystem: "StreamDock", category: "DisplayPower")

/// Follows the Mac's display sleep state without preventing normal idle sleep.
@MainActor
public final class DisplayPowerMonitor {
    private let center: NotificationCenter
    private let readAsleep: () -> Bool?
    private let changed: (Bool) -> Void
    private var observers: [NSObjectProtocol] = []
    private var poll: Task<Void, Never>?
    private var systemSleeping = false
    private var screensSleeping = false
    private var reported: Bool?
    private var wakeAssertion = IOPMAssertionID(kIOPMNullAssertionID)

    public convenience init(changed: @escaping (Bool) -> Void) {
        self.init(center: NSWorkspace.shared.notificationCenter, readAsleep: Self.systemDisplaysAsleep, changed: changed)
    }
    init(center: NotificationCenter, readAsleep: @escaping () -> Bool?, changed: @escaping (Bool) -> Void) {
        self.center = center; self.readAsleep = readAsleep; self.changed = changed
    }
    public func start() {
        guard observers.isEmpty else { return }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let eventName = notification.name
                MainActor.assumeIsolated { self?.receive(eventName) }
            })
        }
        refresh()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.refresh()
            }
        }
    }
    public func stop() {
        poll?.cancel(); poll = nil
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        if wakeAssertion != kIOPMNullAssertionID { IOPMAssertionRelease(wakeAssertion); wakeAssertion = IOPMAssertionID(kIOPMNullAssertionID) }
    }
    /// Reports physical user input to macOS; this does not bypass the lock screen.
    public func requestWake() {
        let result = IOPMAssertionDeclareUserActivity("StreamDock key pressed" as CFString, kIOPMUserActiveLocal, &wakeAssertion)
        powerLog.notice("Wake request result=\(result) assertion=\(self.wakeAssertion) systemSleeping=\(self.systemSleeping) screensSleeping=\(self.screensSleeping)")
    }
    func receive(_ name: Notification.Name) {
        powerLog.notice("Workspace power notification=\(name.rawValue, privacy: .public)")
        switch name {
        case NSWorkspace.screensDidSleepNotification: screensSleeping = true
        case NSWorkspace.screensDidWakeNotification: screensSleeping = false
        case NSWorkspace.willSleepNotification: systemSleeping = true
        case NSWorkspace.didWakeNotification: systemSleeping = false; screensSleeping = readAsleep() ?? screensSleeping
        default: return
        }
        publish()
    }
    func refresh() {
        if let asleep = readAsleep() {
            if screensSleeping != asleep { powerLog.notice("Display query changed asleep=\(asleep)") }
            screensSleeping = asleep
        }
        publish()
    }
    private func publish() {
        let value = systemSleeping || screensSleeping
        guard value != reported else { return }
        reported = value; changed(value)
    }
    private static func systemDisplaysAsleep() -> Bool? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return true }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }
}
