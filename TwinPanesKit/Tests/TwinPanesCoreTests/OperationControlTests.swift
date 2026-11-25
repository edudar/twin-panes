import Foundation
import Testing

@testable import TwinPanesCore

/// Pausing and cancelling a running operation (docs/plans/M6.md, D-c, step 6).
@Suite struct OperationControlTests {
    @Test func aFreshOperationGoesOn() {
        let control = OperationControl()
        #expect(control.checkpoint() && !control.isPaused && !control.isCancelled)
    }

    @Test func aCancelledOperationStops() {
        let control = OperationControl()
        control.cancel()
        #expect(!control.checkpoint() && control.isCancelled)
    }

    /// A checkpoint waiting in a pause wakes when the operation is cancelled.
    @Test func cancellingEndsAPause() async {
        let control = OperationControl()
        control.pause()
        #expect(control.isPaused)
        let waiting = Task.detached { control.checkpoint() }
        control.cancel()
        #expect(await waiting.value == false)
        #expect(!control.isPaused)
    }

    @Test func resumingEndsAPause() async {
        let control = OperationControl()
        control.pause()
        let waiting = Task.detached { control.checkpoint() }
        control.resume()
        #expect(await waiting.value == true)
    }
}
