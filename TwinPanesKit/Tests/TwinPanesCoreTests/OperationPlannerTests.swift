import Foundation
import Testing

@testable import TwinPanesCore

/// Checking and walking an operation's sources (docs/plans/M6.md, D-c, step 5).
@Suite struct OperationPlannerTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("OperationPlannerTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let planner = OperationPlanner(fileSystem: RealFileOperationSystem())

    /// tree/ a.txt (3 bytes), sub/ b.bin (5 bytes), Tool.app/ Contents/ x (1 byte),
    /// link -> a.txt
    var tree: URL { root.appendingPathComponent("tree", isDirectory: true) }
    var destination: URL { root.appendingPathComponent("dest", isDirectory: true) }

    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: tree.appendingPathComponent("Tool.app/Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: tree.appendingPathComponent("a.txt"))
        try Data(count: 5).write(to: tree.appendingPathComponent("sub/b.bin"))
        try Data(count: 1).write(to: tree.appendingPathComponent("Tool.app/Contents/x"))
        try fm.createSymbolicLink(
            atPath: tree.appendingPathComponent("link").path, withDestinationPath: "a.txt")
    }

    func cleanUp() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tree.appendingPathComponent("sub").path)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: destination.path)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func aWalkListsFoldersBeforeTheirContents() {
        defer { cleanUp() }
        let walk = planner.walk(tree)
        let paths = walk.items.map(\.relativePath)
        #expect(
            Set(paths) == [
                "tree", "tree/a.txt", "tree/sub", "tree/sub/b.bin", "tree/Tool.app",
                "tree/Tool.app/Contents", "tree/Tool.app/Contents/x", "tree/link",
            ])
        for item in walk.items {
            let parent = (item.relativePath as NSString).deletingLastPathComponent
            guard !parent.isEmpty else { continue }
            #expect(
                paths.firstIndex(of: parent)! < paths.firstIndex(of: item.relativePath)!,
                "\(parent) comes before \(item.relativePath)")
        }
        #expect(walk.totalBytes == 9 && walk.fileCount == 3)
        #expect(walk.unreadable.isEmpty)
    }

    @Test func symlinksAreItemsNotFollowed() {
        defer { cleanUp() }
        let link = planner.walk(tree).items.first { $0.relativePath == "tree/link" }
        #expect(link?.metadata.kind == .symbolicLink && link?.metadata.size == 0)
    }

    @Test func aSingleFileIsItsOwnWalk() {
        defer { cleanUp() }
        let walk = planner.walk(tree.appendingPathComponent("a.txt"))
        #expect(walk.items.map(\.relativePath) == ["a.txt"] && walk.totalBytes == 3)
    }

    @Test func anUnreadableFolderIsReportedAndItsContentsLeftOut() throws {
        defer { cleanUp() }
        let sub = tree.appendingPathComponent("sub")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sub.path)
        let walk = planner.walk(tree)
        #expect(walk.items.contains { $0.relativePath == "tree/sub" })
        #expect(!walk.items.contains { $0.relativePath == "tree/sub/b.bin" })
        #expect(walk.unreadable.map(\.path) == [sub.path] && walk.unreadable.first?.errno == EACCES)
    }

    @Test func aCancelledWalkStopsEarly() {
        defer { cleanUp() }
        var asked = 0
        let walk = planner.walk(tree) {
            asked += 1
            return asked > 1
        }
        #expect(walk.items.count < 8)
    }

    @Test func goodSourcesAndDestinationPass() throws {
        defer { cleanUp() }
        try planner.check(sources: [tree], destination: destination)
        // Copying into the folder that holds it is a conflict, not a refusal (D-d).
        try planner.check(sources: [tree], destination: root)
    }

    @Test func aMissingSourceIsRefused() {
        defer { cleanUp() }
        let gone = root.appendingPathComponent("gone")
        #expect(throws: PlanningRefusal.sourceMissing(gone)) {
            try planner.check(sources: [tree, gone], destination: destination)
        }
    }

    @Test func aFolderIntoItselfOrItsSubfolderIsRefused() {
        defer { cleanUp() }
        #expect(throws: PlanningRefusal.intoItself(tree)) {
            try planner.check(sources: [tree], destination: tree)
        }
        #expect(throws: PlanningRefusal.intoItself(tree)) {
            try planner.check(sources: [tree], destination: tree.appendingPathComponent("sub"))
        }
        // A sibling whose name starts the same isn't inside it.
        let sibling = root.appendingPathComponent("tree2", isDirectory: true)
        try? FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        #expect(throws: Never.self) { try planner.check(sources: [tree], destination: sibling) }
    }

    @Test func aMissingOrReadOnlyDestinationIsRefused() throws {
        defer { cleanUp() }
        let gone = root.appendingPathComponent("nowhere")
        #expect(throws: PlanningRefusal.destinationMissing(gone)) {
            try planner.check(sources: [tree], destination: gone)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: destination.path)
        #expect(throws: PlanningRefusal.destinationNotWritable(destination)) {
            try planner.check(sources: [tree], destination: destination)
        }
    }
}
