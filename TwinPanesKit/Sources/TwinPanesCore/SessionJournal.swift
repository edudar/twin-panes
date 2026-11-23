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

    /// Records what changed between `old` and `new` (an edit, undo, redo or revert).
    func record(from old: PieceTree, to new: PieceTree) throws {
        for range in SavePlan.changedRanges(from: old, to: new) {
            try append(.replace(range, new.pieces(in: range)))
            replaceCount += 1
        }
        flushSoon()
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
