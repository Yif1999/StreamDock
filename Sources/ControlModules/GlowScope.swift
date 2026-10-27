import DockCore
import Foundation
import Observation
import RhythmKit

/// A live look inside the music light, for the 律动可视化 window: the canvas seen from above with
/// its blobs, what each LED shows, and the last seconds of the low end and the events driving
/// it. Recorded by the playing `MusicGlow` only while the window is open.
@MainActor @Observable
public final class GlowScope {
    public static let shared = GlowScope()
    /// Set by the window; nothing is recorded otherwise.
    public var watching = false {
        didSet { if !watching { frame = nil; samples = []; marks = []; layer = .all } }
    }

    /// Which part of the music light plays, on the strip too (back to all when the window closes).
    public var layer: MusicGlowLayer = .all
    public static let history = 8.0
    /// Canvas samples per side.
    public static let grid = 32

    public struct Blob: Sendable {
        public let x, y: Double
        /// Where its soft edge is half way (`GlowBudget.cover`).
        public let radius: Double
        public let vx, vy: Double
        /// The main color's blob (over the others, pulled by the low end).
        public let main: Bool
        /// Where it is in the shuffle: 1 in front, −1 behind (the main blob is always 1).
        public let depth: Double
        public let color: RGB
    }

    public struct Frame: Sendable {
        public let time: Double
        /// The canvas, `grid` × `grid`, row 0 at the front (y 0).
        public let canvas: [RGB]
        public let blobs: [Blob]
        /// Every LED where it sits and what it shows (brightness included).
        public let leds: [(x: Double, y: Double, color: RGB, bar: Bool)]
        /// Mid lifts still showing: where on the edge, how strong now.
        public let lifts: [(x: Double, y: Double, level: Double)]
        /// Where the low end is pulling the main blob, while it draws.
        public let anchor: (x: Double, y: Double)?
        public let draw, rebound, lowDraw, intensity: Double
    }

    public struct Sample: Sendable {
        public let time, lowDraw, draw, rebound, intensity: Double
    }

    public enum Mark: Sendable {
        /// Every low-band hit (`strength` 0...1), and the heaviest (they hold the glints back).
        case lowHit(time: Double, strength: Double)
        case kick(time: Double, strength: Double)
        /// A mid hit: full height for a heavy one (it flashes), half its size for a light one.
        case lift(time: Double, strength: Double)
        case high(time: Double, strength: Double)

        public var time: Double {
            switch self {
            case .lowHit(let time, _), .kick(let time, _), .lift(let time, _), .high(let time, _): time
            }
        }
    }

    public private(set) var frame: Frame?
    public private(set) var samples: [Sample] = []
    public private(set) var marks: [Mark] = []

    func record(_ frame: Frame, events: [RhythmEvent]) {
        self.frame = frame
        samples.append(Sample(time: frame.time, lowDraw: frame.lowDraw, draw: frame.draw, rebound: frame.rebound, intensity: frame.intensity))
        for event in events {
            switch event {
            case .hit(let hit) where hit.band == .low: marks.append(.lowHit(time: frame.time, strength: min(1, hit.strength / 10)))
            case .kick(_, let strength): marks.append(.kick(time: frame.time, strength: strength))
            case .lift(_, .mid, let strength, let heavy): marks.append(.lift(time: frame.time, strength: heavy ? 1 : strength * 0.5))
            case .lift(_, _, let strength, _): marks.append(.high(time: frame.time, strength: strength))
            default: break
            }
        }
        let since = frame.time - Self.history
        samples.removeAll { $0.time < since }
        marks.removeAll { $0.time < since }
    }
}

/// The music light driven by hand — for `dock-probe glowdemo`, which plays scripted rhythm on
/// the strip (no audio needed) to show an effect on its own.
@MainActor
public final class MusicGlowDriver {
    private let glow: MusicGlow
    public init(palette: [Swatch]) { glow = MusicGlow(palette: palette) }
    public func frame(at time: TimeInterval, ledCount: Int, events: [RhythmEvent], snapshot: RhythmSnapshot) -> [LightPixel] {
        glow.frame(at: time, ledCount: ledCount, input: (events, snapshot))
    }
}
