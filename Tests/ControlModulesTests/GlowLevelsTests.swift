import Testing
@testable import ControlModules

@Suite struct GlowLevelsTests {
    /// A small accent landing while a big flash is still fading must still lift the light.
    @Test func smallAccentDuringAFadeIsNotSwallowed() {
        var envelope = FlashEnvelope(attack: GlowBudget.accentAttack, decay: GlowBudget.accentDecay)
        let dt = 1.0 / 30
        envelope.trigger(GlowBudget.accent(strength: 1, intensity: 1))
        for _ in 0..<18 { envelope.advance(dt: dt) }   // 0.6 s
        let before = envelope.level
        envelope.trigger(GlowBudget.accent(strength: 0.3, intensity: 1))
        var peak = before
        for _ in 0..<10 {
            envelope.advance(dt: dt)
            peak = max(peak, envelope.level)
        }
        #expect(before > GlowBudget.accent(strength: 0.3, intensity: 1), "the fade is still above the small accent's size")
        #expect(peak > before + 0.08, "before \(before) peak \(peak)")
    }

    /// A flash rises roundly to its full size and falls slowly, with no jump between frames.
    @Test func flashIsSmooth() {
        var envelope = FlashEnvelope(attack: GlowBudget.accentAttack, decay: GlowBudget.accentDecay)
        let dt = 1.0 / 30
        envelope.trigger(1)
        var levels: [Double] = []
        for _ in 0..<60 {
            envelope.advance(dt: dt)
            levels.append(envelope.level)
        }
        let peak = levels.max()!
        let peakFrame = levels.firstIndex(of: peak)!
        #expect(abs(peak - 1) < 0.02, "peak \(peak)")
        #expect((0.08...0.2).contains(Double(peakFrame + 1) * dt), "peak after \(Double(peakFrame + 1) * dt) s")
        let half = levels[peakFrame...].firstIndex { $0 < 0.5 }.map { Double($0 + 1) * dt }
        #expect(half.map { (0.45...0.8).contains($0) } ?? false, "half after \(String(describing: half)) s")
        let steps = zip(levels, levels.dropFirst()).map { abs($1 - $0) }
        #expect(steps.max()! < 0.35, "largest step \(steps.max()!)")
    }

    /// The biggest accent reaches full brightness; nothing ever goes past it.
    @Test func brightnessStaysWithinBudget() {
        #expect(GlowBudget.brightness(base: 0.3, accent: GlowBudget.accent(strength: 1, intensity: 1), groove: 0) == 1)
        for base in stride(from: 0.0, through: 0.6, by: 0.1) {
            for accent in stride(from: 0.0, through: 1, by: 0.1) {
                for groove in stride(from: 0.0, through: 1, by: 0.25) {
                    let value = GlowBudget.brightness(base: base, accent: accent, groove: groove)
                    #expect(value >= base && value <= 1)
                }
            }
        }
    }

    /// Heavier accents are brighter, and a calm passage (intensity 0) does not flash at all.
    @Test func accentSizeFollowsStrengthAndIntensity() {
        let sizes = [0.2, 0.5, 0.8, 1.0].map { GlowBudget.accent(strength: $0, intensity: 1) }
        #expect(sizes == sizes.sorted() && Set(sizes).count == sizes.count)
        #expect(GlowBudget.accent(strength: 1, intensity: 0) == 0)
    }
}
