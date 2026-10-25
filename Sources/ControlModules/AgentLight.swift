import DockCore
import Foundation

/// The light strip's language for Codex and Claude in the VibeCoding scene (docs/design.md,
/// 灯带提醒): the color says who, the motion says what, speed and brightness say how urgent.
/// Each motion here only decides how bright each LED is at a moment; colors come from outside.
/// Everything is computed from elapsed time, never from frame counts.
///
/// Single LEDs read as grains, so nothing that moves is narrower than about three LEDs: every
/// moving light has a lit core, a soft edge ahead and a long fading tail behind. Nothing switches
/// either: every change of brightness eases down and up, however quick (a light rises out of its
/// surroundings; the fault flicker is a pair of smooth dips, not on/off steps). A strong motion
/// and its quiet version are one curve played at two speeds and brightnesses (the quiet summon
/// just leaves the short bars out).
public enum AgentLight {
    /// The apps' colors on the strip, tuned on the device (2026-10-25): Codex a periwinkle blue,
    /// Claude a full orange. Brighter and softer than the key meter colors on purpose.
    public static func color(for service: AIService) -> RGB {
        service == .codex ? RGB(hex: "#7891FF") : RGB(hex: "#FF6900")
    }

    public enum Motion: Sendable {
        /// Working (weak, ambient): a wide comet with a long fading tail laps the ring.
        case cruise
        /// Done (one-shot, then `hold`): the comet speeds up until its tail closes the ring.
        case close
        /// Done, waiting to be looked at (weak): the whole ring, still, barely breathing.
        case hold
        /// Failed (one-shot, then `fault`): the comet stops and swells into the whole ring, which
        /// dips twice like a failing lamp, then settles at the fault level.
        case fail
        /// Failed, waiting to be looked at (weak): the ring at the fault level, dipping twice the
        /// same way every 1.5 s.
        case fault
        /// Needs you (strong, until handled): pulses run up both sides from the front and meet at the back.
        case summon
        /// `summon` while the app is already in front: slower and dimmer.
        case quietSummon
    }

    /// LED levels (perceived brightness, 0…1) for one motion: one per ring LED, plus the short bars.
    public struct Levels: Sendable {
        public var ring: [Double]
        public var bars: Double
    }

    static var ringCount: Int { LightLayout.ring.count }
    /// Ring positions run 0…1 counterclockwise from the left end; the front middle (nearest you)
    /// is LED 5, the back middle LED 16.
    static func position(_ index: Int) -> Double { (Double(index) + 0.5) / Double(ringCount) }
    static let front = position(5), back = position(16)

    // Three strengths: strong reminders (summon, the moment something finishes or fails) at full
    // light over a lit ring; ambient (cruise); weak holds (done, fault, summon while you look).
    // Anything that stays lit stays at `weakFloor` or above: dimmer, the light guide no longer
    // blends the LEDs and they show as grains (only a passing dip goes lower).
    static let strongPeak = 1.0, strongBase = 0.4, weakFloor = 0.25
    // Moving lights, in LEDs: a lit core, a soft edge ahead, a tail fading behind.
    static let core = 1.0, edge = 1.6
    // Cruise
    public static let lap = 3.0
    static let cruiseTail = 3.5, cruisePeak = 0.8, cruiseBase = 0.25
    // Close
    static let closeDuration = 1.6
    // Hold
    static let holdLevel = 0.7, holdBreath = 0.05, holdPeriod = 6.0
    // Fail and fault: one flicker, a pair of quick smooth dips, used at full strength when it
    // fails and at the fault level while it waits.
    static let faultLevel = 0.65, dipFloor = 0.08, swell = 0.25, faultSettle = 0.6
    static let dipLength = 0.25, dipGap = 0.1, twitchPeriod = 1.5
    static let dipsLength = 2 * dipLength + dipGap
    public static let failDuration = swell + dipsLength + faultSettle
    // Summon cycle, in fractions of its period: lighting up at the front, the run to the back,
    // and the fade of the meeting flash.
    static let summonIgnite = 0.1, summonTravel = 0.62, summonFlashFade = 0.13
    /// The pulses' run, 0 → 1: off at 0.6 of the average speed (so they light up near the front
    /// yet never stand still), faster up the sides, easing to a stop at the meeting (cubic Hermite).
    static func launch(_ x: Double) -> Double {
        let t = min(1, max(0, x)), start = 0.6
        return start * t + (3 - 2 * start) * t * t + (start - 2) * t * t * t
    }
    // Summon
    public static let summonPeriod = 1.4, quietPeriod = 3.0

