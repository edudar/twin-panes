import Foundation
import Testing

@testable import TwinPanesCore

/// Moving on one volume and across (docs/plans/M6.md, D-c, step 8).
@Suite struct TreeMoverTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TreeMoverTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let system = ScriptedFileOperationSystem()

    /// src/ a.txt (3 bytes), docs/ x.txt (5), docs/y.txt (7); dest/ empty
    var source: URL { root.appendingPathComponent("src", isDirectory: true) }
    var destination: URL { root.appendingPathComponent("dest", isDirectory: true) }

    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: source.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: source.appendingPathComponent("a.txt"))
        try Data(count: 5).write(to: source.appendingPathComponent("docs/x.txt"))
        try Data(count: 7).write(to: source.appendingPathComponent("docs/y.txt"))
        system.useTrash(root.appendingPathComponent("Trash", isDirectory: true))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func move(
        _ names: [String], control: OperationControl = OperationControl(),
        answers: [ConflictAnswer] = []
    ) -> MoveOutcome {
        var remaining = answers
        return TreeMover(fileSystem: system).move(
            names.map { source.appendingPathComponent($0) }, into: destination,
            control: control,
            resolve: { _ in remaining.isEmpty ? ConflictAnswer(.stop) : remaining.removeFirst() },
            progress: { _ in })
    }

    @Test func onOneVolumeItemsAreRenamed() {
        defer { cleanUp() }
        let outcome = move(["a.txt", "docs"])
        #expect(outcome.failures.isEmpty && system.copied.isEmpty)
        #expect(exists("dest/a.txt") && exists("dest/docs/y.txt") && !exists("src/docs"))
        #expect(outcome.moved.map(\.to.lastPathComponent) == ["a.txt", "docs"])
        #expect(outcome.moved.first?.from.lastPathComponent == "a.txt")
    }

    @Test func acrossVolumesItemsAreCopiedThenRemoved() {
        defer { cleanUp() }
        system.failRename(endingWith: "src/docs", errno: EXDEV)
        let outcome = move(["a.txt", "docs"])
        #expect(outcome.failures.isEmpty)
        #expect(system.copied.count == 2)
        #expect(exists("dest/docs/x.txt") && exists("dest/docs/y.txt") && !exists("src/docs"))
        #expect(Set(outcome.moved.map(\.to.lastPathComponent)) == ["a.txt", "docs"])
    }

    @Test func aFileThatFailsToCopyKeepsItsSourceAndFolder() {
        defer { cleanUp() }
        system.failRename(endingWith: "src/docs", errno: EXDEV)
        system.failCopy(endingWith: "docs/x.txt", errno: ENOSPC)
        let outcome = move(["docs"])
        #expect(outcome.failures.map(\.errno) == [ENOSPC])
        #expect(exists("src/docs/x.txt") && !exists("src/docs/y.txt"))
        #expect(exists("dest/docs/y.txt") && !exists("dest/docs/x.txt"))
    }

    /// A copy that ends up the wrong size isn't trusted: its source stays.
    @Test func aShortCopyKeepsItsSource() {
        defer { cleanUp() }
        system.failRename(endingWith: "src/a.txt", errno: EXDEV)
        system.truncateCopies(endingWith: "a.txt")
        let outcome = move(["a.txt"])
        #expect(outcome.failures.map(\.errno) == [EIO])
        #expect(exists("src/a.txt") && outcome.moved.isEmpty)
    }

    @Test func aTakenNameIsSettledByTheUser() throws {
        defer { cleanUp() }
        try Data("old".utf8).write(to: destination.appendingPathComponent("a.txt"))
        let outcome = move(["a.txt"], answers: [ConflictAnswer(.replace)])
        #expect(!exists("src/a.txt"))
        #expect(try Data(contentsOf: destination.appendingPathComponent("a.txt")).count == 3)
        #expect(outcome.replaced.count == 1 && outcome.moved.count == 1)
    }

    @Test func skippedItemsStayWhereTheyWere() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("docs/x.txt"))
        _ = move(["docs"], answers: [ConflictAnswer(.merge), ConflictAnswer(.skip)])
        #expect(exists("src/docs/x.txt") && !exists("src/docs/y.txt"))
        #expect(exists("dest/docs/y.txt"))
    }

    /// Cancelled halfway across volumes, every file is in one place or the other.
    @Test func aCancelledMoveLosesNothing() {
        defer { cleanUp() }
        system.failRename(endingWith: "src/docs", errno: EXDEV)
        let control = OperationControl()
        system.reportChunks(2) { path, chunk in
            if path.hasSuffix("docs/y.txt"), chunk == 1 { control.cancel() }
        }
        let outcome = move(["docs"], control: control)
        #expect(outcome.wasCancelled)
        #expect(exists("dest/docs/x.txt") && !exists("src/docs/x.txt"))
        #expect(exists("src/docs/y.txt") && !exists("dest/docs/y.txt"))
    }
}
