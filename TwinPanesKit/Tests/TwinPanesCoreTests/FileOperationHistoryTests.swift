import Foundation
import Testing

@testable import TwinPanesCore

/// Undo and redo of file operations (docs/plans/M6.md, D-g, step 11).
@MainActor
@Suite struct FileOperationHistoryTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileOperationHistoryTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let system = ScriptedFileOperationSystem()
    var tree: URL { root.appendingPathComponent("tree", isDirectory: true) }

    /// tree/ a.txt, b.txt, one/ c.txt, two/ (empty)
    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: tree.appendingPathComponent("one"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: tree.appendingPathComponent("two"), withIntermediateDirectories: true)
        for path in ["a.txt", "b.txt", "one/c.txt"] {
            try Data(path.utf8).write(to: tree.appendingPathComponent(path))
        }
        system.useTrash(root.appendingPathComponent("Trash", isDirectory: true))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// Every path below the tree with its contents ("" for folders).
    func snapshot() -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(atPath: tree.path)
        while let path = enumerator?.nextObject() as? String {
            let url = tree.appendingPathComponent(path)
            result[path] =
                (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        return result
    }

    /// Runs `request` to the end; conflicts use `resolve` (Keep Both by default).
    func run(
        _ request: OperationRequest,
        resolve: (Conflict) -> ConflictAnswer = { _ in ConflictAnswer(.keepBoth) }
    ) -> OperationResult {
        FileOperationQueue.run(
            request, fileSystem: system, control: OperationControl(),
            resolve: resolve, progress: { _ in })
    }

    func runAndRecord(
        _ request: OperationRequest, in history: FileOperationHistory,
        resolve: (Conflict) -> ConflictAnswer = { _ in ConflictAnswer(.keepBoth) }
    ) {
        if let change = FileChange(request: request, result: run(request, resolve: resolve)) {
            history.record(change)
        }
    }

    func undo(
        _ history: FileOperationHistory,
        resolve: (Conflict) -> ConflictAnswer = { _ in ConflictAnswer(.keepBoth) }
    ) {
        guard let change = history.takeUndo() else { return }
        for request in change.undoRequests ?? [] { _ = run(request, resolve: resolve) }
        history.didUndo(change)
    }

    func redo(
        _ history: FileOperationHistory,
        resolve: (Conflict) -> ConflictAnswer = { _ in ConflictAnswer(.keepBoth) }
    ) {
        guard let change = history.takeRedo() else { return }
        let request = change.request
        if let again = FileChange(request: request, result: run(request, resolve: resolve)) {
            history.didRedo(again)
        }
    }

    func url(_ path: String) -> URL { tree.appendingPathComponent(path) }

    @Test func titlesNameWhatWasDone() throws {
        defer { cleanUp() }
        let copy = OperationRequest.copy([url("a.txt"), url("b.txt")], into: url("two"))
        let change = try #require(FileChange(request: copy, result: run(copy)))
        #expect(change.title == "Copy of 2 Items")
        let rename = OperationRequest.rename(url("a.txt"), to: "z.txt")
        #expect(FileChange(request: rename, result: run(rename))?.title == "Rename")
    }

    @Test func aRefusedNameChangesNothingToUndo() {
        defer { cleanUp() }
        let rename = OperationRequest.rename(url("a.txt"), to: "b.txt")
        #expect(FileChange(request: rename, result: run(rename)) == nil)
    }

    @Test func aNewOperationForgetsWhatWasUndone() {
        defer { cleanUp() }
        let history = FileOperationHistory()
        runAndRecord(.makeFolder(named: "x", in: tree), in: history)
        undo(history)
        #expect(history.nextRedo != nil)
        runAndRecord(.makeFolder(named: "y", in: tree), in: history)
        #expect(history.nextRedo == nil && history.nextUndo?.title == "New Folder")
    }

    @Test func aPermanentDeleteStopsUndo() {
        defer { cleanUp() }
        let history = FileOperationHistory()
        runAndRecord(.makeFolder(named: "x", in: tree), in: history)
        runAndRecord(.delete([url("b.txt")]), in: history)
        #expect(history.isBlockedByDelete && history.nextUndo == nil && history.takeUndo() == nil)
    }

    /// Random operations, all undone, leave the tree as it was; redone, as they left it.
    @Test(arguments: 1...24)
    func undoingEverythingRestoresTheTree(seed: UInt64) {
        defer { cleanUp() }
        var random = SplitMix64(seed: seed)
        let history = FileOperationHistory()
        let initial = snapshot()
        for step in 0..<12 {
            let items = snapshot().keys.sorted().filter { !$0.isEmpty }
            let folders = [""] + items.filter { snapshot()[$0] == "" }
            guard let item = items.randomElement(using: &random),
                let folder = folders.randomElement(using: &random)
            else { break }
            let request: OperationRequest
            switch Int.random(in: 0..<5, using: &random) {
            case 0: request = .copy([url(item)], into: url(folder))
            case 1: request = .move([url(item)], into: url(folder))
            case 2: request = .trash([url(item)])
            case 3: request = .rename(url(item), to: "r\(step)")
            default: request = .makeFolder(named: "f\(step)", in: url(folder))
            }
            runAndRecord(request, in: history)
        }
        let done = snapshot()
        while history.nextUndo != nil { undo(history) }
        #expect(snapshot() == initial, "seed \(seed)")
        while history.nextRedo != nil { redo(history) }
        #expect(snapshot() == done, "seed \(seed)")
    }

    @Test func emptyOrZeroRemovalDeletesDoNotBlockUndo() throws {
        defer { cleanUp() }
        let history = FileOperationHistory()
        runAndRecord(.makeFolder(named: "x", in: tree), in: history)
        #expect(FileChange(request: .delete([]), result: .removed(RemoveOutcome())) == nil)

        let cancelled = OperationControl()
        cancelled.cancel()
        let cancelledResult = OperationResult.removed(
            TreeRemover(fileSystem: system).remove([url("a.txt")], control: cancelled) { _ in })
        #expect(FileChange(request: .delete([url("a.txt")]), result: cancelledResult) == nil)

        system.failRemove(endingWith: "a.txt", errno: EPERM)
        runAndRecord(.delete([url("a.txt")]), in: history)
        #expect(!history.isBlockedByDelete && history.nextUndo?.title == "New Folder")

        // Partial folder delete removes one child before failing: must still act as a barrier.
        try Data("keep".utf8).write(to: url("one/locked.txt"))
        system.failRemove(endingWith: "one/locked.txt", errno: EPERM)
        runAndRecord(.delete([url("one")]), in: history)
        #expect(history.isBlockedByDelete && history.nextUndo == nil)
    }

    @Test func interleavedRecordInvalidatesStaleUndoAndRedoAndLimitPreservesBarriers() throws {
        defer { cleanUp() }
        let history = FileOperationHistory(limit: 3)
        runAndRecord(.makeFolder(named: "f1", in: tree), in: history)
        let first = try #require(history.takeUndoWithToken())
        runAndRecord(.makeFolder(named: "f2", in: tree), in: history)
        history.didUndo(first.change, epoch: first.epoch)
        history.restoreUndo(first.change, epoch: first.epoch)
        #expect(history.nextRedo == nil && history.nextUndo?.title == "New Folder")
        let taken = try #require(history.takeUndo())
        runAndRecord(.makeFolder(named: "f3", in: tree), in: history)
        history.didUndo(taken)
        #expect(history.nextRedo == nil)

        runAndRecord(.makeFolder(named: "f4", in: tree), in: history)
        let current = try #require(history.takeUndoWithToken())
        history.restoreUndo(current.change, epoch: current.epoch)
        for _ in 0..<2 {
            let undid = try #require(history.takeUndoWithToken())
            history.didUndo(undid.change, epoch: undid.epoch)
        }
        let redid = try #require(history.takeRedoWithToken())
        history.didRedo(redid.change, epoch: redid.epoch)
        #expect(history.nextRedo != nil && history.nextUndo != nil)

        let bounded = FileOperationHistory(limit: 3)
        for name in ["b1", "b2"] { runAndRecord(.makeFolder(named: name, in: tree), in: bounded) }
        runAndRecord(.delete([url("a.txt")]), in: bounded)
        for name in ["b3", "b4"] { runAndRecord(.makeFolder(named: name, in: tree), in: bounded) }
        #expect(bounded.takeUndo() != nil && bounded.takeUndo() != nil)
        #expect(bounded.isBlockedByDelete && bounded.takeUndo() == nil)
    }

    @Test func modelWithExdevReplaceMergeMultiItemAndDeleteBarrier() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(
            at: url("two/one"), withIntermediateDirectories: true)
        for (path, body) in [
            ("two/a.txt", "old-a"), ("two/one/existing.txt", "existing"),
            ("xdev.txt", "xdev"), ("one/xdev.txt", "one-xdev"),
        ] {
            try Data(body.utf8).write(to: url(path))
        }
        system.failRename(endingWith: "xdev.txt", errno: EXDEV)
        let resolve: (Conflict) -> ConflictAnswer = { conflict in
            if conflict.choices.contains(.merge) { return ConflictAnswer(.merge) }
            if conflict.choices.contains(.replace) { return ConflictAnswer(.replace) }
            return ConflictAnswer(.keepBoth)
        }

        let history = FileOperationHistory()
        let initial = snapshot()
        runAndRecord(
            .copy([url("a.txt"), url("b.txt")], into: url("two")), in: history, resolve: resolve)
        runAndRecord(
            .move([url("xdev.txt"), url("one")], into: url("two")), in: history, resolve: resolve)
        let beforeBarrier = snapshot()
        while history.nextUndo != nil { undo(history, resolve: resolve) }
        #expect(snapshot() == initial)
        while history.nextRedo != nil { redo(history, resolve: resolve) }
        #expect(snapshot() == beforeBarrier)

        runAndRecord(.delete([url("two/b.txt")]), in: history, resolve: resolve)
        let afterBarrier = snapshot()
        runAndRecord(
            .trash([url("two/a.txt"), url("two/xdev.txt")]), in: history, resolve: resolve)
        runAndRecord(.rename(url("a.txt"), to: "renamed.txt"), in: history, resolve: resolve)
        let done = snapshot()
        while history.nextUndo != nil { undo(history, resolve: resolve) }
        #expect(history.isBlockedByDelete && snapshot() == afterBarrier)
        while history.nextRedo != nil { redo(history, resolve: resolve) }
        #expect(snapshot() == done)
    }
}
