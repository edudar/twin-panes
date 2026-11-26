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

    @Test func dismissedRowDeallocates() async {
        defer { cleanUp() }
        weak var rowView: NSView?
        do {
            let operation = await heldCopy()
            rowView = strip.view.subviews.first
            #expect(rowView != nil)
            held.answer(ConflictAnswer(.skip))
            _ = await operation.finished()
        }
        #expect(rowView == nil)
    }

    @Test func lingeringDismissesOnceWithoutDuplicateTasks() async {
        defer { cleanUp() }
        var dismissedIDs: [QueuedOperation.ID] = []
        var onDismissContinuation: CheckedContinuation<Void, Never>?
        let lingeringStrip = OperationsStripViewController(
            queue: queue, linger: .milliseconds(30),
            shows: { _ in true },
            onDismiss: { id in
                dismissedIDs.append(id)
                onDismissContinuation?.resume()
                onDismissContinuation = nil
            })
        _ = lingeringStrip.view

        let operation = queue.add(
            .copy([source.appendingPathComponent("b.txt")], into: destination), scopes: []
        ) { _, _ in ConflictAnswer(.stop) }
        _ = await operation.finished()
        #expect(lingeringStrip.shownOperations.map(\.id) == [operation.id])
        for _ in 0..<5 { lingeringStrip.refresh() }
        #expect(lingeringStrip.scheduledDismissCount == 1)

        await withCheckedContinuation { continuation in
            if !dismissedIDs.isEmpty {
                continuation.resume()
            } else {
                onDismissContinuation = continuation
            }
        }
        #expect(dismissedIDs == [operation.id])
        #expect(lingeringStrip.shownOperations.isEmpty)
        #expect(lingeringStrip.scheduledDismissCount == 0)
    }

    @Test func refusedNameDismissesImmediatelyWithoutLingering() async {
        defer { cleanUp() }
        var dismissedIDs: [QueuedOperation.ID] = []
        let lingeringStrip = OperationsStripViewController(
            queue: queue, linger: .seconds(5),
            shows: { _ in true },
            onDismiss: { dismissedIDs.append($0) })
        _ = lingeringStrip.view

        let operation = queue.add(
            .rename(source.appendingPathComponent("a.txt"), to: "b.txt"), scopes: []
        ) { _, _ in ConflictAnswer(.stop) }
        let result = await operation.finished()
        #expect(result.refusal != nil)
        #expect(lingeringStrip.shownOperations.isEmpty)
        #expect(lingeringStrip.scheduledDismissCount == 0)
        #expect(dismissedIDs == [operation.id])
    }

    @Test func refreshShowsTransferredOperationsAndOnDismissFires() async {
        defer { cleanUp() }
        var accepts = false
        var dismissedIDs: [QueuedOperation.ID] = []
        let targetStrip = OperationsStripViewController(
            queue: queue, linger: .zero,
            shows: { _ in accepts },
            onDismiss: { dismissedIDs.append($0) })
        _ = targetStrip.view

        let operation = await heldCopy()
        #expect(targetStrip.shownOperations.isEmpty)
        accepts = true
        targetStrip.refresh()
        #expect(targetStrip.shownOperations.map(\.id) == [operation.id])

        held.answer(ConflictAnswer(.skip))
        _ = await operation.finished()
        #expect(dismissedIDs == [operation.id])
    }

    @Test func manyFailuresAreCappedAndShowWithoutWindowKeepsRow() async {
        defer { cleanUp() }
        let missing = (1...25).map { source.appendingPathComponent("missing-\($0).txt") }
        let operation = queue.add(.trash(missing), scopes: []) { _, _ in ConflictAnswer(.stop) }
        _ = await operation.finished()
        let list = strip.failureList(of: operation)
        let lines = list?.split(separator: "\n") ?? []
        #expect(lines.count == 21)
        #expect(lines.last == "…and 5 more")
        #expect(strip.view.window == nil)
        strip.clickShow(of: operation)
        #expect(strip.shownOperations.map(\.id) == [operation.id])
    }

    @Test func deinitCancelsPendingDismissTask() async {
        defer { cleanUp() }
        var dismissedIDs: [QueuedOperation.ID] = []
        weak var weakStrip: OperationsStripViewController?
        do {
            let lingeringStrip = OperationsStripViewController(
                queue: queue, linger: .seconds(60),
                shows: { _ in true },
                onDismiss: { dismissedIDs.append($0) })
            weakStrip = lingeringStrip
            _ = lingeringStrip.view
            let operation = queue.add(
                .copy([source.appendingPathComponent("b.txt")], into: destination), scopes: []
            ) { _, _ in ConflictAnswer(.stop) }
            _ = await operation.finished()
            #expect(lingeringStrip.scheduledDismissCount == 1)
        }
        #expect(weakStrip == nil)
        #expect(dismissedIDs.isEmpty)
    }
}
