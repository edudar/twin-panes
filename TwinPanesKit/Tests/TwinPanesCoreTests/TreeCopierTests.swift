import Foundation
import Testing

@testable import TwinPanesCore

/// Copying walked trees (docs/plans/M6.md, D-c, step 6).
@Suite struct TreeCopierTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TreeCopierTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let system = ScriptedFileOperationSystem()
    let old = Date(timeIntervalSince1970: 1_000_000_000)

    /// tree/ a.txt, sub/ b.bin, sub/c.bin, link -> a.txt
    var tree: URL { root.appendingPathComponent("tree", isDirectory: true) }
    var destination: URL { root.appendingPathComponent("dest", isDirectory: true) }
    var copy: URL { destination.appendingPathComponent("tree", isDirectory: true) }

    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: tree.appendingPathComponent("a.txt"))
        try Data(count: 5).write(to: tree.appendingPathComponent("sub/b.bin"))
        try Data(count: 7).write(to: tree.appendingPathComponent("sub/c.bin"))
        try fm.createSymbolicLink(
            atPath: tree.appendingPathComponent("link").path, withDestinationPath: "a.txt")
        try fm.setAttributes(
            [.modificationDate: old], ofItemAtPath: tree.appendingPathComponent("sub").path)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func run(_ control: OperationControl = OperationControl()) -> (CopyOutcome, [OperationProgress])
    {
        let walk = OperationPlanner(fileSystem: system).walk(tree)
        var reports: [OperationProgress] = []
        let outcome = TreeCopier(fileSystem: system).copy(
            [walk], into: destination, control: control, resolve: { _ in ConflictAnswer(.stop) }
        ) { reports.append($0) }
        return (outcome, reports)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: copy.appendingPathComponent(path).path)
    }

    @Test func aTreeCopiesWithLinksAndFolderDates() throws {
        defer { cleanUp() }
        let (outcome, reports) = run()
        #expect(outcome.failures.isEmpty && !outcome.wasCancelled)
        #expect(outcome.created.map(\.copy.path) == [copy.path])
        #expect(outcome.created.first?.source.path == tree.path)
        #expect(outcome.finished.count == 6 && outcome.finished["tree/sub/b.bin"] != nil)
        #expect(try Data(contentsOf: copy.appendingPathComponent("sub/c.bin")).count == 7)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: copy.appendingPathComponent("link").path) == "a.txt")
        let sub = try FileManager.default.attributesOfItem(
            atPath: copy.appendingPathComponent("sub").path)
        #expect(sub[.modificationDate] as? Date == old)
        let last = try #require(reports.last)
        #expect(last.bytesDone == 15 && last.bytesTotal == 15)
        #expect(last.itemsDone == 6 && last.itemsTotal == 6)
    }

    @Test func aFailedFileLeavesTheOthers() {
        defer { cleanUp() }
        system.failCopy(endingWith: "sub/b.bin", errno: ENOSPC)
        let (outcome, _) = run()
        #expect(outcome.failures.map(\.errno) == [ENOSPC])
        #expect(!exists("sub/b.bin") && exists("sub/c.bin") && exists("a.txt"))
    }

    @Test func aFolderThatCantBeMadeTakesItsContents() {
        defer { cleanUp() }
        system.failMakingFolder(endingWith: "tree/sub", errno: EACCES)
        let (outcome, _) = run()
        #expect(outcome.failures.map(\.errno) == [EACCES])
        #expect(!system.copied.contains { $0.contains("/sub/") })
        #expect(exists("a.txt"))
    }

    @Test func unreadableItemsAreFailures() throws {
        defer { cleanUp() }
        var walk = OperationPlanner(fileSystem: system).walk(tree)
        walk.unreadable.append(FileSystemError("list", "/somewhere", errno: EACCES))
        let outcome = TreeCopier(fileSystem: system).copy(
            [walk], into: destination, control: OperationControl(),
            resolve: { _ in ConflictAnswer(.stop) }
        ) { _ in }
        #expect(outcome.failures.map(\.path) == ["/somewhere"])
    }

    @Test func cancellingStopsWithinAFileAndRemovesItsPartialCopy() {
        defer { cleanUp() }
        let control = OperationControl()
        system.reportChunks(3) { path, chunk in
            if path.hasSuffix("sub/b.bin"), chunk == 1 { control.cancel() }
        }
        let (outcome, _) = run(control)
        #expect(outcome.wasCancelled && outcome.failures.isEmpty)
        #expect(!exists("sub/b.bin") && !exists("sub/c.bin"))
        #expect(exists("a.txt"))
        #expect(!system.copied.contains { $0.hasSuffix("sub/c.bin") })
    }

    /// A pause inside a file holds the copy there until it's resumed.
    @Test func aPauseHoldsTheCopy() async {
        defer { cleanUp() }
        let control = OperationControl()
        let paused = DispatchSemaphore(value: 0)
        system.reportChunks(2) { path, chunk in
            guard path.hasSuffix("a.txt"), chunk == 0 else { return }
            control.pause()
            paused.signal()
        }
        let copier = TreeCopier(fileSystem: system)
        let walk = OperationPlanner(fileSystem: system).walk(tree)
        let destination = destination
        let task = Task.detached {
            copier.copy(
                [walk], into: destination, control: control, resolve: { _ in ConflictAnswer(.stop) }
            ) { _ in }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                paused.wait()
                continuation.resume()
            }
        }
        #expect(control.isPaused && !exists("sub/c.bin"))
        control.resume()
        let outcome = await task.value
        #expect(outcome.failures.isEmpty && exists("sub/c.bin"))
    }
}
