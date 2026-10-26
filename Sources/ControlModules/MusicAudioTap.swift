import AudioToolbox
import CoreAudio
import Foundation
import os
import RhythmKit

private let log = Logger(subsystem: "StreamDock", category: "AudioTap")

/// Live rhythm analysis of Music output, including its shared AirPlay renderer when delegated,
/// through a Core Audio process tap (macOS 14.2+), feeding RhythmKit on the audio thread.
/// Needs the "System Audio Recording" permission. Samples are analysed on the fly and never
/// stored or sent anywhere (a debug trace keeps only feature values, see `RhythmRecorder`).
///
/// `start` and `stop` return immediately: the Core Audio calls run on a private queue,
/// because they can block for as long as the system permission prompt is on screen.
final class MusicAudioTap: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSignal: TimeInterval = 0
    private var running = false
    private var lastCallback: TimeInterval = 0
    // Accessed only on the control queue.
    private var route: Route?
    private var lastAttempt: TimeInterval = 0

    private struct Route: Equatable {
        let processes: [AudioObjectID]
        let devices: [AudioObjectID]
        let outputUID: String?
    }
    private var pendingEvents: [RhythmEvent] = []
    private var latestSnapshot = RhythmSnapshot()
    private let control = DispatchQueue(label: "StreamDock.AudioTap.control")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "StreamDock.AudioTap", qos: .userInteractive)

    // Analysis state; touched only on `ioQueue`.
    private var sampleRate = 48_000.0
    private var extractor: FeatureExtractor?
    private var analyzer: RhythmAnalyzer?
    private var mono: [Float] = []

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Events since the last call and the latest snapshot. Read once per animation frame.
    func drain() -> (events: [RhythmEvent], snapshot: RhythmSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        return (events, latestSnapshot)
    }

    /// The latest rhythm snapshot, without consuming events.
    var snapshot: RhythmSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return latestSnapshot
    }

    /// Feature frames per second of the current session.
    var frameRate: Double {
        lock.lock()
        defer { lock.unlock() }
        return currentFrameRate
    }
    private var currentFrameRate = 48_000.0 / Double(FeatureExtractor.hopSize)

    /// True if real sound arrived recently (false when permission is missing: the tap then
    /// delivers silence).
    var hasSignal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastSignal < 2
    }

    /// Re-evaluate Music's actual renderer; AirPlay can move playback into Apple's helper.
    func start(pid: pid_t, airPlayEnabled: Bool = false) {
        control.async { [self] in
            let next = Self.captureRoute(pid: pid, airPlayEnabled: airPlayEnabled)
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            let stalled = running && route?.devices.isEmpty == false && now - max(lastCallback, lastAttempt) > 5
            lock.unlock()
            guard next != route || procID == nil || stalled else { return }
            guard now - lastAttempt >= 2 else { return }
            lastAttempt = now
            stopNow()
            lock.lock()
            running = false
            lastSignal = 0
            pendingEvents.removeAll()
            latestSnapshot = RhythmSnapshot()
            lock.unlock()
            route = next
            guard let next else { return }
            log.notice("Capture route processes=\(next.processes.description, privacy: .public) devices=\(next.devices.description, privacy: .public)")
            let started = startNow(route: next)
            lock.lock()
            running = started
            lock.unlock()
        }
    }

    func stop() {
        control.async { [self] in
            stopNow()
            lock.lock()
            running = false
            lastSignal = 0
            route = nil
            pendingEvents.removeAll()
            latestSnapshot = RhythmSnapshot()
            lock.unlock()
        }
    }

    private func startNow(route: Route) -> Bool {
        let description = CATapDescription(stereoMixdownOfProcesses: route.processes)
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else {
            log.error("Creating the process tap failed: \(status)")
            return false
        }
        tapID = tap

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "StreamDock Music Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        // Tap-only aggregate: no physical-device input streams can enter the analysis,
        // and changing the output clock does not pin capture to the old device.
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr else {
            log.error("Creating the aggregate device failed: \(status)")
            stopNow()
            return false
        }
        aggregateID = aggregate

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &format) == noErr,
              format.mSampleRate > 0, format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
            log.error("Unsupported tap format")
            stopNow()
            return false
        }
        ioQueue.sync { sampleRate = format.mSampleRate }
        // A fresh analysis per session.
        ioQueue.sync {
            let extractor = FeatureExtractor(sampleRate: sampleRate)
            self.extractor = extractor
            analyzer = RhythmAnalyzer(frameRate: extractor.frameRate)
            lock.lock()
            currentFrameRate = extractor.frameRate
            lock.unlock()
        }
        // A pending debug trace starts with the session, so it covers the very first frames.
        let seconds = UserDefaults.standard.double(forKey: "rhythmTraceSeconds")  // a number or a numeric string
        if seconds > 0 {
            UserDefaults.standard.removeObject(forKey: "rhythmTraceSeconds")
            RhythmRecorder.shared.start(seconds: seconds, frameRate: currentFrameRate)
        }

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }
        guard status == noErr, let proc else {
            log.error("Creating the IO proc failed: \(status)")
            stopNow()
            return false
        }
        procID = proc
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else {
            log.error("Starting the tap failed: \(status)")
            stopNow()
            return false
        }
        log.notice("Tapping Music audio at \(Int(format.mSampleRate)) Hz")
        return true
    }

    private func stopNow() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Analysis (IO queue)

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        lock.lock()
        lastCallback = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        guard let extractor, let analyzer else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        // Mix down to mono (interleaved or one buffer per channel).
        mono.removeAll(keepingCapacity: true)
        var energy: Float = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let samples = data.assumingMemoryBound(to: Float32.self)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size / channels
            if mono.isEmpty { mono = [Float](repeating: 0, count: frames) }
            guard frames == mono.count else { continue }
            let scale = 1 / Float(channels * buffers.count)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += samples[frame * channels + channel] }
                mono[frame] += sum * scale
            }
        }
        guard !mono.isEmpty else { return }
        for sample in mono { energy += sample * sample }

        let now = ProcessInfo.processInfo.systemUptime
        let features = mono.withUnsafeBufferPointer { extractor.process($0, endTime: now) }
        var events: [RhythmEvent] = []
        for frame in features {
            RhythmRecorder.shared.record(frame)
            events += analyzer.process(frame)
        }

        lock.lock()
        // A global activity can hide Music for hours. Do not queue old beats for its return.
        pendingEvents.removeAll { $0.time < now - 0.25 }
        pendingEvents += events
        latestSnapshot = analyzer.snapshot
        if sqrt(energy / Float(mono.count)) > 0.0005 { lastSignal = now }
        lock.unlock()
    }

    // MARK: - Helpers

    static func selectProcesses(music: AudioObjectID?, musicHasOutput: Bool,
                                airPlayEnabled: Bool, activeHelpers: [AudioObjectID]) -> [AudioObjectID] {
        if airPlayEnabled && !musicHasOutput && !activeHelpers.isEmpty { return activeHelpers }
        return music.map { [$0] } ?? []
    }

    private static func captureRoute(pid: pid_t, airPlayEnabled: Bool) -> Route? {
        let music = processObject(for: pid)
        let musicOutputs = music.map { objectIDs($0, selector: kAudioProcessPropertyDevices, scope: kAudioDevicePropertyScopeOutput) } ?? []
        var processes = Self.selectProcesses(music: music, musicHasOutput: !musicOutputs.isEmpty, airPlayEnabled: airPlayEnabled, activeHelpers: [])
        var outputs = musicOutputs
        // Only use the shared AirPlay renderer while Music itself confirms AirPlay is enabled
        // and has no local output. Never fall back to a global/system-wide audio tap.
        if airPlayEnabled && musicOutputs.isEmpty {
            let helpers = objectIDs(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList)
                .filter { stringProperty($0, selector: kAudioProcessPropertyBundleID) == "com.apple.AirPlayXPCHelper" }
            let active = helpers.filter { !objectIDs($0, selector: kAudioProcessPropertyDevices, scope: kAudioDevicePropertyScopeOutput).isEmpty }
            processes = Self.selectProcesses(music: music, musicHasOutput: false, airPlayEnabled: airPlayEnabled, activeHelpers: active.isEmpty ? helpers : active)
            outputs = processes.flatMap { objectIDs($0, selector: kAudioProcessPropertyDevices, scope: kAudioDevicePropertyScopeOutput) }
        }
        guard !processes.isEmpty else { return nil }
        return Route(processes: processes.sorted(), devices: Array(Set(outputs)).sorted(), outputUID: defaultOutputUID())
    }

    private static func objectIDs(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? ids : []
    }

    private static func stringProperty(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
