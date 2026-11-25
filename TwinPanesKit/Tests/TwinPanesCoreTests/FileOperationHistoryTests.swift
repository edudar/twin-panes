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

    /// Runs `request` to the end; conflicts are answered with Keep Both.
    func run(_ request: OperationRequest) -> OperationResult {
        FileOperationQueue.run(
            request, fileSystem: system, control: OperationControl(),
            resolve: { _ in ConflictAnswer(.keepBoth) }, progress: { _ in })
    }

    func runAndRecord(_ request: OperationRequest, in history: FileOperationHistory) {
        if let change = FileChange(request: request, result: run(request)) {
            history.record(change)
        }
    }

    func undo(_ history: FileOperationHistory) {
        guard let change = history.takeUndo() else { return }
        for request in change.undoRequests ?? [] { _ = run(request) }
        history.didUndo(change)
    }

    func redo(_ history: FileOperationHistory) {
        guard let change = history.takeRedo() else { return }
        let request = change.request
        if let again = FileChange(request: request, result: run(request)) {
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
}
