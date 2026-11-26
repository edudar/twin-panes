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

    @Test func mergeFolderConflictMovesContentsBackAndRemovesEmptiedFolder() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(
            at: url("home/docs"), withIntermediateDirectories: true)
        try Data("home".utf8).write(to: url("home/docs/existing.txt"))
        try Data("away y".utf8).write(to: url("away/docs/y.txt"))

        let outcome = putBack(
            [MovedItem(from: url("home/docs"), to: url("away/docs"))],
            answers: [ConflictAnswer(.merge)])
        #expect(outcome.failures.isEmpty)
        #expect(read("home/docs/existing.txt") == "home")
        #expect(read("home/docs/x.txt") == "x" && read("home/docs/y.txt") == "away y")
        #expect(!FileManager.default.fileExists(atPath: url("away/docs").path))
    }

    @Test func applyToAllAppliesAcrossMultipleConflicts() throws {
        defer { cleanUp() }
        try Data("old a".utf8).write(to: url("home/a.txt"))
        try Data("old b".utf8).write(to: url("home/b.txt"))
        try Data("new a".utf8).write(to: url("away/a.txt"))
        try Data("new b".utf8).write(to: url("away/b.txt"))

        var asked: [Conflict] = []
        let outcome = PutBack(fileSystem: system).putBack(
            [
                MovedItem(from: url("home/a.txt"), to: url("away/a.txt")),
                MovedItem(from: url("home/b.txt"), to: url("away/b.txt")),
            ],
            control: OperationControl(),
            resolve: { conflict in
                asked.append(conflict)
                return ConflictAnswer(.replace, applyToAll: true)
            },
            progress: { _ in })
        #expect(asked.count == 1 && outcome.replaced.count == 2)
        #expect(read("home/a.txt") == "new a" && read("home/b.txt") == "new b")
    }

    @Test func crossVolumePutBackReportsProgressAndPropagatesCancellation() throws {
        defer { cleanUp() }
        try Data("y".utf8).write(to: url("away/docs/y.txt"))
        system.failRename(endingWith: "away/docs", errno: EXDEV)

        var reports: [OperationProgress] = []
        let completed = PutBack(fileSystem: system).putBack(
            [MovedItem(from: url("home/docs"), to: url("away/docs"))],
            control: OperationControl(),
            resolve: { _ in ConflictAnswer(.stop) },
            progress: { reports.append($0) })
        #expect(completed.failures.isEmpty)
        #expect(reports.count >= 3)
        #expect(reports.last?.itemsDone == 3 && reports.last?.itemsTotal == 3)

        // Recreate away/docs for cancellation test.
        try FileManager.default.createDirectory(
            at: url("away/docs"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url("away/docs/x.txt"))
        try Data("y".utf8).write(to: url("away/docs/y.txt"))
        let control = OperationControl()
        system.reportChunks(2) { path, chunk in
            if path.hasSuffix("docs/y.txt"), chunk == 1 { control.cancel() }
        }
        let cancelled = PutBack(fileSystem: system).putBack(
            [
                MovedItem(from: url("home/sub/docs"), to: url("away/docs")),
                MovedItem(from: url("home/original.txt"), to: url("away/renamed.txt")),
            ],
            control: control,
            resolve: { _ in ConflictAnswer(.stop) },
            progress: { _ in })
        #expect(cancelled.wasCancelled)
        #expect(read("away/renamed.txt") == "mine" && read("home/original.txt") == nil)
    }

    @Test func symlinkedSameEntryIsNoOpWhileCaseOnlyPutBackRenames() throws {
        defer { cleanUp() }
        let symAway = root.appendingPathComponent("away-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: symAway.path, withDestinationPath: url("away").path)
        let same = putBack([
            MovedItem(
                from: symAway.appendingPathComponent("renamed.txt"), to: url("away/renamed.txt"))
        ])
        #expect(same.moved.isEmpty && same.failures.isEmpty && read("away/renamed.txt") == "mine")

        let caseOutcome = putBack([
            MovedItem(from: url("away/RENAMED.txt"), to: url("away/renamed.txt"))
        ])
        #expect(caseOutcome.failures.isEmpty && caseOutcome.moved.count == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: url("away").path)
        #expect(names.contains("RENAMED.txt"))
    }
}
