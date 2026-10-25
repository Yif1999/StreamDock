import DockCore
import Foundation

/// The VibeCoding scene's live reminder light: every frame it reads `AgentStatus` and paints it
/// in the `AgentLight` language. One app showing takes the ring; two at the same tier share it
/// (paired comets when both work, turns otherwise); a less urgent app stays on the short bars.
/// It eases between arrangements itself, so it stays on the strip as one animation while
/// anything shows; the monitor takes it off when both apps are idle.
@MainActor
final class AgentGlow: LightAnimation {
    private let status: AgentStatus
    // The arrangement on show, when it began, and the fade into it.
    private var signature = ""
    private var since: TimeInterval = 0
    private var lastFrame: [LightPixel]?
    private var fadeFrom: [LightPixel]?
    private var fadeStart: TimeInterval = 0
    private var fadeLength: TimeInterval = 0

    init(status: AgentStatus) { self.status = status }

    /// Reminders always count as activity: the engine never halves them like an idle color.
    var isActive: Bool { true }

    func pixels(at time: TimeInterval, ledCount: Int) -> [LightPixel] {
        // The status records on the engine's clock (system uptime), so `time` compares directly.
        let lights = AIService.allCases.map { ($0, status.light(for: $0, at: time)) }
        let key = Self.signature(lights)
        if key != signature {
            if let lastFrame { fadeFrom = lastFrame }
            fadeStart = time
            fadeLength = Self.fade(into: lights)
            signature = key
            since = time
        }
        var frame = compose(lights, at: time, ledCount: ledCount)
        if let from = fadeFrom {
            let progress = (time - fadeStart) / fadeLength
            if progress >= 1 { fadeFrom = nil } else { frame = AgentLight.crossfade(from, frame, amount: progress) }
        }
        lastFrame = frame
        return frame
    }

    private func compose(_ lights: [(AIService, AgentStatus.Light)], at time: TimeInterval, ledCount: Int) -> [LightPixel] {
        let showing = lights.filter { $0.1 != .idle }
        // Everything just went idle: hold the last frame while the monitor takes the glow off and
        // the engine eases to the scene color.
        guard let top = showing.map(\.1.tier).max() else { return lastFrame ?? Array(repeating: .black, count: ledCount) }
        let leaders = showing.filter { $0.1.tier == top }
        let rest = showing.filter { $0.1.tier < top }
        let colors = leaders.map { AgentLight.color(for: $0.0) }
        var frame: [LightPixel]
        if leaders.count == 2 {
            switch leaders[0].1 {
            case .cruise:
                frame = AgentLight.twoComets(colors[0], colors[1], at: time, ledCount: ledCount)
            case .summon:
                // Quiet only when neither needs to be loud.
                let quiet = leaders.allSatisfy { $0.1 == .summon(quiet: true) }
                frame = AgentLight.alternatingSummon(colors, quiet: quiet, at: time, since: since, ledCount: ledCount)
            case .hold, .fault:
                frame = AgentLight.alternatingHolds(leaders.map { (motion(for: $0.1), AgentLight.color(for: $0.0)) }, at: time, ledCount: ledCount)
            default:
                // Two one-shots at once: the latest plays, the other waits on the bars.
                let latest = leaders.max { start(of: $0.1) < start(of: $1.1) }!
                let other = leaders.first { $0.0 != latest.0 }!
                return AgentLight.withBars(single(latest, at: time, ledCount: ledCount), color: AgentLight.color(for: other.0))
            }
        } else {
            frame = single(leaders[0], at: time, ledCount: ledCount)
        }
        if let other = rest.first { frame = AgentLight.withBars(frame, color: AgentLight.color(for: other.0)) }
        return frame
    }

    private func single(_ app: (AIService, AgentStatus.Light), at time: TimeInterval, ledCount: Int) -> [LightPixel] {
        AgentLight.pixels(AgentLight.levels(motion(for: app.1), at: time, since: start(of: app.1)), color: AgentLight.color(for: app.0), ledCount: ledCount)
    }

    private func motion(for light: AgentStatus.Light) -> AgentLight.Motion {
        switch light {
        case .idle, .cruise: .cruise
        case .summon(let quiet): quiet ? .quietSummon : .summon
        case .close: .close
        case .hold: .hold
        case .fail: .fail
        case .fault: .fault
        }
    }

    /// When a motion's own clock starts: a one-shot from its moment, a summon from when this
    /// arrangement began (so the first pair sets off at once), the rest run on absolute time.
    private func start(of light: AgentStatus.Light) -> TimeInterval {
        switch light {
        case .close(let since), .fail(let since): since
        case .summon: since
        default: 0
        }
    }

    /// What is on show, without the times that only move it along.
    static func signature(_ lights: [(AIService, AgentStatus.Light)]) -> String {
        lights.map { service, light in
            switch light {
            case .close(let since): "\(service.rawValue):close@\(since)"
            case .fail(let since): "\(service.rawValue):fail@\(since)"
            default: "\(service.rawValue):\(light)"
            }
        }.joined(separator: " ")
    }

    /// One-shots cut in quickly, a summon fairly quickly, anything else eases.
    static func fade(into lights: [(AIService, AgentStatus.Light)]) -> TimeInterval {
        let states = lights.map(\.1)
        if states.contains(where: { if case .close = $0 { true } else if case .fail = $0 { true } else { false } }) { return 0.15 }
        if states.contains(where: { if case .summon = $0 { true } else { false } }) { return 0.3 }
        return 0.6
    }
}
