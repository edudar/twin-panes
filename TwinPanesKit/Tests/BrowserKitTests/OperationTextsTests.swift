import Foundation
import Testing
import TwinPanesCore

@testable import BrowserKit

/// What an activity row says and its status.
@MainActor
@Suite struct OperationTextsTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("OperationTextsTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let queue = FileOperationQueue(fileSystem: RealFileOperationSystem())
    let held = HeldAnswers()

    var source: URL { root.appendingPathComponent("src", isDirectory: true) }
    var destination: URL { root.appendingPathComponent("dest", isDirectory: true) }

    /// src/ a.txt, b.txt; dest/ a.txt
    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for path in ["src/a.txt", "src/b.txt", "dest/a.txt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(path))
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func copy(_ name: String) -> QueuedOperation {
        queue.add(.copy([source.appendingPathComponent(name)], into: destination), scopes: []) {
            [held] _, _ in await held.wait()
        }
    }

    @Test func aRunningCopyTracksStatusAndDetail() async {
        defer { cleanUp() }
        let waiting = copy("a.txt")
        await held.asked()
        let queued = copy("b.txt")
        #expect(OperationTexts.status(of: waiting) == .inProgress)
        #expect(OperationTexts.title(of: waiting) == "Copying “a.txt” to “dest”")
        #expect(OperationTexts.detail(of: waiting) == "Waiting for your answer")
        #expect(OperationTexts.status(of: queued) == .inProgress)
        #expect(OperationTexts.detail(of: queued) == "Queued")
        queued.pause()
        #expect(OperationTexts.status(of: queued) == .paused)
        #expect(OperationTexts.detail(of: queued) == "Paused")
        queued.resume()
        #expect(OperationTexts.status(of: queued) == .inProgress)
        #expect(OperationTexts.detail(of: queued) == "Queued")
        queued.cancel()
        held.answer(ConflictAnswer(.skip))
        _ = await queued.finished()
        #expect(OperationTexts.status(of: queued) == .cancelled)
        #expect(OperationTexts.title(of: queued) == "Stopped copying “b.txt”")
        #expect(OperationTexts.detail(of: queued) == nil)
    }

    @Test func aFinishedCopyHasSuccessStatusAndNoDoneDetail() async {
        defer { cleanUp() }
        let operation = copy("b.txt")
        _ = await operation.finished()
        #expect(OperationTexts.status(of: operation) == .success)
        #expect(OperationTexts.title(of: operation) == "Copied “b.txt” to “dest”")
        #expect(OperationTexts.detail(of: operation) == nil)
    }

    @Test func failuresHaveErrorStatusAndCount() async {
        defer { cleanUp() }
        let missing = [source.appendingPathComponent("x"), source.appendingPathComponent("y")]
        let operation = queue.add(.trash(missing), scopes: []) { _, _ in ConflictAnswer(.stop) }
        _ = await operation.finished()
        #expect(OperationTexts.status(of: operation) == .error)
        #expect(OperationTexts.title(of: operation) == "Couldn't move 2 items to the Trash")
        #expect(OperationTexts.detail(of: operation) == "2 items failed")
    }

    @Test func refusedNameHasErrorStatus() async {
        defer { cleanUp() }
        let operation = queue.add(
            .rename(source.appendingPathComponent("a.txt"), to: "b.txt"), scopes: []
        ) { _, _ in ConflictAnswer(.stop) }
        _ = await operation.finished()
        #expect(OperationTexts.status(of: operation) == .error)
        #expect(OperationTexts.title(of: operation) == "Couldn't rename “a.txt” to “b.txt”")
        #expect(OperationTexts.detail(of: operation) == "Refused")
    }
}
