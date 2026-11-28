import Foundation

/// A session's operation journal on disk (docs/plans/M3c.md, D-e): `journal.bin` in its
/// folder. Each record is written at once, which survives the app being killed; flushing
/// to the drive (`F_FULLFSYNC`, add buffer first) waits up to a second, or happens at a
/// save or close, which bounds what a power loss can take.
@MainActor
final class SessionJournal {
    static let fileName = "journal.bin"

    /// Replace records written so far; a `saved` record refers to a count of them.
    private(set) var replaceCount: UInt64 = 0
    private let fileSystem: any FileSystem
    private let add: AddBuffer
    private let path: String
    private var descriptor: Int32?
    private var length: UInt64 = 0
    private var flushPending = false

    init(folder: SessionFolder, add: AddBuffer, fileSystem: any FileSystem) throws {
        let url = folder.file(Self.fileName)
        self.fileSystem = fileSystem
        self.add = add
        path = url.path
        descriptor = try fileSystem.create(url)
    }

    /// Reopens the journal of a recovered session: its first `validLength` bytes hold
    /// `records` (a torn tail is cut off), and new records follow them.
    init(
        reopening folder: SessionFolder, records: [JournalRecord], validLength: Int,
        add: AddBuffer, fileSystem: any FileSystem
    ) throws {
        let url = folder.file(Self.fileName)
        self.fileSystem = fileSystem
        self.add = add
        path = url.path
        let descriptor = try fileSystem.openForWriting(url)
        do {
            try fileSystem.truncate(descriptor, to: UInt64(validLength), path: path)
        } catch {
            fileSystem.close(descriptor)
            throw error
        }
        self.descriptor = descriptor
        length = UInt64(validLength)
        replaceCount = UInt64(records.count { if case .replace = $0 { true } else { false } })
    }

    /// Records what changed between `old` and `new` (an edit, undo, redo or revert): a
    /// record per changed range when the length stays, else one record for the stretch
    /// between what both share at the start and at the end (docs/plans/M8.md, D-c).
    func record(from old: PieceTree, to new: PieceTree) throws {
        guard old.length != new.length else {
            for range in SavePlan.changedRanges(from: old, to: new) {
                try append(.replace(range, new.pieces(in: range)))
                replaceCount += 1
            }
            return flushSoon()
        }
        let (prefix, suffix) = Self.sharedEnds(old, new)
        try append(
            .replace(
                prefix..<(old.length - suffix), new.pieces(in: prefix..<(new.length - suffix))))
        replaceCount += 1
        flushSoon()
    }

    /// How many bytes `a` and `b` take from the same places at their start and, after
    /// that, at their end.
    static func sharedEnds(_ a: PieceTree, _ b: PieceTree) -> (prefix: UInt64, suffix: UInt64) {
        let (piecesA, piecesB) = (a.pieces(in: 0..<a.length), b.pieces(in: 0..<b.length))
        let prefix = sharedRun(piecesA, piecesB) { $0.offset + $1 }
        let suffix = sharedRun(piecesA.reversed(), piecesB.reversed()) {
            $0.offset + $0.length - $1
        }
        return (prefix, min(suffix, min(a.length, b.length) - prefix))
    }

    /// Walks two piece lists side by side from their first pieces while each step takes
    /// its bytes from the same source and place, and returns how many bytes that is.
    /// `place` gives where a piece's byte lies `into` bytes from the walk's side.
    private static func sharedRun(
        _ a: some Sequence<Piece>, _ b: some Sequence<Piece>,
        place: (Piece, UInt64) -> UInt64
    ) -> UInt64 {
        var (iteratorA, iteratorB) = (a.makeIterator(), b.makeIterator())
        var (pieceA, pieceB) = (iteratorA.next(), iteratorB.next())
        var intoA: UInt64 = 0, intoB: UInt64 = 0, shared: UInt64 = 0
        while let pa = pieceA, let pb = pieceB, pa.source == pb.source,
            place(pa, intoA) == place(pb, intoB)
        {
            let step = min(pa.length - intoA, pb.length - intoB)
            shared += step
            intoA += step
            intoB += step
            if intoA == pa.length { (pieceA, intoA) = (iteratorA.next(), 0) }
            if intoB == pb.length { (pieceB, intoB) = (iteratorB.next(), 0) }
        }
        return shared
    }

    /// Records that the version after `replaceCount` replace records is on disk, and
    /// flushes.
    func recordSaved(after replaceCount: UInt64) throws {
        try append(.saved(replaceCount))
        try flush()
    }

    /// Flushes the add buffer, then the journal, to the drive.
    func flush() throws {
        flushPending = false
        guard let descriptor else { return }
        try add.sync()
        try fileSystem.fullSync(descriptor, path: path)
    }

    /// Writes `closed`, flushes and closes the file.
    func close() {
        guard let descriptor else { return }
        try? append(.closed)
        try? flush()
        fileSystem.close(descriptor)
        self.descriptor = nil
    }

    private func append(_ record: JournalRecord) throws {
        guard let descriptor else { return }
        let data = JournalFormat.encode(record)
        try fileSystem.write(data, to: descriptor, at: length, path: path)
        length += UInt64(data.count)
    }

    /// A flush within a second of the first unflushed record.
    private func flushSoon() {
        guard !flushPending else { return }
        flushPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.flushPending else { return }
            try? self.flush()
        }
    }
}
