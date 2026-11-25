import Foundation
import Testing

@testable import TwinPanesCore

/// An operation as the queue and its progress row see it (docs/plans/M6.md, D-e).
@MainActor
@Suite struct QueuedOperationTests {
    let here = URL(fileURLWithPath: "/tmp/x")

    @Test func copiesAndMovesWaitTheirTurnTrashAndDeleteDont() {
        #expect(OperationRequest.copy([here], into: here).waitsItsTurn)
        #expect(OperationRequest.move([here], into: here).waitsItsTurn)
        #expect(!OperationRequest.trash([here]).waitsItsTurn)
        #expect(!OperationRequest.delete([here]).waitsItsTurn)
        #expect(OperationRequest.putBack([MovedItem(from: here, to: here)]).waitsItsTurn)
    }

    @Test func aResultReportsItsFailuresAndCancel() {
        var outcome = TrashOutcome()
        outcome.failures = [FileSystemError("move to the Trash", "/x", errno: ENOTSUP)]
        outcome.wasCancelled = true
        let result = OperationResult.trashed(outcome)
        #expect(result.failures.map(\.errno) == [ENOTSUP] && result.wasCancelled)
    }

    @Test func pauseAndCancelReachTheOperationsControl() {
        let operation = QueuedOperation(request: .trash([here]), scopes: [])
        operation.pause()
        #expect(operation.isPaused)
        operation.resume()
        #expect(!operation.isPaused)
        operation.cancel()
        #expect(operation.control.isCancelled && operation.result == nil)
    }
}
