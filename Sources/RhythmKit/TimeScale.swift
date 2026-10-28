import Foundation

/// The analysis' three time scales. Every reference it keeps looks back one of these, so each
/// measure answers one of three questions, the same way in every band (2026-10-28: eight
/// windows from 0.5 s to 60 s had grown up, one per rule).
public enum TimeScale {
    /// What is sounding now: a hit's threshold, how much of the mix each band holds, the
    /// low end held under its hits.
    public static let now = 1.0
    /// The passage: ranking a hit among its band's recent ones, what rises out of the low end,
    /// the flux's usual level.
    public static let context = 8.0
    /// The song: how big a hit is against the band's big ones, how loud a band gets, how busy
    /// the song usually is.
    public static let song = 60.0
}

/// One ranking for every "is this among the heaviest right now" — heavy low and mid hits, the
/// accents — and one spacing between them.
enum Ranking {
    /// Hits within `tie` of each other rank as equals, counted half below and half above — the
    /// usual way with ties: a backbeat of equally hard snares ranks together instead of only
    /// the few that came out a hair bigger, while a run of equal light hits under a few heavy
    /// ones still ranks low (2026-10-28: a drum loop flashed on 1–2 of its 8 snares).
    static let tie = 0.1
    /// The top `top` of the last `TimeScale.context` are the heaviest; with fewer than `warmUp`
    /// others to rank against, nothing is. (0.25 keeps the heavy hits the light was tuned on:
    /// they had ranked the hit itself above itself, at 0.3 — 2026-10-28, six songs within ±10 %.)
    static let top = 0.25, warmUp = 5
    /// At most one per half beat (within `gapRange`; `defaultGap` with no tempo): a flash marks
    /// the heaviest hit, several a beat read as strobing.
    static let defaultGap = 0.25, gapRange = 0.2...0.35

    /// Where `size` stands among the `others` (the hit itself not among them): the fraction of
    /// them below it, 0 below them all, 1 above them all.
    static func rank(_ size: Double, among others: [Double]) -> Double {
        guard !others.isEmpty else { return 0 }
        let below = others.filter { $0 * (1 + tie) < size }.count
        let level = others.filter { abs($0 - size) <= tie * max($0, size) }.count
        return (Double(below) + 0.5 * Double(level)) / Double(others.count)
    }

    /// Among the heaviest: in the top `top` (or the fraction given) of the `others`.
    static func isHeavy(_ size: Double, among others: [Double], top: Double = Ranking.top) -> Bool {
        others.count >= warmUp && rank(size, among: others) >= 1 - top
    }

    static func gap(beatPeriod: Double?) -> Double {
        beatPeriod.map { min(gapRange.upperBound, max(gapRange.lowerBound, $0 / 2)) } ?? defaultGap
    }
}
