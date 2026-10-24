import AudioToolbox
import CoreAudio
import Foundation

/// Volume and mute of the default output device, with change notifications.
@MainActor
final class SystemAudio {
    /// Called on the main thread whenever volume, mute or the output device changes.
    var onChange: (() -> Void)?

    private(set) var volume: Float?
    private(set) var isMuted = false
    /// The output is a monitor's speakers (DisplayPort / HDMI), whose volume macOS cannot set.
    private(set) var outputIsDisplay = false

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var transportAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    func startObserving() {
        guard defaultDeviceListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bindDefaultDevice() }
        }
        AudioObjectAddPropertyListenerBlock(Self.systemObject, &Self.defaultOutputAddress, .main, listener)
        defaultDeviceListener = listener
        bindDefaultDevice()
    }

    func stopObserving() {
        unbindDevice()
        if let listener = defaultDeviceListener {
            AudioObjectRemovePropertyListenerBlock(Self.systemObject, &Self.defaultOutputAddress, .main, listener)
            defaultDeviceListener = nil
        }
    }

    /// Two percent per step; raising the volume unmutes.
    func step(by steps: Int) {
        guard let current = volume else { return }
        let target = min(1, max(0, current + Float(steps) * 0.02))
        if steps > 0, isMuted { setMuted(false) }
        var value = target
        AudioObjectSetPropertyData(device, &Self.volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        refresh()
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    private func setMuted(_ muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &Self.muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private func bindDefaultDevice() {
        unbindDevice()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(Self.systemObject, &Self.defaultOutputAddress, 0, nil, &size, &id)
        device = id

        for address in [Self.volumeAddress, Self.muteAddress] where AudioObjectHasProperty(id, [address]) {
            var address = address
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            AudioObjectAddPropertyListenerBlock(id, &address, .main, listener)
            deviceListeners.append((address, listener))
        }
        refresh()
    }

    private func unbindDevice() {
        for (address, listener) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener)
        }
        deviceListeners.removeAll()
    }

    private func refresh() {
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &Self.transportAddress, 0, nil, &transportSize, &transport)
        outputIsDisplay = transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI

        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        volume = AudioObjectHasProperty(device, &Self.volumeAddress)
            && AudioObjectGetPropertyData(device, &Self.volumeAddress, 0, nil, &size, &level) == noErr ? level : nil

        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        isMuted = AudioObjectHasProperty(device, &Self.muteAddress)
            && AudioObjectGetPropertyData(device, &Self.muteAddress, 0, nil, &size, &muted) == noErr && muted != 0
        onChange?()
    }
}
