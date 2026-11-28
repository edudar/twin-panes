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

    /// The records in the session's journal so far.
    func records(_ session: EditorSession) throws -> [JournalRecord] {
        let made = try #require(session.folder)
        return JournalFormat.decode(try Data(contentsOf: made.file(SessionJournal.fileName)))
            .records
    }

    /// Moves the session to `tree` as an edit, undo or redo does, journaling the change.
    func move(_ session: EditorSession, to tree: PieceTree) {
        let old = session.buffer.tree
        session.buffer.restore(tree)
        session.journalChange(from: old)
    }

    /// A change of length is one record: the stretch between what both versions share at
    /// the start and at the end, replaced by the new version's pieces there.
    @Test func aLengthChangeIsOneRecordOfWhatDiffers() throws {
        defer { cleanUp() }
        let session = try EditorSession(
            url: url, sessionsRoot: folder.appendingPathComponent("Sessions"))
        try session.overwrite(Data([1, 2]), at: 0, selectionBefore: 0..<1, selectionAfter: 2..<3)
        let typed = session.buffer.tree
        let inserted = Piece(.add, offset: 0, length: 2)
        move(session, to: typed.inserting(inserted, at: 50))
        #expect(try records(session).last == .replace(50..<50, [inserted]))
        move(session, to: session.buffer.tree.removing(10..<20))
        #expect(try records(session).last == .replace(10..<20, []))
        // Undo of both (192 bytes back to 200): what lies between the shared start
        // (10 bytes) and the shared end (the original from 50 on) is one record.
        move(session, to: typed)
        #expect(
            try records(session).last
                == .replace(10..<42, [Piece(.original, offset: 10, length: 40)]))
    }

    /// Random inserts, deletes, overwrites and jumps through the history; after each step
    /// the journal on disk replays to the live tree.
    @Test func replayMatchesRandomLengthChanges() throws {
        defer { cleanUp() }
        let seed: UInt64 = 0x10E7_5EED_0000_0008
        var rng = SplitMix64(seed: seed)
        let session = try EditorSession(
            url: url, sessionsRoot: folder.appendingPathComponent("Sessions"))
        try session.overwrite(
            Data(repeating: 7, count: 8), at: 0, selectionBefore: 0..<1, selectionAfter: 8..<9)
        var history = [session.buffer.tree]
        func randomPiece() -> Piece {
            let (source, size): (Piece.Source, UInt64) =
                Bool.random(using: &rng) ? (.original, 200) : (.add, 8)
            let offset = UInt64.random(in: 0..<size, using: &rng)
            let count = UInt64.random(in: 1...min(6, size - offset), using: &rng)
            return Piece(source, offset: offset, length: count)
        }
        for step in 0..<300 {
            let context: Comment = "seed \(seed), step \(step)"
            let tree = session.buffer.tree
            let length = tree.length
            var next: PieceTree
            switch Int.random(in: 0..<4, using: &rng) {
            case 0:
                next = tree.inserting(
                    randomPiece(), at: UInt64.random(in: 0...length, using: &rng))
            case 1 where length > 0:
                let offset = UInt64.random(in: 0..<length, using: &rng)
                let count = UInt64.random(in: 1...min(6, length - offset), using: &rng)
                next = tree.removing(offset..<(offset + count))
            case 2 where length > 0:
                let piece = randomPiece()
                let offset = UInt64.random(
                    in: 0...(length - min(length, piece.length)), using: &rng)
                next = tree.replacing(offset..<min(length, offset + piece.length), with: piece)
            default:
                next = history[Int.random(in: 0..<history.count, using: &rng)]
            }
            move(session, to: next)
            history.append(next)
            let (replayed, _) = try replayed(session)
            #expect(try bytes(session, replayed) == bytes(session, next), context)
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
