import Foundation
import Testing

@testable import BrowserKit

/// Timed main-actor steps for the smoke test's stall report (docs/plans/M4.md,
/// performance pass, step 1).
@MainActor
@Suite(.serialized) struct StepTimingTests {
    let t0 = ContinuousClock.now

    func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    @Test func measureRunsTheBodyWithoutARecorder() {
        StepTiming.recorder = nil
        #expect(StepTiming.measure("step") { 42 } == 42)
    }

    @Test func measureRecordsANamedStep() {
        let recorder = StepRecorder()
        StepTiming.recorder = recorder
        defer { StepTiming.recorder = nil }
        let before = ContinuousClock.now
        #expect(StepTiming.measure("show") { "done" } == "done")
        let steps = recorder.steps(from: before, to: .now)
        #expect(steps.map(\.name) == ["show"])
        #expect(steps.first?.count == 1)
    }

    @Test func stepsAreClippedToTheSpanAndSortedByTime() {
        let recorder = StepRecorder()
        recorder.record("draw", from: at(0), to: at(10))
        recorder.record("draw", from: at(20), to: at(25))
        recorder.record("show", from: at(5), to: at(40))
        recorder.record("before", from: at(-20), to: at(-10))
        recorder.record("after", from: at(60), to: at(70))
        let steps = recorder.steps(from: at(8), to: at(50))
        #expect(steps.map(\.name) == ["show", "draw"])
        #expect(steps[0].total == .milliseconds(32) && steps[0].longest == .milliseconds(35))
        #expect(steps[1].count == 2 && steps[1].total == .milliseconds(7))
        #expect(steps[1].longest == .milliseconds(10))
    }

    @Test func resetForgetsAndTheLimitDropsTheOldest() {
        let recorder = StepRecorder(limit: 4)
        for i in 0..<5 { recorder.record("s\(i)", from: at(i * 10), to: at(i * 10 + 1)) }
        let names = Set(recorder.steps(from: at(-1), to: at(100)).map(\.name))
        #expect(names.contains("s4") && !names.contains("s0"))
        recorder.reset()
        #expect(recorder.steps(from: at(-1), to: at(100)).isEmpty)
    }

    @Test func zeroLimitClampsToOneAndInvertedSpanReturnsEmpty() {
        let recorder = StepRecorder(limit: 0)
        recorder.record("a", from: at(0), to: at(5))
        recorder.record("b", from: at(5), to: at(25))
        #expect(recorder.steps(from: at(0), to: at(30)).map(\.name) == ["b"])
        #expect(recorder.steps(from: at(10), to: at(10)).isEmpty)
        #expect(recorder.steps(from: at(20), to: at(10)).isEmpty)
    }

    /// A step that waited (for a core, a lock, the disk) shows little time on the CPU.
    @Test func stepsSayHowMuchOfTheirTimeWasOnTheCPU() {
        let recorder = StepRecorder()
        StepTiming.recorder = recorder
        defer { StepTiming.recorder = nil }
        let before = ContinuousClock.now
        StepTiming.measure("waiting") { Thread.sleep(forTimeInterval: 0.03) }
        StepTiming.measure("working") {
            let end = StepTiming.threadCPU() + .milliseconds(25)
            while StepTiming.threadCPU() < end {}
        }
        let steps = Dictionary(
            uniqueKeysWithValues: recorder.steps(from: before, to: .now).map { ($0.name, $0) })
        let waiting = steps["waiting"], working = steps["working"]
        #expect((waiting?.longest ?? .zero) >= .milliseconds(30))
        #expect((waiting?.longestOnCPU ?? .seconds(1)) < .milliseconds(10))
        #expect((working?.longestOnCPU ?? .zero) > .milliseconds(15))
        #expect((working?.onCPU ?? .zero) == working?.longestOnCPU)
    }
}
