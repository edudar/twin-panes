import Testing

@testable import TwinPanesCore

/// The smoke test's stall measure: the longest gap between heartbeats, and the most the
/// main thread worked inside one gap (docs/plans/M4.md, performance pass).
@Suite struct GapMeterTests {
    let t0 = ContinuousClock.now

    func beats(_ beats: [(wallMS: Int, cpuMS: Int)]) -> GapMeter {
        var meter = GapMeter()
        for beat in beats {
            meter.beat(at: t0 + .milliseconds(beat.wallMS), cpu: .milliseconds(beat.cpuMS))
        }
        return meter
    }

    @Test func noGapsBeforeTwoBeats() {
        let meter = beats([(0, 0)])
        #expect(meter.worstWall == .zero && meter.worstBusy == .zero)
    }

    /// A long gap with little CPU time is the thread waiting for a core, not a stall.
    @Test func waitingCountsAsAGapButNotAsWork() {
        let meter = beats([(0, 0), (5, 5), (95, 7), (100, 12)])
        #expect(meter.worstWall == .milliseconds(90))
        #expect(meter.worstWallEnd == t0 + .milliseconds(95))
        #expect(meter.worstBusy == .milliseconds(5))
    }

    /// The busiest gap is reported with when it ended and how long it lasted.
    @Test func theBusiestGapIsTheStall() {
        let meter = beats([(0, 0), (60, 2), (100, 40), (105, 45)])
        #expect(meter.worstWall == .milliseconds(60))
        #expect(meter.worstBusy == .milliseconds(38))
        #expect(meter.worstBusyEnd == t0 + .milliseconds(100))
        #expect(meter.worstBusyWall == .milliseconds(40))
    }
}
