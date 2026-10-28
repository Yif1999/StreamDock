import Foundation

/// Tracks a signal's typical level so values can be expressed relative to it. The one
/// normalisation mechanism in RhythmKit; every time constant is chosen where it is created.
public struct AdaptiveScale: Sendable {
    public enum Mode: Sendable {
        /// Running mean with time constant `seconds`.
        case mean
        /// Running peak that halves every `seconds`.
        case peak
    }

    public let mode: Mode
    public let seconds: Double
    public let floor: Double
    public private(set) var level: Double?
    /// Time observed so far; until it reaches `seconds` the mean is the plain average of
    /// everything seen (bias-corrected), instead of creeping up from the first sample.
    private var elapsed = 0.0

    public init(_ mode: Mode, seconds: Double, floor: Double) {
        self.mode = mode
        self.seconds = seconds
        self.floor = floor
    }

    /// Updates with a new sample `dt` seconds after the previous one; returns value / level.
    public mutating func normalize(_ value: Double, dt: Double) -> Double {
        switch (mode, level) {
        case (_, nil):
            level = value
        case (.mean, let current?):
            elapsed += dt
            let window = min(seconds, elapsed + dt)
            level = current + (value - current) * (1 - exp(-dt / window))
        case (.peak, let current?):
            level = max(value, current * pow(0.5, dt / seconds))
        }
        return value / max(level ?? value, floor)
    }
}

/// A value per frequency band.
public struct Bands: Sendable, Equatable {
    public var low: Double
    public var mid: Double
    public var high: Double

    public init(low: Double = 0, mid: Double = 0, high: Double = 0) {
        self.low = low
        self.mid = mid
        self.high = high
    }

    public enum Band: String, Sendable, CaseIterable {
        case low, mid, high
    }

    public subscript(band: Band) -> Double {
        get {
            switch band {
            case .low: low
            case .mid: mid
            case .high: high
            }
        }
        set {
            switch band {
            case .low: low = newValue
            case .mid: mid = newValue
            case .high: high = newValue
            }
        }
    }
}

/// One analysis frame (≈10.7 ms at 48 kHz).
public struct FeatureFrame: Sendable, Equatable {
    /// Seconds on the system uptime clock (`ProcessInfo.systemUptime`).
    public var time: Double
    /// Spectral flux per band, relative to the band's own recent mean (≈1 on average) — for
    /// finding hits whatever the level.
    public var flux: Bands
    /// The same flux before that normalisation — keeps how loud a hit really is, for sizing.
    public var rawFlux: Bands
    /// Onset detection function: weighted sum of `flux`.
    public var onset: Double
    /// Loudness per band, relative to its recent peak (0...1).
    public var loudness: Bands
    /// Each band's energy as it is (sum of squared magnitudes over its bins) — comparable
    /// between bands, for how much of the mix each one holds (`BandShares`). 0 when not known.
    public var energy = Bands()
    /// Flux (normalised, like `flux`) and raw flux in `FeatureExtractor.detailEdges`, for
    /// offline study only; empty when not measured.
    public var detail: [Double] = []
    public var detailRaw: [Double] = []

    public init(time: Double, flux: Bands, rawFlux: Bands? = nil, onset: Double, loudness: Bands) {
        self.time = time
        self.flux = flux
        self.rawFlux = rawFlux ?? flux
        self.onset = onset
        self.loudness = loudness
    }

    public static let onsetWeights = Bands(low: 1.0, mid: 0.8, high: 0.5)
}
