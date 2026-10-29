import Foundation
import Testing
@testable import DockCore

struct MotionTests {
    @Test func easeIsSlowAtBothEndsAndFastThroughTheMiddle() {
        #expect(Motion.ease(0) == 0 && abs(Motion.ease(1) - 1) < 1e-6 && abs(Motion.ease(0.5) - 0.5) < 1e-6)
        // Symmetric, and monotonic.
        #expect(abs(Motion.ease(0.2) + Motion.ease(0.8) - 1) < 1e-6)
        let samples = stride(from: 0.0, through: 1, by: 0.01).map(Motion.ease)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
        // The first and last fifth cover little ground; the middle is five times average speed.
        #expect(Motion.ease(0.2) < 0.06)
        #expect(abs(Motion.peakSpeed - 5) < 0.01)
        #expect(Motion.speed(0.05) < 0.2 && Motion.speed(0.95) < 0.2)
    }

    @Test func settleOvershootsOnceAndComesToRest() {
        let samples = stride(from: 0.0, through: 1, by: 0.005).map(Motion.settle)
        let peak = samples.max()!
        #expect(peak > 1.06 && peak < 1.1)
        #expect(Motion.settle(0) == 0 && Motion.settle(1) == 1 && abs(Motion.settle(0.97) - 1) < 0.01)
        #expect(Motion.settle(0.05) < 0.1) // Leaves gently.
    }

    @Test func stretchKeepsTheAreaAndDurationGrowsWithDistance() {
        let fast = Motion.stretch(speed: Motion.peakSpeed)
        #expect(abs(fast.along - 1.3) < 1e-9 && abs(fast.along * fast.across - 1) < 1e-9)
        #expect(Motion.stretch(speed: 0).along == 1)
        #expect(Motion.duration(distance: 64) == 0.25)
        #expect(Motion.duration(distance: 10) == 0.18 && Motion.duration(distance: 2000) == 0.6)
    }

    @MainActor @Test func valuesGlideToANewReadingAndRedrawUntilThere() async throws {
        var redraws = 0
        let values = ValueTransitions<Int>(redraw: { redraws += 1 })
        // First reading: fills up from empty.
        #expect(values.value(1, target: 0.5) < 0.01)
        #expect(values.isAnimating)
        let deadline = ContinuousClock.now + .seconds(3)
        while values.isAnimating && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(values.value(1, target: 0.5) == 0.5 && !values.isAnimating && redraws > 10)
        // A new reading starts from what is shown, not from empty.
        let next = values.value(1, target: 0.8)
        #expect(next >= 0.5 && next < 0.52)
        #expect(Motion.duration(change: 0.3) > 0.5 && Motion.duration(change: 1) == 0.7)
    }

    @Test func oneFormulaForKeysAndLight() {
        // The light strip's curve is exactly smoothstep; the keys' is the same formula, steeper.
        for t in stride(from: 0.0, through: 1, by: 0.05) {
            #expect(abs(Motion.light.ease(t) - t * t * (3 - 2 * t)) < 1e-6)
        }
        #expect(abs(Motion.light.speed(0.5) - 1.5) < 1e-6 && abs(Motion.keys.speed(0.5) - 5) < 1e-6)
        #expect(abs(Motion.Curve(peak: 2.5).speed(0.5) - 2.5) < 1e-6)
    }
}