    /// `time` is seconds on any steady clock; `since` is when the motion began (for one-shots).
    /// A comet stands at `time / lap` laps, so cruise, close and fail line up wherever they meet.
    public static func levels(_ motion: Motion, at time: TimeInterval, since start: TimeInterval = 0) -> Levels {
        let age = max(0, time - start)
        switch motion {
        case .cruise:
            let head = time / lap
            let ring = (0..<ringCount).map { comet(at: position($0), head: head, tail: cruiseTail, peak: cruisePeak, base: cruiseBase) }
            return Levels(ring: ring, bars: cruiseBase)
        case .close:
            guard age < closeDuration else { return levels(.hold, at: time) }
            // 0–0.7 s: the comet speeds up (half a lap extra) and its tail grows round the whole ring.
            let grow = ease(min(1, age / 0.7))
            let head = time / lap + 0.5 * grow * grow
            let tail = cruiseTail + 60 * grow * grow
            let peak = cruisePeak + (1 - cruisePeak) * grow
            var ring = (0..<ringCount).map { comet(at: position($0), head: head, tail: tail, peak: peak, base: cruiseBase) }
            // 0.7–1.0 s: the gradient evens out into a full ring; 1.0–1.6 s: it settles to the hold.
            let even = ease((age - 0.7) / 0.3)
            let settle = ease((age - 1.0) / 0.6)
            let full = 1 - (1 - holdLevel) * settle
            ring = ring.map { $0 + (full - $0) * even }
            return Levels(ring: ring, bars: ring.max() ?? 0)
        case .fail:
            guard age < failDuration else { return levels(.fault, at: time) }
            if age < swell {
                // The comet stops where it stood and swells into the whole ring at full strength.
                let head = start / lap
                let grow = ease(age / swell)
                let ring = (0..<ringCount).map { index -> Double in
                    let comet = comet(at: position(index), head: head, tail: cruiseTail, peak: cruisePeak, base: cruiseBase)
                    return comet + (strongPeak - comet) * grow
                }
                return Levels(ring: ring, bars: cruiseBase + (strongPeak - cruiseBase) * grow)
            }
            // The flicker is a strong moment, at full strength; then it settles to the weak fault level.
            let into = age - swell
            let level = into < dipsLength
                ? dipped(strongPeak, at: into)
                : strongPeak - (strongPeak - faultLevel) * ease((into - dipsLength) / faultSettle)
            return Levels(ring: Array(repeating: level, count: ringCount), bars: level)
        case .fault:
            let level = dipped(faultLevel, at: time.truncatingRemainder(dividingBy: twitchPeriod))
            return Levels(ring: Array(repeating: level, count: ringCount), bars: level)
        case .hold:
            let level = holdLevel + holdBreath * sin(2 * .pi * time / holdPeriod)
            return Levels(ring: Array(repeating: level, count: ringCount), bars: level)
        case .summon, .quietSummon:
            // One shape for both: the cycle is laid out in fractions of its period, so the quiet
            // version is the same motion played slower and dimmer (fixed seconds inside it made the
            // two look different: the strong pulse lit up already halfway up the sides).
            let quiet = motion == .quietSummon
            let period = quiet ? quietPeriod : summonPeriod
            let peak = quiet ? 0.7 : strongPeak, base = quiet ? weakFloor : strongBase
            let u = age.truncatingRemainder(dividingBy: period) / period
            var ring = Array(repeating: base, count: ringCount)
            var bars = base
            if u < summonTravel {
                // Two pulses light up at the front while setting off slowly (lit before they are
                // 1.5 LEDs out), speed up the sides and slow into the meeting at the back.
                let s = launch(u / summonTravel)
                let peak = peak * ease(u / summonIgnite)
                for index in 0..<ringCount {
                    let p = position(index)
                    let up = comet(at: p, head: front + 0.5 * s, tail: 2.5, peak: peak, base: 0)
                    let down = comet(at: p, head: front - 0.5 * s, tail: 2.5, peak: peak, base: 0, clockwise: true)
                    ring[index] = max(base, up, down)
                }
            } else {
                // They meet at the back in a flash that fades before the next pair sets off.
                let flash = peak * exp(-(u - summonTravel) / summonFlashFade)
                for index in 0..<ringCount {
                    let d = distance(position(index), back) * Double(ringCount)
                    ring[index] = max(base, flash * exp(-(d * d) / (2 * 2.5 * 2.5)))
                }
                // The bars join in only when it is strong; the quiet version leaves them be.
                if !quiet { bars = max(base, flash) }
            }
            return Levels(ring: ring, bars: bars)
        }
    }

