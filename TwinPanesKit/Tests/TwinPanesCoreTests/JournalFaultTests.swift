import Foundation
import Testing

@testable import TwinPanesCore

/// The fault-injection gate for the journal (PLAN.md §7): a session crashed at every
/// file operation of a scripted run comes back from its folder as a state it really
/// passed through: after a kill, the last one before the crash; after a power loss, one
/// no older than its last save.
@MainActor
@Suite struct JournalFaultTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("JournalFaultTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    @Test(arguments: [false, true])
    func everyCrashRecoversAStateTheSessionHad(powerLoss: Bool) async throws {
        defer { cleanUp() }
        var crashes = 0
        for n in 1...60 {
            let run = folder.appendingPathComponent("run-\(n)")
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            let url = run.appendingPathComponent("file.bin")
            try Data((0..<200).map { UInt8($0) }).write(to: url)
            let fs = CrashingFileSystem(crashAt: n)
            let session = try EditorSession(
                url: url, saver: Saver(fileSystem: fs),
                sessionsRoot: run.appendingPathComponent("Sessions"))

            // The script; `reached` keeps the states completed before the crash.
            var reached = [try session.snapshot.read(0..<200)]
            var saving: Data?  // the version the save writes
            for step in 0..<8 {
                switch step {
                case 3: _ = session.undo()
                case 5:
                    saving = reached.last
                    _ = try? await session.save()
                default:
                    let at = UInt64(step * 20)
                    try? session.overwrite(
                        Data([UInt8(0xA0 + step)]), at: at, selectionBefore: at..<(at + 1),
                        selectionAfter: at..<(at + 1))
                }
                guard !fs.crashed else { break }
                reached.append(try session.snapshot.read(0..<200))
            }
            guard fs.crashed else { break }  // the script ran clean: every point tried
            crashes += 1
            let context: Comment = "power loss \(powerLoss), crash at operation \(n)"
            guard let made = session.folder, !session.isNarrowed else { continue }
            if powerLoss { fs.powerLoss() }
            let copy = run.appendingPathComponent("crashed")
            try FileManager.default.copyItem(at: made.url, to: copy)
            session.close()

            guard
                let recovered = try? EditorSession(recovering: SessionFolder(url: copy))
            else {
                // Only a crash before the journal existed leaves nothing to recover.
                #expect(reached.count <= 1, context)
                continue
            }
            let bytes = try recovered.snapshot.read(0..<200)
            if powerLoss {
                #expect(reached.contains(bytes), context)
            } else {
                #expect(bytes == reached.last, context)
            }
            let saved = EditSnapshot(
                tree: recovered.savedTree, original: recovered.buffer.original,
                add: recovered.buffer.add)
            // The journal never claims a save the file doesn't hold.
            let savedBytes = try saved.read(0..<200)
            let disk = try Data(contentsOf: url)
            #expect(
                savedBytes == reached[0] || (savedBytes == saving && disk == saving), context)
        }
        #expect(crashes >= 5)
    }
}
