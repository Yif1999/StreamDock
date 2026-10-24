import Foundation

/// Real-time beat tracking with a cumulative score (Ellis 2007; Stark et al., BTrack):
///
///   C(t) = (1 − α)·O(t) + α · max_v W(t − v)·C(v),   v ∈ [t − 2τ, t − τ/2]
///
/// where W is a log-Gaussian around one beat period τ. Half-way through each beat the score
/// is projected forward (with no new onsets) and weighted by a Gaussian around the expected
/// beat; its maximum is the predicted next beat. Phase comes from the data, not from rules.
struct BeatTracker {
    let frameRate: Double
    let alpha = 0.9
    /// Tightness of W: larger means stricter about the beat period.
    let tightness = 5.0

    private var scores: [Double] = []
    private var frameIndex = 0
    private var lastBeatFrame: Int?
    private var predictedFrame: Int?

    init(frameRate: Double) {
        self.frameRate = frameRate
    }

    /// Feeds one onset value with the current period (frames); returns the frame index of a
    /// newly predicted beat, if this frame produced one (it lies in the future).
    mutating func push(onset: Double, periodFrames tau: Double) -> Int? {
        let frame = frameIndex
        let score = (1 - alpha) * onset + alpha * bestPast(at: frame, tau: tau, scores: scores, offset: scoreOffset)
        scores.append(score)
        frameIndex += 1
        let capacity = Int(4 * tau) + 4
        if scores.count > capacity {
            scores.removeFirst(scores.count - capacity)
        }

        // The predicted beat has arrived: it becomes the last beat.
        if let predicted = predictedFrame, frame >= predicted {
            lastBeatFrame = predicted
            predictedFrame = nil
        }
        if lastBeatFrame == nil, scores.count > Int(2 * tau) {
            // Start from the strongest recent score.
            let recent = scores.suffix(Int(tau))
            let best = recent.indices.max { recent[$0] < recent[$1] }!
            lastBeatFrame = best + scoreOffset
        }
        guard predictedFrame == nil, let last = lastBeatFrame, Double(frame - last) >= tau / 2 else { return nil }
        let prediction = predict(tau: tau, lastBeat: last, now: frame)
        predictedFrame = prediction
        return prediction
    }

    /// Absolute frame of `scores[0]` (the newest score is frame `frameIndex − 1`).
    private var scoreOffset: Int { frameIndex - scores.count }

    private func bestPast(at frame: Int, tau: Double, scores: [Double], offset: Int) -> Double {
        var best = 0.0
        let nearest = max(1, Int((tau / 2).rounded()))
        let farthest = Int((2 * tau).rounded())
        guard farthest >= nearest else { return 0 }
        for distance in nearest...farthest {
            let index = frame - distance - offset
            guard index >= 0, index < scores.count else { continue }
            let weight = exp(-0.5 * pow(tightness * log(Double(distance) / tau), 2))
            best = max(best, weight * scores[index])
        }
        return best
    }

    /// Projects the score forward with no new onsets and picks the most likely next beat.
    private func predict(tau: Double, lastBeat: Int, now: Int) -> Int {
        var future = scores
        let offset = scoreOffset
        let expected = Double(lastBeat) + tau
        let spread = tau / 6
        var best = (frame: Int(expected.rounded()), value: -Double.infinity)
        let horizon = Int((1.5 * tau).rounded())
        for step in 1...max(1, horizon) {
            let frame = now + step
            let value = alpha * bestPast(at: frame, tau: tau, scores: future, offset: offset)
            future.append(value)
            let gaussian = exp(-0.5 * pow((Double(frame) - expected) / spread, 2))
            if value * gaussian > best.value { best = (frame, value * gaussian) }
        }
        return max(best.frame, now + 1)
    }

    mutating func reset() {
        lastBeatFrame = nil
        predictedFrame = nil
    }

    /// The frame the next `push` will be.
    var nextFrame: Int { frameIndex }
}
