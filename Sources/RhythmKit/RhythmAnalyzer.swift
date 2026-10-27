import Foundation

public enum RhythmState: String, Sendable {
    /// Smooth music with no rhythm to show.
    case calm
    /// Rhythmic, but no steady tempo yet: accents only, no beat grid.
    case seeking
    /// Steady tempo: accents plus the tracker's predicted beat grid.
    case locked
}

public enum RhythmEvent: Sendable, Equatable {
    /// A beat of the steady grid expected at `time` (locked only), announced about half a beat
    /// ahead so a soft pulse can peak right on it. Keeps the groove; not an accent.
    case expectedBeat(time: Double)
    /// One of the strongest hits right now (see `SalienceDetector`), on the grid or not.
    /// `strength` 0...1 is its size against the song's big hits of the last minute.
    case accent(time: Double, strength: Double)
    /// Every hit in every band, for secondary effects (blob kicks, sparks).
    case hit(Hit)
    /// One of the heaviest low-band hits right now (see `HeavyHits`); `strength` 0...1
    /// against the low band's big hits of the last minute.
    case kick(time: Double, strength: Double)
    /// A mid (snare, any mid onset) or high (cymbal) hit, sized against its own band's big hits
    /// of the last minute (≈1 for a big one; quiet passages give small ones), for the light to
    /// lift on. Each band stands on its own: nothing is held back to tell a kick from a snare.
    /// `heavy`: a mid hit among the band's heaviest right now (`HeavyHits`, like the kicks) —
    /// the light flashes on those and only glows on the rest.
    case lift(time: Double, band: Bands.Band, strength: Double, heavy: Bool)

    /// When it happened (for an expected beat, when it is due).
    public var time: Double {
        switch self {
        case .expectedBeat(let time), .accent(let time, _), .kick(let time, _), .lift(let time, _, _, _): time
        case .hit(let hit): hit.time
        }
    }
}

public struct RhythmSnapshot: Sendable, Equatable {
    public var state: RhythmState = .calm
    public var bpm: Double?
    /// Periodicity confidence of the current tempo, 0...1.
    public var confidence = 0.0
    /// Low/mid hitting over the last 2 s relative to the song's typical busy level (≈1 in a
    /// chorus, 0 in a passage with no hits).
    public var activity = 0.0
    /// How strongly visuals should follow the rhythm, 0...1 (eased).
    public var intensity = 0.0
    public var loudness = Bands()
    /// How hard the low end (kick and bass) is drawing right now, 0...1 (see `LowDraw`).
    public var lowDraw = 0.0

    public init() {}
}

/// Feature frames in, rhythm events out. See docs/rhythm.md for the design.
public final class RhythmAnalyzer {
    // State machine thresholds (with hysteresis).
    static let calmBelow = 0.3, calmFor = 1.5, wakeAbove = 0.45
    static let lockConfidence = 0.25, lockVotes = 2
    static let unlockConfidence = 0.12, unlockAfter = 3.0
    /// Grid beats are only announced when the beat is this reliable, so an unsure grid never
    /// pulses in between the accents.
    static let gridConfidence = 0.3

    public let frameRate: Double
    public private(set) var snapshot = RhythmSnapshot()
    /// Whether to report the accents and the beat grid (`.accent`, `.expectedBeat`): the light
    /// no longer plays them, only the offline evaluation (`dock-probe rhythm-eval`) does, so the
    /// live analysis turns them off and spares their work. Tempo, state and intensity run either way.
    public var reportsBeats = true

    private var pickers: [PeakPicker]
    private var tempo: TempoEstimator
    private var tracker: BeatTracker
    private var salience = SalienceDetector()
    private var kicks = HeavyHits()
    private var heavyMids = HeavyHits()
    private var references: [Bands.Band: BandReference] = [.low: BandReference(), .mid: BandReference(), .high: BandReference()]
    private var draw = LowDraw()
    private var framesSinceAnalysis = 0

    /// Low/mid hits of the last 2 s (time, strength).
    private var recentHits: [(time: Double, strength: Double)] = []
    private var activityHistory: [Double] = []
    private var calmSince: Double?
    private var lockVotes = 0
    private var weakSince: Double?

    private var lastFrameTime: Double?

    public init(frameRate: Double) {
        self.frameRate = frameRate
        pickers = [
            PeakPicker(band: .low, frameRate: frameRate, minimumInterval: 0.08),
            PeakPicker(band: .mid, frameRate: frameRate, minimumInterval: 0.08),
            PeakPicker(band: .high, frameRate: frameRate, minimumInterval: 0.12),
        ]
        tempo = TempoEstimator(frameRate: frameRate)
        tracker = BeatTracker(frameRate: frameRate)
    }

