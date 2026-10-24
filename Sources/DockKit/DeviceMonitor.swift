import Foundation
import IOKit
import IOKit.hid

/// Watches for M18s being plugged in and unplugged.
///
/// Callbacks arrive on the main run loop. Devices already attached when `start()`
/// is called are reported as arrivals.
@MainActor
public final class DeviceMonitor {
    /// hidapi path of the device (matches `M18Device.Identity.path`).
    public var onArrival: ((String) -> Void)?
    public var onRemoval: ((String) -> Void)?

    private var manager: IOHIDManager?

    public init() {}

    public func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = M18Layout.productIDs.map { pid -> [String: Any] in
            [
                kIOHIDVendorIDKey: Int(M18Layout.vendorID),
                kIOHIDProductIDKey: Int(pid),
                kIOHIDPrimaryUsagePageKey: Int(M18Layout.usagePage),
                kIOHIDPrimaryUsageKey: Int(M18Layout.usage),
            ]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context, let path = hidapiPath(device) else { return }
            let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.onArrival?(path) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context, let path = hidapiPath(device) else { return }
            let monitor = Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.onRemoval?(path) }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    public func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }
}

/// hidapi on macOS names devices "DevSrvsID:<registry entry id>".
private func hidapiPath(_ device: IOHIDDevice) -> String? {
    var entryID: UInt64 = 0
    guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entryID) == KERN_SUCCESS else { return nil }
    return "DevSrvsID:\(entryID)"
}
