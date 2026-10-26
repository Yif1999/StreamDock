import Foundation
import os
import RhythmKit

private let log = Logger(subsystem: "StreamDock", category: "RhythmTrace")

/// Debug recording of rhythm features and tapped beats for offline tuning
/// (`dock-probe rhythm-eval`). Off unless started; keeps feature values only, never audio.
///
/// Start with `defaults write dev.yif.StreamDock rhythmTraceSeconds 180`; tap along on the
/// general scene's beat key while it records.
final class RhythmRecorder: @unchecked Sendable {
    static let shared = RhythmRecorder()

    private let lock = NSLock()
    private var lines: [String] = []
    private var until: TimeInterval?
    private var frameRate = 48_000.0 / Double(FeatureExtractor.hopSize)

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return until != nil
    }

    /// Starts recording; `note` (what is playing, from where) goes at the top of the trace.
    func start(seconds: Double, frameRate: Double, note: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard until == nil else { return }
        self.frameRate = frameRate
        lines = [RhythmTrace.header(frameRate: frameRate)] + (note.map { [RhythmTrace.noteLine($0)] } ?? [])
        until = ProcessInfo.processInfo.systemUptime + seconds
        log.notice("Recording rhythm trace for \(Int(seconds)) s")
    }

    func record(_ frame: FeatureFrame) {
        lock.lock()
        guard let end = until else {
            lock.unlock()
            return
        }
        lines.append(RhythmTrace.frameLine(frame))
        let finished = frame.time >= end
        let output = finished ? lines : nil
        if finished {
            until = nil
            lines = []
        }
        lock.unlock()
        if let output { write(output) }
    }

    func tap(at time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard until != nil else { return }
        lines.append(RhythmTrace.tapLine(time))
    }

    private func write(_ lines: [String]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("streamdock-rhythm-trace.txt")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            log.notice("Rhythm trace written to \(url.path, privacy: .public) (\(lines.count) lines)")
        } catch {
            log.error("Writing rhythm trace failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
