import Foundation
import Testing

@testable import TwinPanesCore

/// The fault-injection gate for saving (PLAN.md §7): a kill or a power loss at every
/// operation of strategies A and B leaves the file with either its old or its new
/// contents, after recovery's rollback.
struct SaveFaultTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("SaveFaultTests-\(UUID().uuidString)")
    let original = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    /// A fresh copy of the file (hard-linked for strategy B), its edited version and plan.
    func prepare(inPlace: Bool) throws -> (URL, EditSnapshot, SavePlan, Data) {
        let url = folder.appendingPathComponent("file.bin")
        let link = folder.appendingPathComponent("link.bin")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: link)
        try original.write(to: url)
        if inPlace { try FileManager.default.linkItem(at: url, to: link) }
        let buffer = EditBuffer(original: try ByteSource(url: url))
        let opened = buffer.tree
        try buffer.overwrite(at: 5, with: Data([0xAA, 0xBB]))
        try buffer.overwrite(at: 69_990, with: Data(repeating: 0xCC, count: 10))
        let snapshot = buffer.snapshot()
        let plan = SavePlan(saved: opened, current: buffer.tree, diskMatchesSaved: true)
        return (url, snapshot, plan, try snapshot.read(0..<70_000))
    }

    @Test(arguments: [false, true], [false, true])
    func everyCrashLeavesOldOrNew(inPlace: Bool, powerLoss: Bool) throws {
        defer { cleanUp() }
        let journal = folder.appendingPathComponent(SaveJournal.fileName)
        var crashes = 0
        for n in 1...80 {
            let (url, snapshot, plan, edited) = try prepare(inPlace: inPlace)
            let fs = CrashingFileSystem(crashAt: n)
            let saved = try? Saver(fileSystem: fs).save(
                snapshot, plan: plan, to: url, inPlaceJournal: inPlace ? journal : nil)
            guard fs.crashed else {
                #expect(try saved != nil && Data(contentsOf: url) == edited)
                break
            }
            crashes += 1
            if powerLoss { fs.powerLoss() }
            try SaveJournal.rollBackIfNeeded(journal, fileSystem: RealFileSystem())  // relaunch
            let disk = try Data(contentsOf: url)
            #expect(
                disk == original || disk == edited,
                "in place \(inPlace), power loss \(powerLoss), crash at operation \(n)")
        }
        #expect(crashes >= 5)  // the save really went through several crash points
    }
}
