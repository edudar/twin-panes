import AppKit
import Testing
import TwinPanesCore

@testable import BrowserKit

/// The file operations' progress strip (docs/plans/M6.md, D-e, step 13).
@MainActor
@Suite struct OperationsStripTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("OperationsStripTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let queue = FileOperationQueue(fileSystem: RealFileOperationSystem())
    let strip: OperationsStripViewController
    let held = HeldAnswers()

    var source: URL { root.appendingPathComponent("src", isDirectory: true) }
    var destination: URL { root.appendingPathComponent("dest", isDirectory: true) }

    /// src/ a.txt, b.txt; dest/ a.txt: copying a.txt asks, and waits for the test.
    init() throws {
        strip = OperationsStripViewController(queue: queue, linger: .zero) { _ in true }
        let fm = FileManager.default
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for url in [
            source.appendingPathComponent("a.txt"), source.appendingPathComponent("b.txt"),
            destination.appendingPathComponent("a.txt"),
        ] {
            try Data("x".utf8).write(to: url)
        }
        _ = strip.view
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// A copy of a.txt, held at its conflict until `held.answer(_:)`.
    func heldCopy() async -> QueuedOperation {
        let operation = queue.add(
            .copy([source.appendingPathComponent("a.txt")], into: destination), scopes: []
        ) { [held] _, _ in await held.wait() }
        await held.asked()
        return operation
    }

    @Test func aRowShowsWhatTheOperationDoesAndGoesWhenDone() async {
        defer { cleanUp() }
        let operation = await heldCopy()
        #expect(strip.shownOperations.map(\.id) == [operation.id])
        let texts = strip.texts(of: operation)
        #expect(texts?.title == "Copying “a.txt” to “dest”")
        #expect(texts?.detail == "Waiting for your answer")
        held.answer(ConflictAnswer(.skip))
        _ = await operation.finished()
        #expect(strip.shownOperations.isEmpty)
        #expect(strip.view.fittingSize.height < 1)
    }

    @Test func failuresStayWithAList() async {
        defer { cleanUp() }
        let missing = source.appendingPathComponent("missing.txt")
        let operation = queue.add(.trash([missing]), scopes: []) { _, _ in ConflictAnswer(.stop) }
        _ = await operation.finished()
        #expect(strip.shownOperations.map(\.id) == [operation.id])
        #expect(strip.texts(of: operation)?.title == "Couldn't move 1 item to the Trash")
        #expect(strip.failureList(of: operation)?.contains("missing.txt") == true)
    }

    /// The second copy waits its turn behind the held one; its buttons reach it.
    @Test func pauseAndCancelReachTheOperation() async {
        defer { cleanUp() }
        let first = await heldCopy()
        let second = queue.add(
            .copy([source.appendingPathComponent("b.txt")], into: destination), scopes: []
        ) { _, _ in ConflictAnswer(.stop) }
        #expect(strip.texts(of: second)?.detail == "Queued")
        strip.clickPause(of: second)
        #expect(second.isPaused)
        strip.clickPause(of: second)
        #expect(!second.isPaused)
        strip.clickCancel(of: second)
        held.answer(ConflictAnswer(.skip))
        _ = await first.finished()
        let result = await second.finished()
        #expect(result.wasCancelled)
    }
}
