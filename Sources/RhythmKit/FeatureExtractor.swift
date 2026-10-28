import Accelerate
import Foundation

/// Turns mono audio into `FeatureFrame`s: FFT (1024, hop 512, Hann), spectral flux per band
/// and band loudness.
///
/// Two fluxes per band: `flux` rises in log-compressed magnitude, normalised by the band's
/// mean — level-independent, for finding hits; `rawFlux` rises in linear magnitude — scales
/// with the level, for sizing them (a passage at 30 % volume gives 30 % raw flux).
public final class FeatureExtractor {
    public static let frameSize = 1024
    public static let hopSize = 512
    /// Band edges in Hz, end to end. Mid runs to 6 kHz so it holds a snare's crack and wires
    /// (2–6 kHz), its most telling part, and high starts above them: from 2.5 kHz high fell on
    /// the snares' own beats instead of the hi-hats' (`dock-probe bandcompare`, 2026-10-27).
    public static let bandEdges: [(Bands.Band, ClosedRange<Double>)] = [
        (.low, 30...150), (.mid, 150...6000), (.high, 6000...16000),
    ]
    /// Finer bands, recorded alongside for offline study of how to split the spectrum
    /// (`BandComparison`): kick and bass, a snare's body, the middle, a snare's wires and crack,
    /// cymbals. Not used by the live analysis, so only worked out while `computesDetail` (a trace
    /// recording).
    public static let detailEdges: [ClosedRange<Double>] = [30...150, 150...400, 400...2000, 2000...6000, 6000...16000]
    /// Log compression strength, Y = log(1 + γ·|X|).
    static let compression: Float = 1000

    public let sampleRate: Double
    /// Whether frames carry the detail bands (`detailEdges`).
    public var computesDetail = true
    public var frameRate: Double { sampleRate / Double(Self.hopSize) }
    /// How many FFT bins each band spans.
    public var binCounts: Bands { Self.binCounts(sampleRate: sampleRate) }

    public static func binCounts(sampleRate: Double) -> Bands {
        var counts = Bands()
        for (band, bins) in bins(edges: bandEdges.map(\.1), sampleRate: sampleRate).enumerated().map({ (bandEdges[$0].0, $1) }) {
            counts[band] = Double(bins.count)
        }
        return counts
    }

    static func bins(edges: [ClosedRange<Double>], sampleRate: Double) -> [Range<Int>] {
        let binWidth = sampleRate / Double(frameSize)
        return edges.map { range in
            let first = max(1, Int((range.lowerBound / binWidth).rounded(.up)))
            let last = min(frameSize / 2 - 1, Int((range.upperBound / binWidth).rounded(.down)))
            return first..<max(first + 1, last + 1)
        }
    }

    private let log2n = vDSP_Length(10)
    private let fftSetup: FFTSetup
    private let window: [Float]
    private var buffer: [Float] = []
    private var previousLog: [Float]?
    private var previousMagnitudes: [Float]?
    private var bandBins: [(Bands.Band, Range<Int>)] = []
    private var detailBins: [Range<Int>] = []
    private var detailScale: [AdaptiveScale] = []

    private var fluxScale: [Bands.Band: AdaptiveScale] = [:]
    private var loudnessScale: [Bands.Band: AdaptiveScale] = [:]

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.frameSize, isHalfWindow: false)
        bandBins = Array(zip(Self.bandEdges.map(\.0), Self.bins(edges: Self.bandEdges.map(\.1), sampleRate: sampleRate)))
        detailBins = Self.bins(edges: Self.detailEdges, sampleRate: sampleRate)
        detailScale = Self.detailEdges.map { _ in AdaptiveScale(.mean, seconds: 10, floor: 1e-3) }
        for band in Bands.Band.allCases {
            fluxScale[band] = AdaptiveScale(.mean, seconds: 10, floor: 1e-3)
            loudnessScale[band] = AdaptiveScale(.peak, seconds: 50, floor: 1e-5)
        }
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Feeds samples whose last one plays at `endTime`; returns the frames completed.
    public func process(_ samples: UnsafeBufferPointer<Float>, endTime: Double) -> [FeatureFrame] {
        buffer.append(contentsOf: samples)
        var frames: [FeatureFrame] = []
        let hop = Self.hopSize, size = Self.frameSize
        // Samples still waiting after each frame tell us how far before `endTime` it ends.
        while buffer.count >= size {
            let remaining = buffer.count - size
            let time = endTime - Double(remaining) / sampleRate
            frames.append(analyze(Array(buffer[0..<size]), time: time))
            buffer.removeFirst(hop)
        }
        return frames
    }

    private func analyze(_ samples: [Float], time: Double) -> FeatureFrame {
        let size = Self.frameSize
        let windowed = vDSP.multiply(samples, window)
        var real = [Float](repeating: 0, count: size / 2)
        var imaginary = [Float](repeating: 0, count: size / 2)
        var magnitudes = [Float](repeating: 0, count: size / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))
            }
        }
        // vDSP's real FFT is scaled by 2; normalise to the frame length.
        vDSP.multiply(1 / Float(size), magnitudes, result: &magnitudes)
        let logMagnitudes = magnitudes.map { log1pf(Self.compression * $0) }

        let dt = Double(Self.hopSize) / sampleRate
        var flux = Bands(), rawFlux = Bands(), loudness = Bands(), energyNow = Bands()
        for (band, bins) in bandBins {
            var rise: Float = 0, linearRise: Float = 0, energy: Float = 0
            for bin in bins {
                if let previous = previousLog { rise += max(0, logMagnitudes[bin] - previous[bin]) }
                if let previous = previousMagnitudes { linearRise += max(0, magnitudes[bin] - previous[bin]) }
                energy += magnitudes[bin] * magnitudes[bin]
            }
            let rms = sqrt(Double(energy) / Double(bins.count))
            // The first frame has nothing to rise from; keep it out of the flux scale.
            if previousLog != nil {
                rawFlux[band] = Double(linearRise) / Double(bins.count)
                flux[band] = fluxScale[band]!.normalize(Double(rise) / Double(bins.count), dt: dt)
            }
            loudness[band] = min(1, loudnessScale[band]!.normalize(rms, dt: dt))
            energyNow[band] = Double(energy)
        }
        var detail: [Double] = [], detailRaw: [Double] = []
        if computesDetail, let previousLog, let previousMagnitudes {
            for (index, bins) in detailBins.enumerated() {
                var rise: Float = 0, linearRise: Float = 0
                for bin in bins {
                    rise += max(0, logMagnitudes[bin] - previousLog[bin])
                    linearRise += max(0, magnitudes[bin] - previousMagnitudes[bin])
                }
                detail.append(detailScale[index].normalize(Double(rise) / Double(bins.count), dt: dt))
                detailRaw.append(Double(linearRise) / Double(bins.count))
            }
        }
        previousLog = logMagnitudes
        previousMagnitudes = magnitudes

        let weights = FeatureFrame.onsetWeights
        let onset = weights.low * flux.low + weights.mid * flux.mid + weights.high * flux.high
        var frame = FeatureFrame(time: time, flux: flux, rawFlux: rawFlux, onset: onset, loudness: loudness)
        frame.energy = energyNow
        frame.detail = detail
        frame.detailRaw = detailRaw
        return frame
    }
}
