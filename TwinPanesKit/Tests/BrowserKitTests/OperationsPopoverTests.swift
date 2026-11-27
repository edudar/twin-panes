import AppKit
import Testing
import TwinPanesCore
import WorkspaceKit

@testable import BrowserKit

@MainActor
@Suite struct OperationsPopoverTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("OperationsPopoverTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let queue = FileOperationQueue(fileSystem: RealFileOperationSystem())
    let popover: OperationsPopoverViewController
    let held = HeldAnswers()

    var source: URL { root.appendingPathComponent("src", isDirectory: true) }
    var destination: URL { root.appendingPathComponent("dest", isDirectory: true) }

    /// src/ a.txt, b.txt; dest/ a.txt: copying a.txt asks and waits for the test.
    init() throws {
        popover = OperationsPopoverViewController(queue: queue, linger: .zero) { _ in true }
        let fm = FileManager.default
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for url in [
            source.appendingPathComponent("a.txt"), source.appendingPathComponent("b.txt"),
            destination.appendingPathComponent("a.txt"),
        ] {
            try Data("x".utf8).write(to: url)
        }
        _ = popover.view
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func heldCopy() async -> QueuedOperation {
        let operation = queue.add(
            .copy([source.appendingPathComponent("a.txt")], into: destination), scopes: []
        ) { [held] _, _ in await held.wait() }
        await held.asked()
        return operation
    }

    @Test func rowUpdatesStatusAndStaysInHistoryAfterAutoHide() async {
        defer { cleanUp() }
        var showCount = 0
        var hideCount = 0
        popover.onRequestShow = { showCount += 1 }
        popover.onRequestHide = { hideCount += 1 }

        let operation = await heldCopy()
        #expect(showCount == 1)
        #expect(hideCount == 0)
        #expect(popover.shownOperations.map(\.id) == [operation.id])
        #expect(popover.status(of: operation) == .inProgress)
        #expect(popover.texts(of: operation)?.title == "Copying “a.txt” to “dest”")
        #expect(popover.texts(of: operation)?.detail == "Waiting for your answer")

        held.answer(ConflictAnswer(.skip))
        _ = await operation.finished()
        #expect(hideCount == 1)
        #expect(popover.shownOperations.map(\.id) == [operation.id])
        #expect(popover.status(of: operation) == .success)
        #expect(popover.texts(of: operation)?.detail == nil)
    }

    @Test func failuresKeepPopoverOpenAndCapErrorList() async {
        defer { cleanUp() }
        var hideCount = 0
        var indicatorStates: [OperationsIndicatorState] = []
        popover.onRequestHide = { hideCount += 1 }
        popover.onIndicatorChange = { indicatorStates.append($0) }

        let missing = (1...25).map { source.appendingPathComponent("missing-\($0).txt") }
        let operation = queue.add(.trash(missing), scopes: []) { _, _ in ConflictAnswer(.stop) }
        _ = await operation.finished()

        #expect(hideCount == 0)
        #expect(popover.status(of: operation) == .error)
        #expect(indicatorStates.last == .failed)
        let lines = popover.failureList(of: operation)?.split(separator: "\n") ?? []
        #expect(lines.count == 21)
        #expect(lines.last == "…and 5 more")
    }

    @Test func pauseResumeAndCancelReachQueuedOperation() async {
        defer { cleanUp() }
        let first = await heldCopy()
        let second = queue.add(
            .copy([source.appendingPathComponent("b.txt")], into: destination), scopes: []
        ) { _, _ in ConflictAnswer(.stop) }

        #expect(popover.status(of: second) == .inProgress)
        popover.clickPause(of: second)
        #expect(second.isPaused)
        #expect(popover.status(of: second) == .paused)

        popover.clickPause(of: second)
        #expect(!second.isPaused)
        #expect(popover.status(of: second) == .inProgress)

        popover.clickCancel(of: second)
        held.answer(ConflictAnswer(.skip))
        _ = await first.finished()
        let result = await second.finished()
        #expect(result.wasCancelled)
        #expect(popover.status(of: second) == .cancelled)
    }

    @Test func historyKeepsLastTwentyNewestFirstAndDiscardsOlder() async {
        defer { cleanUp() }
        var discarded: [QueuedOperation.ID] = []
        let capped = OperationsPopoverViewController(
            queue: queue, linger: .zero, shows: { _ in true },
            onDiscard: { discarded.append($0) })
        _ = capped.view

        var created: [QueuedOperation] = []
        for index in 1...23 {
            let folder = "folder-\(index)"
            let op = queue.add(.makeFolder(named: folder, in: destination), scopes: []) { _, _ in
                ConflictAnswer(.stop)
            }
            _ = await op.finished()
            created.append(op)
        }

        let shown = capped.shownOperations
        #expect(shown.count == OperationsPopoverViewController.maxRetainedOperations)
        #expect(shown.first?.id == created.last?.id)
        #expect(shown.last?.id == created[3].id)
        #expect(discarded == created.prefix(3).map(\.id))
    }

    @Test func preferredHeightCapsAtFourVisibleRows() async {
        defer { cleanUp() }
        var heights: [CGFloat] = []
        for index in 1...6 {
            let op = queue.add(.makeFolder(named: "dir-\(index)", in: destination), scopes: []) {
                _, _ in ConflictAnswer(.stop)
            }
            _ = await op.finished()
            heights.append(popover.preferredContentSize.height)
        }
        #expect(heights[0] < heights[1])
        #expect(heights[1] < heights[2])
        #expect(heights[2] < heights[3])
        #expect(heights[3] == heights[4])
        #expect(heights[4] == heights[5])
    }

    @Test func manualOpenSuppressesAutoHideAndClearRemovesFinished() async {
        defer { cleanUp() }
        var discarded: [QueuedOperation.ID] = []
        var hideCount = 0
        let controller = OperationsPopoverViewController(
            queue: queue, linger: .milliseconds(30), shows: { _ in true },
            onDiscard: { discarded.append($0) })
        controller.onRequestHide = { hideCount += 1 }
        _ = controller.view

        let operation = await heldCopy()
        controller.noteUserOpened()
        held.answer(ConflictAnswer(.skip))
        _ = await operation.finished()
        #expect(!controller.isAutoHideScheduled)
        #expect(hideCount == 0)

        controller.clickClear()
        #expect(controller.shownOperations.isEmpty)
        #expect(discarded == [operation.id])
    }

    @Test func lingeringAutoHidesOnceAndCancelsOnDeinit() async {
        defer { cleanUp() }
        var hideCount = 0
        var hideContinuation: CheckedContinuation<Void, Never>?
        let lingering = OperationsPopoverViewController(
            queue: queue, linger: .milliseconds(30), shows: { _ in true })
        lingering.onRequestHide = {
            hideCount += 1
            hideContinuation?.resume()
            hideContinuation = nil
        }
        _ = lingering.view

        let op = queue.add(.makeFolder(named: "linger-dir", in: destination), scopes: []) { _, _ in
            ConflictAnswer(.stop)
        }
        _ = await op.finished()
        #expect(lingering.isAutoHideScheduled)

        await withCheckedContinuation { continuation in
            if hideCount > 0 {
                continuation.resume()
            } else {
                hideContinuation = continuation
            }
        }
        #expect(hideCount == 1)
        #expect(!lingering.isAutoHideScheduled)

        var deinitHides = 0
        weak var weakController: OperationsPopoverViewController?
        do {
            let shortLived = OperationsPopoverViewController(
                queue: queue, linger: .seconds(60), shows: { _ in true })
            shortLived.onRequestHide = { deinitHides += 1 }
            weakController = shortLived
            _ = shortLived.view
            let op2 = queue.add(.makeFolder(named: "deinit-dir", in: destination), scopes: []) {
                _, _ in ConflictAnswer(.stop)
            }
            _ = await op2.finished()
            #expect(shortLived.isAutoHideScheduled)
        }
        #expect(weakController == nil)
        #expect(deinitHides == 0)
    }

    @Test func refusedNameDiscardsImmediatelyWithoutEnteringHistory() async {
        defer { cleanUp() }
        var discarded: [QueuedOperation.ID] = []
        let controller = OperationsPopoverViewController(
            queue: queue, linger: .seconds(5), shows: { _ in true },
            onDiscard: { discarded.append($0) })
        _ = controller.view

        let op = queue.add(
            .rename(source.appendingPathComponent("a.txt"), to: "b.txt"), scopes: []
        ) { _, _ in ConflictAnswer(.stop) }
        let result = await op.finished()
        #expect(result.refusal != nil)
        #expect(controller.shownOperations.isEmpty)
        #expect(discarded == [op.id])
    }
}
