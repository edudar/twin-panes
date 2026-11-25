import Foundation
import Testing

@testable import TwinPanesCore

/// Putting items back where they were, for undo (docs/plans/M6.md, D-g, step 11).
@Suite struct PutBackTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PutBackTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let system = ScriptedFileOperationSystem()

    /// away/ renamed.txt ("mine"), away/docs/ x.txt
    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("away/docs"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: url("away/renamed.txt"))
        try Data("x".utf8).write(to: url("away/docs/x.txt"))
        system.useTrash(root.appendingPathComponent("Trash", isDirectory: true))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    func read(_ path: String) -> String? {
        (try? Data(contentsOf: url(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func putBack(_ items: [MovedItem], answers: [ConflictAnswer] = []) -> MoveOutcome {
        var remaining = answers
        return PutBack(fileSystem: system).putBack(
            items, control: OperationControl(),
            resolve: { _ in remaining.isEmpty ? ConflictAnswer(.stop) : remaining.removeFirst() },
            progress: { _ in })
    }

    @Test func itemsGoBackUnderTheirOldNames() {
        defer { cleanUp() }
        let outcome = putBack([
            MovedItem(from: url("home/original.txt"), to: url("away/renamed.txt")),
            MovedItem(from: url("home/docs"), to: url("away/docs")),
        ])
        #expect(outcome.failures.isEmpty && outcome.moved.count == 2)
        #expect(read("home/original.txt") == "mine" && read("home/docs/x.txt") == "x")
        #expect(read("away/renamed.txt") == nil)
    }

    @Test func aTakenPlaceIsAConflict() throws {
        defer { cleanUp() }
        try Data("new".utf8).write(to: url("home/original.txt"))
        let item = MovedItem(from: url("home/original.txt"), to: url("away/renamed.txt"))
        let outcome = putBack([item], answers: [ConflictAnswer(.keepBoth)])
        #expect(read("home/original.txt") == "new" && read("home/original 2.txt") == "mine")
        #expect(outcome.moved.map(\.to.lastPathComponent) == ["original 2.txt"])
    }

    @Test func replaceTrashesWhatTookThePlace() throws {
        defer { cleanUp() }
        try Data("new".utf8).write(to: url("home/original.txt"))
        let item = MovedItem(from: url("home/original.txt"), to: url("away/renamed.txt"))
        let outcome = putBack([item], answers: [ConflictAnswer(.replace)])
        #expect(read("home/original.txt") == "mine" && outcome.replaced.count == 1)
    }

    @Test func acrossVolumesItIsMovedBack() {
        defer { cleanUp() }
        system.failRename(endingWith: "away/docs", errno: EXDEV)
        let outcome = putBack([MovedItem(from: url("home/docs"), to: url("away/docs"))])
        #expect(outcome.failures.isEmpty && read("home/docs/x.txt") == "x")
        #expect(!FileManager.default.fileExists(atPath: url("away/docs").path))
    }

    /// Across volumes a renamed item can't go back under another name in one step.
    @Test func acrossVolumesUnderAnotherNameIsAFailure() {
        defer { cleanUp() }
        system.failRename(endingWith: "away/renamed.txt", errno: EXDEV)
        let outcome = putBack([
            MovedItem(from: url("home/original.txt"), to: url("away/renamed.txt"))
        ])
        #expect(outcome.failures.map(\.errno) == [EXDEV] && read("away/renamed.txt") == "mine")
    }
}
