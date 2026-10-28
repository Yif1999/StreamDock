import Foundation

/// A hit in one band: a peak of that band's flux.
public struct Hit: Sendable, Equatable {
    public let time: Double
    public let band: Bands.Band
    /// The flux at the peak (relative to the band's recent mean, so ≈2–10 for clear hits).
    public let strength: Double
    /// The un-normalised flux at the peak: how loud the hit really is.
    public let magnitude: Double

    public init(time: Double, band: Bands.Band, strength: Double, magnitude: Double? = nil) {
        self.time = time
        self.band = band
        self.strength = strength
        self.magnitude = magnitude ?? strength
    }
}

/// Finds hits in one band's flux: a local maximum over ±`halfWidth` frames, above the last
/// second's mean + `deviations`·σ and at least `floor` (flux is relative to the band's
/// long-run mean, so 2 = twice the usual), at least `minimumInterval` after the previous hit.
/// Reports each peak `halfWidth` frames late (it needs to see past it).
struct PeakPicker {
    let band: Bands.Band
    let minimumInterval: Double
    let deviations: Double
    let halfWidth: Int
    let windowFrames: Int
    /// Ignore peaks below this flux (silence, noise floor).
    let floor: Double

    private var recent: [(time: Double, value: Double, raw: Double)] = []
    private var lastHit = -Double.infinity

    init(band: Bands.Band, frameRate: Double, minimumInterval: Double, deviations: Double = 1.5, floor: Double = 2) {
        self.band = band
        self.minimumInterval = minimumInterval
        self.deviations = deviations
        self.floor = floor
        halfWidth = 3
        windowFrames = Int(frameRate)
    }

    mutating func push(time: Double, value: Double, raw: Double? = nil) -> Hit? {
        recent.append((time, value, raw ?? value))
        if recent.count > windowFrames { recent.removeFirst(recent.count - windowFrames) }
        guard recent.count > 2 * halfWidth else { return nil }

        let centerIndex = recent.count - 1 - halfWidth
        let center = recent[centerIndex]
        let neighbourhood = recent[(centerIndex - halfWidth)...(centerIndex + halfWidth)]
        guard neighbourhood.allSatisfy({ $0.value <= center.value }) else { return nil }

        let values = recent.map(\.value)
        let mean = values.reduce(0, +) / Double(values.count)
        let deviation = sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count))
        guard center.value > max(floor, mean + deviations * deviation),
              center.time - lastHit >= minimumInterval
        else { return nil }
        lastHit = center.time
        // Its size: the raw rise over the peak frame and the ones either side. A hit's rise falls
        // into one frame or splits over two, as it lands against the 512-sample hops; one frame
        // alone sized the same snare anywhere from 0.4 to 1 of the others (2026-10-28).
        let raw = recent[(centerIndex - 1)...(centerIndex + 1)].reduce(0) { $0 + $1.raw }
        return Hit(time: center.time, band: band, strength: center.value, magnitude: raw)
    }
}
