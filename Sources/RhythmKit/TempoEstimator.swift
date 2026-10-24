import Accelerate
import Foundation

/// Estimates the beat period from the onset function: autocorrelation of the last
/// `historySeconds`, a comb template over its first four multiples, and a log-Gaussian tempo
/// prior around 120 BPM (as in Ellis 2007). Periodicity confidence is the biased
/// (standard) autocorrelation r(τ) = Σx_t·x_{t−τ} / Σx_t², which stays within −1…1.
struct TempoEstimator {
    let frameRate: Double
    let historySeconds = 6.0
    let minBPM = 60.0, maxBPM = 200.0
    /// Prior centre and width (octaves).
    let priorPeriod = 0.5, priorWidth = 0.9

    private var onsets: [Double] = []
    private(set) var period: Double?
    private(set) var confidence = 0.0
    /// A different tempo that won the last analysis; a jump needs two wins in a row.
    private var challenger: Double?

    init(frameRate: Double) {
        self.frameRate = frameRate
    }

    mutating func push(_ onset: Double) {
        onsets.append(onset)
        let capacity = Int(historySeconds * frameRate)
        if onsets.count > capacity { onsets.removeFirst(onsets.count - capacity) }
    }

    var hasEnoughHistory: Bool { onsets.count >= Int(historySeconds * frameRate * 0.75) }

    /// Re-estimates tempo and confidence from the buffered onsets.
    mutating func analyze() {
        guard hasEnoughHistory else { return }
        let mean = onsets.reduce(0, +) / Double(onsets.count)
        let signal = onsets.map { Float($0 - mean) }
        let count = signal.count
        let minLag = Int((frameRate * 60 / maxBPM).rounded(.down))
        let maxLag = Int((frameRate * 60 / minBPM).rounded(.up))
        let longestLag = min(count - 1, 4 * maxLag)

        // Autocorrelation: unbiased (per overlapping sample) for scoring tempo candidates
        // fairly across lags; biased (standard) for the confidence value.
        var correlation = [Double](repeating: 0, count: longestLag + 1)
        var biased = [Double](repeating: 0, count: longestLag + 1)
        signal.withUnsafeBufferPointer { pointer in
            for lag in 0...longestLag {
                var sum: Float = 0
                vDSP_dotpr(pointer.baseAddress!, 1, pointer.baseAddress! + lag, 1, &sum, vDSP_Length(count - lag))
                correlation[lag] = Double(sum) / Double(count - lag)
                biased[lag] = Double(sum)
            }
        }
        guard correlation[0] > 1e-9 else {
            confidence = 0
            return
        }
        let zero = correlation[0], biasedZero = biased[0]
        for lag in correlation.indices {
            correlation[lag] /= zero
            biased[lag] /= biasedZero
        }

        func comb(_ lag: Int) -> Double {
            var score = 0.0
            for multiple in 1...4 where multiple * lag <= longestLag {
                score += correlation[multiple * lag] / Double(multiple)
            }
            return score
        }
        func prior(_ lag: Int) -> Double {
            let period = Double(lag) / frameRate
            return exp(-0.5 * pow(log2(period / priorPeriod) / priorWidth, 2))
        }
        var best = (lag: minLag, score: -Double.infinity)
        for lag in minLag...maxLag {
            let score = comb(lag) * prior(lag)
            if score > best.score { best = (lag, score) }
        }
        confidence = max(0, biased[best.lag])

        // Sub-frame period by parabolic interpolation of the weighted comb score.
        var lag = Double(best.lag)
        if best.lag > minLag, best.lag < maxLag {
            let left = comb(best.lag - 1) * prior(best.lag - 1)
            let right = comb(best.lag + 1) * prior(best.lag + 1)
            let denominator = left - 2 * best.score + right
            if abs(denominator) > 1e-12 { lag += 0.5 * (left - right) / denominator }
        }
        let estimate = lag / frameRate

        guard let current = period else {
            period = estimate
            return
        }
        if abs(estimate - current) / current < 0.04 {
            period = current * 0.7 + estimate * 0.3
            challenger = nil
        } else if let previous = challenger, abs(estimate - previous) / previous < 0.04 {
            period = estimate
            challenger = nil
        } else {
            challenger = estimate
        }
    }
}
