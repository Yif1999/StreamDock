import AudioToolbox
import CoreAudio
import Foundation
import Observation

/// Shared device inventory, defaults and verified input-mute state.
@MainActor
@Observable
public final class AudioDevices {
    public static let shared = AudioDevices()

    public struct Device: Identifiable, Equatable {
        public let id: AudioObjectID
        public let uid: String
        public let name: String
        public let input: Bool
        public let output: Bool
        public let virtual: Bool
    }

    public private(set) var devices: [Device] = []
    public private(set) var inputID: AudioObjectID = 0
    public private(set) var outputID: AudioObjectID = 0
    public private(set) var inputMuted: Bool?
    public private(set) var error: String?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard
    public private(set) var inputSelection: [String]?
    public private(set) var outputSelection: [String]?
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private init() {
        inputSelection = defaults.stringArray(forKey: "audioInputSelection")
        outputSelection = defaults.stringArray(forKey: "audioOutputSelection")
    }

    public var input: Device? { devices.first { $0.id == inputID } }
    public var output: Device? { devices.first { $0.id == outputID } }

    public func start() {
        guard poll == nil else { return }
        refresh()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    public func isSelected(_ device: Device, input: Bool) -> Bool {
        let selection = input ? inputSelection : outputSelection
        return selection?.contains(device.uid) ?? !device.virtual
    }

    public func select(_ device: Device, input: Bool, enabled: Bool) {
        var selected = (input ? inputSelection : outputSelection)
            ?? devices.filter { (input ? $0.input : $0.output) && !$0.virtual }.map(\.uid)
        selected.removeAll { $0 == device.uid }
        if enabled { selected.append(device.uid) }
        if input { inputSelection = selected } else { outputSelection = selected }
        defaults.set(selected, forKey: input ? "audioInputSelection" : "audioOutputSelection")
        onChange?()
    }

    func cycle(input: Bool) {
        refresh()
        let available = devices.filter { (input ? $0.input : $0.output) && isSelected($0, input: input) }
        let current = input ? inputID : outputID
        guard let target = Self.nextDevice(in: available.map(\.id), current: current) else {
            error = "未选设备"; onChange?(); return
        }
        var address = Self.address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var value = target
        let status = AudioObjectSetPropertyData(Self.system, &address, 0, nil, 4, &value)
        refresh()
        error = status == noErr && (input ? inputID : outputID) == target ? nil : "切换失败"
        onChange?()
    }

    static func nextDevice(in devices: [AudioObjectID], current: AudioObjectID) -> AudioObjectID? {
        guard !devices.isEmpty else { return nil }
        guard let index = devices.firstIndex(of: current) else { return devices.first }
        return devices[(index + 1) % devices.count]
    }

    func toggleInputMute() {
        refresh()
        guard let input, let muted = inputMuted, let controls = muteControls(for: inputID) else {
            error = "不支持静音"; onChange?(); return
        }
        let device = inputID
        let savedKey = "microphoneGain.\(input.uid)"
        let oldValues = controls.addresses.compactMap { Self.readUInt(device, $0) }
        guard oldValues.count == controls.addresses.count else { return }
        let saved = defaults.array(forKey: savedKey) as? [NSNumber]
        var desired: [UInt32]
        if controls.gain {
            if muted {
                // Restore only values actually saved for this exact device and channel layout.
                guard let saved, saved.count == oldValues.count else {
                    error = "请调输入音量"; onChange?(); return
                }
                desired = saved.map { $0.uint32Value }
            } else {
                desired = Array(repeating: Float32(0).bitPattern, count: oldValues.count)
                defaults.set(oldValues.map { NSNumber(value: $0) }, forKey: savedKey)
            }
        } else {
            desired = Array(repeating: muted ? 0 : 1, count: oldValues.count)
        }
        var success = true
        for (index, address) in controls.addresses.enumerated() {
            var address = address
            var value = desired[index]
            if AudioObjectSetPropertyData(device, &address, 0, nil, 4, &value) != noErr { success = false; break }
        }
        if !success {
            // Roll back a partial multi-channel write instead of leaving a half-muted input.
            for (index, address) in controls.addresses.enumerated() {
                var address = address
                var value = oldValues[index]
                _ = AudioObjectSetPropertyData(device, &address, 0, nil, 4, &value)
            }
        }
        refresh()
        success = success && inputID == device && inputMuted == !muted
        if success && controls.gain && muted { defaults.removeObject(forKey: savedKey) }
        error = success ? nil : "静音操作失败"
        onChange?()
    }

    func refresh() {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &size) == noErr else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty else {
            devices = []; inputID = 0; outputID = 0; inputMuted = nil; onChange?(); return
        }
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return }
        let inventory = ids.compactMap { id -> Device? in
            guard Self.readUInt(id, Self.address(kAudioDevicePropertyDeviceIsAlive)) == 1,
                  let uid = Self.readString(id, kAudioDevicePropertyDeviceUID),
                  let name = Self.readString(id, kAudioObjectPropertyName) else { return nil }
            let input = Self.channelCount(id, input: true) > 0
            let output = Self.channelCount(id, input: false) > 0
            guard input || output else { return nil }
            let transport = Self.readUInt(id, Self.address(kAudioDevicePropertyTransportType))
            return Device(id: id, uid: uid, name: name, input: input, output: output,
                          virtual: transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate)
        }.sorted { $0.name == $1.name ? $0.uid < $1.uid : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if devices != inventory { devices = inventory }
        inputID = Self.readUInt(Self.system, Self.address(kAudioHardwarePropertyDefaultInputDevice)) ?? 0
        outputID = Self.readUInt(Self.system, Self.address(kAudioHardwarePropertyDefaultOutputDevice)) ?? 0
        if let controls = muteControls(for: inputID) {
            let values = controls.addresses.compactMap { Self.readUInt(inputID, $0) }
            inputMuted = values.count == controls.addresses.count
                ? values.allSatisfy { controls.gain ? Float32(bitPattern: $0) == 0 : $0 != 0 } : nil
        } else { inputMuted = nil }
        onChange?()
    }

    private func muteControls(for device: AudioObjectID) -> (addresses: [AudioObjectPropertyAddress], gain: Bool)? {
        let count = Self.channelCount(device, input: true)
        guard count > 0 else { return nil }
        for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
            let master = Self.address(selector, input: true)
            if Self.writable(device, master) { return ([master], selector == kAudioDevicePropertyVolumeScalar) }
            let channels = (1...count).map { Self.address(selector, input: true, element: UInt32($0)) }
            if channels.allSatisfy({ Self.writable(device, $0) }) {
                return (channels, selector == kAudioDevicePropertyVolumeScalar)
            }
        }
        return nil
    }

    private static func address(_ selector: AudioObjectPropertySelector, input: Bool? = nil, element: UInt32 = 0) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
            mScope: input.map { $0 ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput } ?? kAudioObjectPropertyScopeGlobal,
            mElement: element)
    }

    private static func readUInt(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        var size: UInt32 = 4
        var value: UInt32 = 0
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func writable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    private static func channelCount(_ object: AudioObjectID, input: Bool) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, input: input)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, memory) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
