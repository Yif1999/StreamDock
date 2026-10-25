import Testing
@testable import DockCore

struct FrameGridTests {
    @Test func framesStayOnTheGridAndSkipWhatAStallMissed() {
        let start = ContinuousClock.now
        let grid = FrameGrid(framesPerSecond: 60, start: start)
        // Early in a slot: the end of that slot.
        #expect(grid.next(after: start + .milliseconds(5)) == start + .seconds(1.0 / 60))
        // After a one-second stall: the next slot from now, not a burst of the 60 missed ones.
        #expect(grid.next(after: start + .milliseconds(1001)) == start + .seconds(61.0 / 60))
    }
}
