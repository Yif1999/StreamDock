import CTransport
import Foundation
import os

let log = Logger(subsystem: "StreamDock", category: "DockKit")

/// TRANSPORT_ERROR_DEVICE_NOT_CONNECTED (compound C macros are not imported into Swift).
private let deviceNotConnected: UInt32 = TRANSPORT_ERROR_DEVICE | TRANSPORT_MODULE_DEVICE | 0x01

public struct TransportError: Error, CustomStringConvertible {
    public let call: String
    public let code: UInt32
    public let message: String

    public var description: String {
        "\(call) failed: 0x\(String(code, radix: 16)) \(message)"
    }
}

/// An open connection to one StreamDock M18.
///
/// All writes go through one serial queue; key events are read on a dedicated
/// thread and delivered through `onInput` on that thread. The reader keeps the
/// device alive, so owners must call `close(notifyDevice:)`.
public final class M18Device: @unchecked Sendable {
    public struct Identity: Hashable, Sendable {
        /// hidapi path, e.g. "DevSrvsID:4294971234".
        public let path: String
        public let serialNumber: String
        public let productID: UInt16
    }

    public let identity: Identity
    public private(set) var firmwareVersion = ""

    private let handle: TransportHandle
    private let io = DispatchQueue(label: "StreamDock.M18.io")
    private let onInput: @Sendable (DockInputEvent) -> Void

    private let stateLock = NSLock()
    private var isOpen = true
    private var skippedLEDFrames = 0
    private let readerFinished = DispatchSemaphore(value: 0)
    private var heartbeat: DispatchSourceTimer?

    /// M18 devices currently attached (vendor HID interface only).
    public static func attached() -> [Identity] {
        var result: [Identity] = []
        for pid in M18Layout.productIDs {
            guard let list = transport_hid_enumerate(M18Layout.vendorID, pid) else { continue }
            defer { transport_hid_free_enumeration(list) }
            var node: UnsafeMutablePointer<hid_device_info>? = list
            while let info = node?.pointee {
                if info.usage_page == M18Layout.usagePage, info.usage == M18Layout.usage, let path = info.path {
                    result.append(Identity(
                        path: String(cString: path),
                        serialNumber: wideString(info.serial_number),
                        productID: info.product_id
                    ))
                }
                node = info.next
            }
        }
        return result
    }

