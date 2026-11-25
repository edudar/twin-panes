import Foundation
import Testing

@testable import TwinPanesCore

/// Names taken at the destination (docs/plans/M6.md, D-d, step 7).
@Suite struct ConflictTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConflictTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let system = ScriptedFileOperationSystem()

    /// src/ a.txt ("new"), docs/ x.txt ("new x"), docs/y.txt ("new y")
    /// dest/ a.txt ("old"), docs/ x.txt ("old x"), docs/z.txt ("old z")
    var source: URL { root.appendingPathComponent("src", isDirectory: true) }
    var destination: URL { root.appendingPathComponent("dest", isDirectory: true) }

    init() throws {
        let fm = FileManager.default
        for folder in [source, destination] {
            try fm.createDirectory(
                at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true)
        }
        try write("new", "src/a.txt")
        try write("new x", "src/docs/x.txt")
        try write("new y", "src/docs/y.txt")
        try write("old", "dest/a.txt")
        try write("old x", "dest/docs/x.txt")
        try write("old z", "dest/docs/z.txt")
        system.useTrash(root.appendingPathComponent("Trash", isDirectory: true))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func write(_ text: String, _ path: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    func read(_ path: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    /// Copies `names` from src into `into` (dest by default), answering conflicts from
    /// `answers` in order and recording what was asked.
    func copy(
        _ names: [String], into: URL? = nil, answers: [ConflictAnswer]
    ) -> (CopyOutcome, [Conflict]) {
        let planner = OperationPlanner(fileSystem: system)
        let walks = names.map { planner.walk(source.appendingPathComponent($0)) }
        var asked: [Conflict] = []
        var remaining = answers
        let outcome = TreeCopier(fileSystem: system).copy(
            walks, into: into ?? destination, control: OperationControl(),
            resolve: { conflict in
                asked.append(conflict)
                return remaining.isEmpty ? ConflictAnswer(.stop) : remaining.removeFirst()
            }, progress: { _ in })
        return (outcome, asked)
    }

    @Test func replaceSendsTheOldFileToTheTrash() throws {
        defer { cleanUp() }
        let (outcome, asked) = copy(["a.txt"], answers: [ConflictAnswer(.replace)])
        #expect(asked.map(\.choices) == [[.replace, .skip, .keepBoth, .stop]])
        #expect(read("dest/a.txt") == "new")
        let trashed = try #require(outcome.replaced.first)
        #expect(trashed.original.lastPathComponent == "a.txt")
        #expect(String(decoding: try Data(contentsOf: trashed.trashed), as: UTF8.self) == "old")
    }

    @Test func skipLeavesTheOldFile() {
        defer { cleanUp() }
        let (outcome, _) = copy(["a.txt"], answers: [ConflictAnswer(.skip)])
        #expect(read("dest/a.txt") == "old" && outcome.created.isEmpty)
        #expect(outcome.finished.isEmpty)
    }

    @Test func keepBothCopiesUnderTheNextName() {
        defer { cleanUp() }
        let (outcome, _) = copy(["a.txt"], answers: [ConflictAnswer(.keepBoth)])
        #expect(read("dest/a.txt") == "old" && read("dest/a 2.txt") == "new")
        #expect(outcome.created.map(\.copy.lastPathComponent) == ["a 2.txt"])
    }

    @Test func mergeGoesIntoTheFolderAndAsksPerItem() {
        defer { cleanUp() }
        let (outcome, asked) = copy(
            ["docs"], answers: [ConflictAnswer(.merge), ConflictAnswer(.replace)])
        #expect(asked.first?.choices.first == .merge)
        #expect(asked.map { $0.item.relativePath } == ["docs", "docs/x.txt"])
        #expect(read("dest/docs/x.txt") == "new x" && read("dest/docs/y.txt") == "new y")
        #expect(read("dest/docs/z.txt") == "old z")
        // Undo trashes what the merge added (the replacing x.txt too, before putting the
        // old one back), not the folder that was there.
        #expect(outcome.created.map(\.copy.lastPathComponent) == ["x.txt", "y.txt"])
        #expect(outcome.replaced.map(\.original.lastPathComponent) == ["x.txt"])
    }

    @Test func keepBothOnAFolderCopiesItsContentsUnderTheNewName() {
        defer { cleanUp() }
        let (_, asked) = copy(["docs"], answers: [ConflictAnswer(.keepBoth)])
        #expect(asked.count == 1)
        #expect(read("dest/docs 2/x.txt") == "new x" && read("dest/docs/x.txt") == "old x")
    }

    @Test func applyToAllAnswersTheRestOfTheSameKind() {
        defer { cleanUp() }
        let (_, asked) = copy(
            ["docs", "a.txt"],
            answers: [ConflictAnswer(.merge), ConflictAnswer(.skip, applyToAll: true)])
        // docs (folder), then x.txt (file, answered for all files); a.txt isn't asked.
        #expect(asked.map { $0.item.relativePath } == ["docs", "docs/x.txt"])
        #expect(read("dest/a.txt") == "old" && read("dest/docs/x.txt") == "old x")
    }

    @Test func stopEndsTheCopy() {
        defer { cleanUp() }
        let (outcome, _) = copy(["a.txt", "docs"], answers: [ConflictAnswer(.stop)])
        #expect(outcome.wasCancelled && read("dest/docs/y.txt") == nil)
    }

    @Test func aReplaceThatCantTrashIsAFailure() {
        defer { cleanUp() }
        system.failTrash(endingWith: "dest/a.txt", errno: ENOTSUP)
        let (outcome, _) = copy(["a.txt"], answers: [ConflictAnswer(.replace)])
        #expect(outcome.failures.map(\.errno) == [ENOTSUP] && read("dest/a.txt") == "old")
    }

    @Test func copyingOntoItselfOffersOnlyKeepBothAndSkip() {
        defer { cleanUp() }
        let (_, asked) = copy(["a.txt"], into: source, answers: [ConflictAnswer(.keepBoth)])
        #expect(asked.first?.isSameItem == true)
        #expect(asked.first?.choices == [.keepBoth, .skip, .stop])
        #expect(read("src/a 2.txt") == "new")
    }
}