    /// A moving light whose head stands at `head` (ring turns, any real number), moving
    /// counterclockwise unless `clockwise`: a lit core of `core` LEDs, a soft edge `edge` LEDs
    /// ahead, a tail fading behind over `tail` LEDs (exponential), on a `base` level.
    static func comet(at p: Double, head: Double, tail: Double, peak: Double, base: Double, clockwise: Bool = false) -> Double {
        let n = Double(ringCount)
        let behind = wrap(clockwise ? p - head : head - p) * n
        let ahead = n - behind
        let trail = behind <= core ? 1 : exp(-(behind - core) / tail)
        let front = exp(-(ahead * ahead) / (edge * edge))
        return base + (peak - base) * max(trail, front)
    }

    /// `level` with the fault flicker `t` seconds into it: two quick dips towards `dipFloor`, each
    /// easing down and back up (sin²), with a short gap between; `level` before and after.
    static func dipped(_ level: Double, at t: Double) -> Double {
        func dip(_ x: Double) -> Double { x > 0 && x < 1 ? pow(sin(.pi * x), 2) : 0 }
        let depth = max(dip(t / dipLength), dip((t - dipLength - dipGap) / dipLength))
        return level - (level - dipFloor) * depth
    }

    static func wrap(_ x: Double) -> Double { x - x.rounded(.down) }
    static func distance(_ a: Double, _ b: Double) -> Double { abs(wrap(a - b + 0.5) - 0.5) }
    static func ease(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Painting

    /// One motion in one color, as pixels for the whole strip.
    public static func pixels(_ levels: Levels, color: RGB, ledCount: Int) -> [LightPixel] {
        let channels = LightPixel(color).channels
        var frame = Array(repeating: LightPixel.black, count: ledCount)
        for (index, led) in LightLayout.ring.enumerated() where led < ledCount && index < levels.ring.count {
            frame[led] = LightPixel(channels: channels, level: levels.ring[index])
        }
        for bar in [LightLayout.leftBar, LightLayout.rightBar] where bar < ledCount {
            frame[bar] = LightPixel(channels: channels, level: levels.bars)
        }
        return frame
    }

    // MARK: - Two apps at once

    /// Both working: two comets on one ring, half a lap apart, each in its app's color. Their tails
    /// are shorter here, so the bright parts stay apart with dim ring between, and each LED takes
    /// the colors in proportion to the light each comet gives it: inside a comet it is that
    /// comet's color, and the change of color happens only in the dim stretch between them (a hard
    /// change at a bright head showed as a stutter).
    public static func twoComets(_ a: RGB, _ b: RGB, at time: TimeInterval, ledCount: Int) -> [LightPixel] {
        let head = time / lap
        let ca = LightPixel(a).channels, cb = LightPixel(b).channels
        var frame = Array(repeating: LightPixel.black, count: ledCount)
        for (index, led) in LightLayout.ring.enumerated() where led < ledCount {
            let p = position(index)
            let la = comet(at: p, head: head, tail: pairTail, peak: cruisePeak, base: cruiseBase)
            let lb = comet(at: p, head: head + 0.5, tail: pairTail, peak: cruisePeak, base: cruiseBase)
            let wa = la - cruiseBase + 0.02, wb = lb - cruiseBase + 0.02
            let level = max(la, lb)
            frame[led] = mixed(LightPixel(channels: ca, level: level), LightPixel(channels: cb, level: level), wb / (wa + wb))
        }
        if LightLayout.leftBar < ledCount { frame[LightLayout.leftBar] = LightPixel(channels: ca, level: cruiseBase) }
        if LightLayout.rightBar < ledCount { frame[LightLayout.rightBar] = LightPixel(channels: cb, level: cruiseBase) }
        return frame
    }
    static let pairTail = 2.0

    /// Both need you: the summon pulses take turns, one cycle each; the color passes to the next
    /// app in the last quarter of a cycle, after the flash has faded.
    public static func alternatingSummon(_ colors: [RGB], at time: TimeInterval, since start: TimeInterval = 0, ledCount: Int) -> [LightPixel] {
        let age = max(0, time - start)
        let cycle = Int((age / summonPeriod).rounded(.down))
        let u = age / summonPeriod - Double(cycle)
        let levels = levels(.summon, at: time, since: start)
        let now = pixels(levels, color: colors[cycle % colors.count], ledCount: ledCount)
        let next = pixels(levels, color: colors[(cycle + 1) % colors.count], ledCount: ledCount)
        return crossfade(now, next, amount: (u - 0.75) / 0.25)
    }

    /// Several apps waiting to be looked at (done or failed): each shows its own hold for
    /// `turn` seconds, easing into the next over `blend`.
    public static func alternatingHolds(_ apps: [(motion: Motion, color: RGB)], at time: TimeInterval, turn: TimeInterval = 3, blend: TimeInterval = 1, ledCount: Int) -> [LightPixel] {
        let slot = Int((time / turn).rounded(.down))
        let into = time - Double(slot) * turn
        let current = apps[slot % apps.count], previous = apps[(slot + apps.count - 1) % apps.count]
        let now = pixels(levels(current.motion, at: time), color: current.color, ledCount: ledCount)
        guard into < blend else { return now }
        return crossfade(pixels(levels(previous.motion, at: time), color: previous.color, ledCount: ledCount), now, amount: into / blend)
    }

    /// A more urgent app takes the ring; the other stays in sight on the short bars, lit low in
    /// its own color.
    public static func withBars(_ frame: [LightPixel], color: RGB) -> [LightPixel] {
        var frame = frame
        let pixel = LightPixel(channels: LightPixel(color).channels, level: barsLevel)
        if LightLayout.leftBar < frame.count { frame[LightLayout.leftBar] = pixel }
        if LightLayout.rightBar < frame.count { frame[LightLayout.rightBar] = pixel }
        return frame
    }
    static let barsLevel = 0.5

    static func mixed(_ a: LightPixel, _ b: LightPixel, _ t: Double) -> LightPixel {
        let r = a.channels.0 * a.level * (1 - t) + b.channels.0 * b.level * t
        let g = a.channels.1 * a.level * (1 - t) + b.channels.1 * b.level * t
        let bl = a.channels.2 * a.level * (1 - t) + b.channels.2 * b.level * t
        let peak = max(r, g, bl)
        return peak == 0 ? .black : LightPixel(channels: (r / peak, g / peak, bl / peak), level: peak)
    }

    /// Fades linearly in light between two frames.
    public static func crossfade(_ from: [LightPixel], _ to: [LightPixel], amount: Double) -> [LightPixel] {
        let t = ease(amount)
        return zip(from, to).map { mixed($0, $1, t) }
    }
}