    /// Opens and initializes the device. Blocks for a few hundred milliseconds; call off the main thread.
    public init(opening identity: Identity, displayAwake: Bool = true, onInput: @escaping @Sendable (DockInputEvent) -> Void) throws {
        self.identity = identity
        self.onInput = onInput

        var created: TransportHandle?
        let createResult: UInt32 = {
            guard let list = transport_hid_enumerate(M18Layout.vendorID, identity.productID) else { return deviceNotConnected }
            defer { transport_hid_free_enumeration(list) }
            var node: UnsafeMutablePointer<hid_device_info>? = list
            while let current = node {
                if let path = current.pointee.path, String(cString: path) == identity.path {
                    return transport_create(current, &created)
                }
                node = current.pointee.next
            }
            return deviceNotConnected
        }()
        guard createResult == TRANSPORT_SUCCESS, let handle = created else {
            throw TransportError(call: "transport_create", code: createResult, message: "")
        }
        self.handle = handle

        do {
            try Self.check(transport_set_reportSize(handle, 513, 1025, 0), "set_reportSize", handle)
            if displayAwake {
                try Self.check(transport_wakeup_screen(handle), "wakeup_screen", handle)
                try Self.check(transport_clear_all_keys(handle), "clear_all_keys", handle)
                try Self.check(transport_refresh(handle), "refresh", handle)
            } else {
                try Self.check(transport_set_key_brightness(handle, 0), "set_key_brightness", handle)
                try Self.check(transport_set_led_brightness(handle, 0), "set_led_brightness", handle)
                try Self.check(transport_sleep(handle), "sleep", handle)
            }
        } catch {
            _ = transport_destroy(handle)
            throw error
        }

        startReader()
        // Like the vendor SDK on macOS: the version is only answered once the reader is running.
        Thread.sleep(forTimeInterval: 0.1)
        var version = [CChar](repeating: 0, count: 64)
        _ = transport_get_firmware_version(handle, &version, version.count)
        firmwareVersion = String(decoding: version.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
        startHeartbeat()
        log.info("Opened M18 \(identity.serialNumber, privacy: .public) fw=\(self.firmwareVersion, privacy: .public)")
    }

    // MARK: - Commands (asynchronous, in order)

    /// Uploads JPEG images for LCD keys (1–15), then refreshes the screen once.
    public func setKeyImages(_ images: [Int: Data]) {
        guard !images.isEmpty else { return }
        perform("set_key_image_stream") { handle in
            for (key, jpeg) in images.sorted(by: { $0.key < $1.key }) {
                let result = jpeg.withUnsafeBytes { raw in
                    transport_set_key_image_stream(
                        handle, raw.baseAddress!.assumingMemoryBound(to: CChar.self), jpeg.count, M18Layout.imageSlot(forKey: key)
                    )
                }
                if result != TRANSPORT_SUCCESS { return result }
            }
            return transport_refresh(handle)
        }
    }

    /// Uploads a JPEG for the whole screen (`M18Layout.screenWidth` × `screenHeight`); the keys'
    /// own images are drawn over it.
    public func setBackgroundImage(_ jpeg: Data) {
        perform("set_background_image_stream") { handle in
            let result = jpeg.withUnsafeBytes { raw in
                transport_set_background_image_stream(handle, raw.baseAddress!.assumingMemoryBound(to: CChar.self), jpeg.count, 3000)
            }
            return result == TRANSPORT_SUCCESS ? transport_refresh(handle) : result
        }
    }

    public func clearKeys(_ keys: [Int]) {
        guard !keys.isEmpty else { return }
        perform("clear_key") { handle in
            for key in keys {
                let result = transport_clear_key(handle, M18Layout.imageSlot(forKey: key))
                if result != TRANSPORT_SUCCESS { return result }
            }
            return transport_refresh(handle)
        }
    }

    public func sleepScreen() { perform("sleep") { transport_sleep($0) } }
    public func wakeScreen() { perform("wakeup_screen") { transport_wakeup_screen($0) } }

    /// LCD backlight, 0–100.
    public func setScreenBrightness(_ percent: Int) {
        perform("set_key_brightness") { transport_set_key_brightness($0, UInt8(clamping: percent)) }
    }

    public func setLEDColor(red: UInt8, green: UInt8, blue: UInt8) {
        perform("set_led_color") { transport_set_led_color($0, M18Layout.ledCount, red, green, blue) }
    }

    /// One color per LED (24; physical positions are documented in M18Layout).
    ///
    /// The vendor SDK only enables this on the N4 Pro. On the M18 a frame is shown only when the
    /// next per-LED frame arrives, so a static picture must be sent twice (`settle: true`);
    /// continuous animation needs no special handling.
    public func setLEDColors(_ colors: [(UInt8, UInt8, UInt8)], settle: Bool = false) {
        guard !colors.isEmpty else { return }
        perform("set_single_led_color") { handle in
            colors.withUnsafeBufferPointer { buffer in
                var result = transport_set_single_led_color(handle, UInt16(colors.count), buffer.baseAddress!)
                if settle, result == TRANSPORT_SUCCESS {
                    result = transport_set_single_led_color(handle, UInt16(colors.count), buffer.baseAddress!)
                }
                return result
            }
        }
    }

    /// An animation frame: dropped while the transport is still busy so frames never pile up.
    public func setLEDFrame(_ colors: [(UInt8, UInt8, UInt8)]) {
        guard !colors.isEmpty else { return }
        perform("set_single_led_color") { handle in
            var canWrite: Int32 = 1
            if transport_can_write(handle, &canWrite) == TRANSPORT_SUCCESS, canWrite == 0 {
                self.stateLock.lock(); self.skippedLEDFrames += 1; self.stateLock.unlock()
                return TRANSPORT_SUCCESS
            }
            return colors.withUnsafeBufferPointer { transport_set_single_led_color(handle, UInt16(colors.count), $0.baseAddress!) }
        }
    }

    /// Animation frames dropped so far because the transport was busy. For diagnostics.
    public var droppedLEDFrames: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return skippedLEDFrames
    }

