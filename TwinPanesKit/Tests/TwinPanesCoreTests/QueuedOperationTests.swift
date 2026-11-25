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

    @Test func renameAndNewFolderRunAtOnceAndReportRefusals() {
        #expect(!OperationRequest.rename(here, to: "y").waitsItsTurn)
        #expect(!OperationRequest.makeFolder(named: "y", in: here).waitsItsTurn)
        let refused = OperationResult.renamed(.failure(.taken(here)))
        #expect(refused.refusal == .taken(here) && refused.failures.isEmpty)
        let error = FileSystemError("make folder", "/tmp/x", errno: EACCES)
        let failed = OperationResult.madeFolder(.failure(.failed(error)))
        #expect(failed.failures == [error] && !failed.wasCancelled)
    }

    /// The queue runs a rename and a new folder like any other request.
    @Test func renameAndNewFolderGoThroughTheQueue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueuedOperationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = FileOperationQueue(fileSystem: RealFileOperationSystem())
        let made = await queue.add(
            .makeFolder(named: "new", in: root), scopes: [], ask: { _, _ in ConflictAnswer(.stop) }
        ).finished()
        guard case .madeFolder(.success(let folder)) = made else {
            Issue.record("made a folder: \(made)")
            return
        }
        let renamed = await queue.add(
            .rename(folder, to: "newer"), scopes: [], ask: { _, _ in ConflictAnswer(.stop) }
        ).finished()
        guard case .renamed(.success(let moved)) = renamed else {
            Issue.record("renamed it: \(renamed)")
            return
        }
        #expect(moved.to.lastPathComponent == "newer")
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