    public func process(_ frame: FeatureFrame) -> [RhythmEvent] {
        let dt = lastFrameTime.map { min(0.1, max(0, frame.time - $0)) } ?? 1 / frameRate
        lastFrameTime = frame.time
        snapshot.loudness = frame.loudness
        draw.push(time: frame.time, level: frame.loudness.low)
        snapshot.lowDraw = draw.value
        var events: [RhythmEvent] = []

        // Hits in every band.
        var hits: [Hit] = []
        for index in pickers.indices {
            let band = pickers[index].band
            if let hit = pickers[index].push(time: frame.time, value: frame.flux[band], raw: frame.rawFlux[band]) { hits.append(hit) }
        }
        events += hits.map(RhythmEvent.hit)

        // Tempo, activity and state, twice a second.
        tempo.push(frame.onset)
        recentHits += hits.filter { $0.band != .high }.map { ($0.time, $0.strength) }
        recentHits.removeAll { $0.time < frame.time - 2 }
        framesSinceAnalysis += 1
        if framesSinceAnalysis >= Int(frameRate / 2) {
            framesSinceAnalysis = 0
            tempo.analyze()
            updateState(now: frame.time)
        }

        // Beat grid: the tracker runs whenever there is a tempo so its score stays continuous.
        if reportsBeats, let period = tempo.period {
            let current = tracker.nextFrame
            if let predicted = tracker.push(onset: frame.onset, periodFrames: period * frameRate),
               snapshot.state == .locked, snapshot.confidence >= Self.gridConfidence {
                events.append(.expectedBeat(time: frame.time + Double(predicted - current) / frameRate))
            }
        }

        // Accents: the strongest low/mid strikes, in any state (intensity scales them).
        let beatPeriod = snapshot.confidence >= Self.unlockConfidence ? tempo.period : nil
        salience.beatPeriod = beatPeriod
        kicks.beatPeriod = beatPeriod
        heavyMids.beatPeriod = beatPeriod
        for hit in hits {
            if reportsBeats, let accent = salience.push(hit) { events.append(.accent(time: accent.time, strength: accent.strength)) }
            // Each band on its own: low hits are kicks, mid and high hits lift.
            let size = references[hit.band]!.size(of: hit)
            if hit.band == .low {
                if let strength = kicks.push(time: hit.time, size: size) { events.append(.kick(time: hit.time, strength: strength)) }
            } else {
                let heavy = hit.band == .mid && heavyMids.push(time: hit.time, size: size) != nil
                events.append(.lift(time: hit.time, band: hit.band, strength: min(1, size), heavy: heavy))
            }
        }

        let target = snapshot.state == .calm ? 0 : Self.smoothstep((snapshot.activity - Self.calmBelow) / 0.4)
        snapshot.intensity += (target - snapshot.intensity) * (1 - exp(-dt / 1.0))
        return events
    }

    // MARK: - Activity and state

    private func updateState(now: Double) {
        // Activity: low/mid hitting in the last 2 s against the 75th percentile of that over the
        // last minute.
        let hitting = recentHits.reduce(0) { $0 + $1.strength }
        activityHistory.append(hitting)
        if activityHistory.count > 120 { activityHistory.removeFirst() }
        if activityHistory.count >= 8 {
            let sorted = activityHistory.sorted()
            let typical = sorted[Int(Double(sorted.count - 1) * 0.75)]
            snapshot.activity = hitting / max(typical, 1)
        } else {
            snapshot.activity = 1
        }
        snapshot.confidence = tempo.confidence
        snapshot.bpm = tempo.period.map { 60 / $0 }

        // Calm ⇄ active.
        if snapshot.activity < Self.calmBelow {
            calmSince = calmSince ?? now
        } else {
            calmSince = nil
        }
        if snapshot.state != .calm, let since = calmSince, now - since >= Self.calmFor {
            snapshot.state = .calm
            lockVotes = 0
            tracker.reset()
            return
        }
        if snapshot.state == .calm {
            guard snapshot.activity >= Self.wakeAbove else { return }
            snapshot.state = .seeking
        }

        // Seeking ⇄ locked.
        switch snapshot.state {
        case .seeking:
            lockVotes = tempo.confidence >= Self.lockConfidence && tempo.period != nil ? lockVotes + 1 : 0
            if lockVotes >= Self.lockVotes {
                snapshot.state = .locked
                weakSince = nil
            }
        case .locked:
            if tempo.confidence < Self.unlockConfidence {
                weakSince = weakSince ?? now
                if now - weakSince! >= Self.unlockAfter {
                    snapshot.state = .seeking
                    lockVotes = 0
                }
            } else {
                weakSince = nil
            }
        case .calm:
            break
        }
    }

    static func smoothstep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }
}