    /// What the transport reports for `can_write` (nil if the call itself failed). For diagnostics.
    public func canWrite() -> Int32? {
        io.sync {
            var value: Int32 = -1
            return transport_can_write(handle, &value) == TRANSPORT_SUCCESS ? value : nil
        }
    }

    /// Blocks until every queued command has been sent.
    public func waitUntilIdle() {
        io.sync {}
    }

    /// 0–100.
    public func setLEDBrightness(_ percent: Int) {
        perform("set_led_brightness") { transport_set_led_brightness($0, UInt8(clamping: percent)) }
    }

    /// Hands the light strip back to the firmware's default effect.
    public func resetLEDEffect() {
        perform("reset_led_color") { transport_reset_led_color($0) }
    }

    /// Stops reading, optionally tells the device we are leaving (it clears the screen),
    /// and releases the handle. Safe to call more than once.
    ///
    /// Pass `notifyDevice: false` when the device was unplugged: writing to a removed
    /// device can crash inside the native library.
    public func close(notifyDevice: Bool) {
        stateLock.lock()
        let wasOpen = isOpen
        isOpen = false
        stateLock.unlock()
        guard wasOpen else { return }

        heartbeat?.cancel()
        let readerStopped = readerFinished.wait(timeout: .now() + 1) == .success
        io.sync {
            if notifyDevice { _ = transport_disconnected(handle) }
            if readerStopped {
                _ = transport_destroy(handle)
            } else {
                log.error("Reader thread did not stop; leaking transport handle to avoid a crash")
            }
        }
        log.info("Closed M18 \(self.identity.serialNumber, privacy: .public)")
    }

    // MARK: - Internals

    private var open: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isOpen
    }

    private func perform(_ call: String, _ body: @escaping @Sendable (TransportHandle) -> UInt32) {
        io.async { [self] in
            guard open else { return }
            let result = body(handle)
            if result != TRANSPORT_SUCCESS {
                log.error("\(Self.error(result, call, self.handle).description, privacy: .public)")
            }
        }
    }

    private func startReader() {
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 1024)
            while open {
                var length = buffer.count
                let result = transport_read(handle, &buffer, &length, 100)
                guard result == TRANSPORT_SUCCESS, length > 0 else {
                    // Timeouts are normal when no key is pressed; back off on real errors.
                    if result != TRANSPORT_SUCCESS, result & 0xFF00_0000 != TRANSPORT_ERROR_TIMEOUT {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    continue
                }
                if let event = Self.decodeInput(buffer[..<length]) {
                    onInput(event)
                }
            }
            readerFinished.signal()
        }
        thread.name = "StreamDock.M18.reader"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: io)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, self.open else { return }
            _ = transport_heartbeat(self.handle)
        }
        timer.resume()
        heartbeat = timer
    }

    /// Input packets look like "ACK" .. "OK" .. [code] [state]; code 0xFF acknowledges a write.
    static func decodeInput(_ data: ArraySlice<UInt8>) -> DockInputEvent? {
        let bytes = Array(data)
        guard bytes.count >= 11,
              bytes[0] == 0x41, bytes[1] == 0x43, bytes[2] == 0x4B,
              bytes[5] == 0x4F, bytes[6] == 0x4B,
              bytes[9] != 0xFF,
              let key = M18Layout.key(forEventCode: bytes[9])
        else { return nil }
        return DockInputEvent(key: key, pressed: bytes[10] == 0x01)
    }

    private static func check(_ result: UInt32, _ call: String, _ handle: TransportHandle) throws {
        if result != TRANSPORT_SUCCESS { throw error(result, call, handle) }
    }

    private static func error(_ result: UInt32, _ call: String, _ handle: TransportHandle) -> TransportError {
        var info = TransportErrorInfo()
        _ = transport_get_last_error_info(handle, &info)
        let message = withUnsafeBytes(of: &info.error_message) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return TransportError(call: call, code: result, message: message)
    }
}

private func wideString(_ pointer: UnsafeMutablePointer<wchar_t>?) -> String {
    guard var cursor = pointer else { return "" }
    var scalars = String.UnicodeScalarView()
    while cursor.pointee != 0 {
        if let scalar = Unicode.Scalar(UInt32(bitPattern: cursor.pointee)) { scalars.append(scalar) }
        cursor += 1
    }
    return String(scalars)
}
