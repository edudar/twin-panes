import Foundation
import Testing

@testable import TwinPanesCore

/// A session's journal, replayed, gives back the session (M3c step 5).
@MainActor
@Suite struct SessionJournalTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionJournalTests-\(UUID().uuidString)")
    let url: URL

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("file.bin")
        try Data((0..<200).map { UInt8($0) }).write(to: url)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    func replayed(_ session: EditorSession) throws -> (tree: PieceTree, saved: PieceTree) {
        let made = try #require(session.folder)
        let data = try Data(contentsOf: made.file(SessionJournal.fileName))
        let decoded = JournalFormat.decode(data)
        #expect(decoded.validLength == data.count)
        return JournalFormat.replay(decoded.records, originalLength: session.buffer.original.length)
    }

    func bytes(_ session: EditorSession, _ tree: PieceTree) throws -> Data {
        try EditSnapshot(tree: tree, original: session.buffer.original, add: session.buffer.add)
            .read(0..<tree.length)
    }

    /// Random edits, undos, redos, reverts and saves; after each step the journal on disk
    /// replays to the live tree and the saved one.
    @Test func replayMatchesARandomSession() async throws {
        defer { cleanUp() }
        let seed: UInt64 = 0x10E7_5EED_0000_0005
        var rng = SplitMix64(seed: seed)
        let session = try EditorSession(
            url: url, sessionsRoot: folder.appendingPathComponent("Sessions"))
        for step in 0..<150 {
            let context: Comment = "seed \(seed), step \(step)"
            switch Int.random(in: 0..<10, using: &rng) {
            case 0..<5:
                let offset = UInt64.random(in: 0..<200, using: &rng)
                let count = Int.random(in: 1...min(5, 200 - Int(offset)), using: &rng)
                let typed = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
                try session.overwrite(
                    typed, at: offset, selectionBefore: offset..<(offset + 1),
                    selectionAfter: offset..<(offset + 1), coalescing: Bool.random(using: &rng))
            case 5, 6: _ = session.undo()
            case 7: _ = session.redo()
            case 8 where step % 3 == 0: session.revert()
            default: try await session.save()
            }
            guard session.folder != nil else { continue }  // nothing typed yet
            let (tree, saved) = try replayed(session)
            #expect(try bytes(session, tree) == session.snapshot.read(0..<200), context)
            #expect(try bytes(session, saved) == bytes(session, session.savedTree), context)
        }
    }

    /// The journal records that the session closed cleanly.
    @Test func closingIsRecorded() throws {
        defer { cleanUp() }
        let session = try EditorSession(
            url: url, sessionsRoot: folder.appendingPathComponent("Sessions"))
        try session.overwrite(Data([1]), at: 0, selectionBefore: 0..<1, selectionAfter: 1..<2)
        let journal = try #require(session.folder).file(SessionJournal.fileName)
        // close() deletes the folder; a hard link keeps the journal to read afterwards.
        let kept = folder.appendingPathComponent("kept.bin")
        try FileManager.default.linkItem(at: journal, to: kept)
        session.close()
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        let records = JournalFormat.decode(try Data(contentsOf: kept)).records
        #expect(records.count == 2 && records.last == .closed)
    }
}
