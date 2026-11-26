import Foundation
import Testing

@testable import TwinPanesCore

/// Trash, permanent delete, rename and new folder (docs/plans/M6.md, D-c, step 9).
@Suite struct SingleStepOperationTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SingleStepOperationTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let system = ScriptedFileOperationSystem()

    /// a.txt, b.txt, docs/ x.txt, docs/deep/ y.txt
    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("docs/deep"), withIntermediateDirectories: true)
        for path in ["a.txt", "b.txt", "docs/x.txt", "docs/deep/y.txt"] {
            try Data(path.utf8).write(to: root.appendingPathComponent(path))
        }
        system.useTrash(root.appendingPathComponent(".Trash", isDirectory: true))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }

    @Test func trashingRecordsWhereEachItemWent() throws {
        defer { cleanUp() }
        system.failTrash(endingWith: "/b.txt", errno: ENOTSUP)
        let outcome = Trasher(fileSystem: system).trash(
            [url("a.txt"), url("b.txt"), url("docs")], control: OperationControl()
        ) { _ in }
        #expect(outcome.failures.map(\.errno) == [ENOTSUP])
        #expect(outcome.trashed.map(\.original.lastPathComponent) == ["a.txt", "docs"])
        #expect(!exists("a.txt") && exists("b.txt") && !exists("docs"))
        let docs = try #require(outcome.trashed.last)
        #expect(
            FileManager.default.fileExists(
                atPath: docs.trashed.appendingPathComponent("deep/y.txt").path))
    }

    @Test func removingDeletesTreesDeepestFirst() {
        defer { cleanUp() }
        var reports: [OperationProgress] = []
        let outcome = TreeRemover(fileSystem: system).remove(
            [url("docs"), url("a.txt")], control: OperationControl()
        ) { reports.append($0) }
        #expect(outcome.failures.isEmpty && !exists("docs") && !exists("a.txt"))
        #expect(outcome.removed.map(\.lastPathComponent) == ["docs", "a.txt"])
        #expect(reports.last?.itemsDone == 5 && reports.last?.itemsTotal == 5)
    }

    @Test func anItemThatWontGoKeepsItsFolders() {
        defer { cleanUp() }
        system.failRemove(endingWith: "deep/y.txt", errno: EPERM)
        let outcome = TreeRemover(fileSystem: system).remove(
            [url("docs")], control: OperationControl()
        ) { _ in }
        #expect(outcome.failures.map(\.errno) == [EPERM])
        #expect(exists("docs/deep/y.txt") && !exists("docs/x.txt") && outcome.removed.isEmpty)
    }

    @Test func aCancelledRemoveStops() {
        defer { cleanUp() }
        let control = OperationControl()
        control.cancel()
        let outcome = TreeRemover(fileSystem: system).remove([url("a.txt")], control: control) {
            _ in
        }
        #expect(outcome.wasCancelled && exists("a.txt"))
    }

    @Test func renameKeepsTheItemInItsFolder() throws {
        defer { cleanUp() }
        let namer = ItemNamer(fileSystem: system)
        let moved = try namer.rename(url("a.txt"), to: "c.txt")
        #expect(moved.from.lastPathComponent == "a.txt" && moved.to.path == url("c.txt").path)
        #expect(exists("c.txt") && !exists("a.txt"))
    }

    @Test func renameRefusesBadOrTakenNames() {
        defer { cleanUp() }
        let namer = ItemNamer(fileSystem: system)
        #expect(throws: NameRefusal.empty) { try namer.rename(url("a.txt"), to: "") }
        #expect(throws: NameRefusal.notAName) { try namer.rename(url("a.txt"), to: "x/y") }
        #expect(throws: NameRefusal.notAName) { try namer.rename(url("a.txt"), to: "a\0b") }
        #expect(throws: NameRefusal.notAName) { try namer.rename(url("a.txt"), to: ".") }
        #expect(throws: NameRefusal.notAName) { try namer.rename(url("a.txt"), to: "..") }
        #expect(throws: NameRefusal.tooLong) {
            try namer.rename(url("a.txt"), to: String(repeating: "é", count: 128))
        }
        #expect(throws: NameRefusal.taken(url("b.txt"))) {
            try namer.rename(url("a.txt"), to: "b.txt")
        }
        #expect(throws: NameRefusal.taken(url("a.txt"))) {
            try namer.rename(url("a.txt"), to: "a.txt")
        }
        #expect(exists("a.txt") && exists("b.txt"))
    }

    @Test func caseOnlyRenameSucceedsOnCaseInsensitiveVolume() throws {
        defer { cleanUp() }
        let namer = ItemNamer(fileSystem: system)
        let moved = try namer.rename(url("a.txt"), to: "A.txt")
        #expect(moved.to.lastPathComponent == "A.txt")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names.contains("A.txt") && !names.contains("a.txt"))
    }

    @Test func aNewFolderIsMadeOnlyUnderAFreeName() throws {
        defer { cleanUp() }
        let namer = ItemNamer(fileSystem: system)
        let made = try namer.makeFolder(named: "untitled folder", in: root)
        #expect(made.path == url("untitled folder").path && exists("untitled folder"))
        #expect(throws: NameRefusal.taken(url("docs"))) {
            try namer.makeFolder(named: "docs", in: root)
        }
    }
}
