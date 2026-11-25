import AppKit
import BrowserKit
import TwinPanesCore

/// Checks that the main thread never works longer than the stall limit between two
/// heartbeats while `body` runs, the limit measured again for each check and scaled to
/// this machine (docs/plans/M4.md; PLAN.md §9). Gaps it spent waiting for a core are
/// printed, not counted. Used by the big-folder and file-operation checks.
@MainActor
final class StallGate {
    private let smoke: SmokeTest
    private let heart = Heartbeat()
    /// The app's timed steps while a check ran, printed for a check that fails.
    let recorder = StepRecorder()
    // The table-rows workload's window, made once: making one waits on the window server.
    private let referenceWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
        backing: .buffered, defer: false)

    init(smoke: SmokeTest) {
        self.smoke = smoke
        referenceWindow.isReleasedWhenClosed = false
        StepTiming.recorder = recorder
    }

    deinit {
        MainActor.assumeIsolated {
            StepTiming.recorder = nil
            referenceWindow.close()
        }
    }

    func check(
        _ what: String, _ check: (Bool, String) -> Void, _ body: () async -> Void
    ) async {
        // Measured again for each check: a shared runner's speed changes as it runs.
        // Its leftovers (the table's layers, autoreleased objects) are cleared before the
        // check starts, so they don't count against it.
        let stall = autoreleasepool { SmokeTest.stallLimit(rowsIn: referenceWindow) }
        await smoke.settle(milliseconds: 100)
        let limit = SmokeTest.milliseconds(stall.limit)
        let limitText = String(format: "%.0f", limit)
        recorder.reset()
        heart.start()
        await body()
        let meter = heart.stop()
        let (wall, busy) = (
            SmokeTest.milliseconds(meter.worstWall), SmokeTest.milliseconds(meter.worstBusy)
        )
        print(
            String(
                format: "  info %@: worst main-thread gap %.1f ms; busiest %.1f ms on the CPU",
                what, wall, busy))
        if busy > limit {
            smoke.printSteps(recorder, from: meter.worstBusyEnd, lasting: meter.worstBusyWall)
        } else if wall > limit {
            // Not the app's work: on a shared machine, the main thread waited for a core.
            print("       the main thread waited; its busiest gap was under the limit")
        }
        check(busy <= limit, "\(what) never keeps the main thread busy over \(limitText) ms")
    }
}
