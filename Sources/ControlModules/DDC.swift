import Foundation
import IOKit

/// DDC/CI to an external monitor on Apple Silicon, via the private IOAVService I²C calls
/// (the approach used by m1ddc / MonitorControl). Calls block for tens of milliseconds;
/// run them off the main thread.
public final class DDCDisplay: @unchecked Sendable {
    /// VCP feature codes from the MCCS standard.
    public enum Feature: UInt8, Sendable {
        case brightness = 0x10
        case volume = 0x62
        case audioMute = 0x8D
    }

    private typealias CreateFunction = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFunction = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    nonisolated(unsafe) private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static let create = iokit.flatMap { dlsym($0, "IOAVServiceCreateWithService") }.map { unsafeBitCast($0, to: CreateFunction.self) }
    private static let readI2C = iokit.flatMap { dlsym($0, "IOAVServiceReadI2C") }.map { unsafeBitCast($0, to: I2CFunction.self) }
    private static let writeI2C = iokit.flatMap { dlsym($0, "IOAVServiceWriteI2C") }.map { unsafeBitCast($0, to: I2CFunction.self) }

    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51

    private let service: CFTypeRef
    private let lock = NSLock()

    private init(service: CFTypeRef) {
        self.service = service
    }

    /// The first external display that exposes an AV service. Nil when none is connected.
    public static func firstExternal() -> DDCDisplay? {
        guard let create else { return nil }
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(
            IORegistryGetRootEntry(kIOMainPortDefault), kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &name)
            guard String(decoding: name.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self) == "DCPAVServiceProxy",
                  let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                      .takeRetainedValue() as? String,
                  location == "External",
                  let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue()
            else { continue }
            return DDCDisplay(service: service)
        }
        return nil
    }

    /// Current and maximum value, or nil if the monitor did not answer.
    public func read(_ feature: Feature) -> (current: Int, max: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let readI2C = Self.readI2C, let writeI2C = Self.writeI2C else { return nil }
        for _ in 0..<3 {
            var request: [UInt8] = [0x82, 0x01, feature.rawValue]
            request.append(Self.checksum(request))
            guard writeI2C(service, Self.chipAddress, Self.dataAddress, &request, UInt32(request.count)) == kIOReturnSuccess else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            guard readI2C(service, Self.chipAddress, Self.dataAddress, &reply, UInt32(reply.count)) == kIOReturnSuccess else { continue }
            // 6E 88 02 <result> <vcp> <type> <max hi> <max lo> <cur hi> <cur lo> <checksum>
            guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == feature.rawValue else { continue }
            let maximum = Int(reply[6]) << 8 | Int(reply[7])
            let current = Int(reply[8]) << 8 | Int(reply[9])
            guard maximum > 0 else { continue }
            return (current, maximum)
        }
        return nil
    }

    @discardableResult
    public func write(_ feature: Feature, value: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let writeI2C = Self.writeI2C else { return false }
        var packet: [UInt8] = [0x84, 0x03, feature.rawValue, UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        packet.append(Self.checksum(packet))
        // Some monitors drop the first write; sending twice is what m1ddc does too.
        var ok = false
        for _ in 0..<2 {
            ok = writeI2C(service, Self.chipAddress, Self.dataAddress, &packet, UInt32(packet.count)) == kIOReturnSuccess || ok
            usleep(10_000)
        }
        return ok
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0x6E ^ UInt8(dataAddress)) { $0 ^ $1 }
    }
}
