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
    /// Band edges in Hz.
    public static let bandEdges: [(Bands.Band, ClosedRange<Double>)] = [
        (.low, 30...150), (.mid, 150...2500), (.high, 2500...11000),
    ]
    /// Log compression strength, Y = log(1 + γ·|X|).
    static let compression: Float = 1000

    public let sampleRate: Double
    public var frameRate: Double { sampleRate / Double(Self.hopSize) }

    private let log2n = vDSP_Length(10)
    private let fftSetup: FFTSetup
    private let window: [Float]
    private var buffer: [Float] = []
    private var previousLog: [Float]?
    private var previousMagnitudes: [Float]?
    private var bandBins: [(Bands.Band, Range<Int>)] = []

    private var fluxScale: [Bands.Band: AdaptiveScale] = [:]
    private var loudnessScale: [Bands.Band: AdaptiveScale] = [:]

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.frameSize, isHalfWindow: false)
        let binWidth = sampleRate / Double(Self.frameSize)
        bandBins = Self.bandEdges.map { band, range in
            let first = max(1, Int((range.lowerBound / binWidth).rounded(.up)))
            let last = min(Self.frameSize / 2 - 1, Int((range.upperBound / binWidth).rounded(.down)))
            return (band, first..<max(first + 1, last + 1))
        }
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
        var flux = Bands(), rawFlux = Bands(), loudness = Bands()
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
        }
        previousLog = logMagnitudes
        previousMagnitudes = magnitudes

        let weights = FeatureFrame.onsetWeights
        let onset = weights.low * flux.low + weights.mid * flux.mid + weights.high * flux.high
        return FeatureFrame(time: time, flux: flux, rawFlux: rawFlux, onset: onset, loudness: loudness)
    }
}
