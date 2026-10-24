import AudioToolbox
import CoreAudio
import Foundation
import os
import RhythmKit

private let log = Logger(subsystem: "StreamDock", category: "AudioTap")

/// Live rhythm analysis of the Music app's own output — not the microphone, not other apps —
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

    func start(pid: pid_t) {
        control.async { [self] in
            guard procID == nil else { return }
            let started = startNow(pid: pid)
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
            pendingEvents.removeAll()
            latestSnapshot = RhythmSnapshot()
            lock.unlock()
        }
    }

    private func startNow(pid: pid_t) -> Bool {
        guard let process = Self.processObject(for: pid) else {
            log.notice("Music (pid \(pid)) has no audio process object yet")
            return false
        }

        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else {
            log.error("Creating the process tap failed: \(status)")
            return false
        }
        tapID = tap

        var aggregateDescription: [String: Any] = [
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
        // Clock the aggregate from the current output device, as Apple's sample does.
        if let outputUID = Self.defaultOutputUID() {
            aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
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
        if AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            ioQueue.sync { sampleRate = format.mSampleRate }
        }
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
        if let seconds = UserDefaults.standard.object(forKey: "rhythmTraceSeconds") as? Double, seconds > 0 {
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
        guard let extractor, let analyzer else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        // Mix down to mono (interleaved or one buffer per channel).
        mono.removeAll(keepingCapacity: true)
        var energy: Float = 0
        for (index, buffer) in buffers.enumerated() {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let samples = data.assumingMemoryBound(to: Float32.self)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size / channels
            if index == 0 { mono = [Float](repeating: 0, count: frames) }
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
        pendingEvents += events
        latestSnapshot = analyzer.snapshot
        if sqrt(energy / Float(mono.count)) > 0.0005 { lastSignal = now }
        lock.unlock()
    }

    // MARK: - Helpers

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
