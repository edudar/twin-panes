import Foundation

/// Strategy B's journal (PLAN.md §4.3; docs/plans/M3c.md, D-b): before a save writes
/// ranges of a file in place, the old bytes of those ranges and the file's identity go to
/// this journal, flushed; after the writes are flushed, a commit mark is appended and the
/// journal deleted. A journal found without its mark means a save stopped half way, and
/// the file is rolled back from it.
///
/// Layout: `"TPSJ" · path · device · inode · count · (offset, length, old bytes)…` and a
/// CRC32C of all that, then `"DONE"` once committed.
public enum SaveJournal {
    /// Its name in a session folder.
    public static let fileName = "save-journal.bin"
    static let magic = Array("TPSJ".utf8)
    static let commitMark = Data("DONE".utf8)

    /// Writes the journal for writing `ranges` of `url` (as `identity`) in place.
    static func begin(
        _ journal: URL, file url: URL, identity: FileIdentity, ranges: [Range<UInt64>],
        fileSystem: any FileSystem
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var body = magic
        let path = Array(url.path.utf8)
        JournalFormat.append(UInt32(path.count), to: &body)
        body += path
        JournalFormat.append(identity.key.device, to: &body)
        JournalFormat.append(identity.key.inode, to: &body)
        JournalFormat.append(UInt32(ranges.count), to: &body)
        for range in ranges {
            let count = range.upperBound - range.lowerBound
            JournalFormat.append(range.lowerBound, to: &body)
            JournalFormat.append(count, to: &body)
            try handle.seek(toOffset: range.lowerBound)
            let old = try handle.read(upToCount: Int(count)) ?? Data()
            guard UInt64(old.count) == count else {
                throw ByteSourceError.truncated(
                    expected: range.upperBound, available: range.lowerBound + UInt64(old.count))
            }
            body += old
        }
        JournalFormat.append(JournalFormat.crc32c(body), to: &body)
        fileSystem.removeItem(at: journal)
        let descriptor = try fileSystem.create(journal)
        defer { fileSystem.close(descriptor) }
        try fileSystem.write(Data(body), to: descriptor, at: 0, path: journal.path)
        try fileSystem.fullSync(descriptor, path: journal.path)
    }

    /// The writes are flushed: marks the journal committed, then deletes it.
    static func commit(_ journal: URL, fileSystem: any FileSystem) throws {
        let end = try FileIdentity(url: journal).size
        let descriptor = try fileSystem.openForWriting(journal)
        defer { fileSystem.close(descriptor) }
        try fileSystem.write(commitMark, to: descriptor, at: end, path: journal.path)
        try fileSystem.fullSync(descriptor, path: journal.path)
        fileSystem.removeItem(at: journal)
    }

    /// If `journal` holds a save that didn't commit, writes the old bytes back into its
    /// file (when it's still the same file) and returns true. Deletes the journal either
    /// way; a journal that never finished being written means the file wasn't touched.
    @discardableResult
    public static func rollBackIfNeeded(
        _ journal: URL, fileSystem: any FileSystem
    ) throws
        -> Bool
    {
        guard let data = try? Data(contentsOf: journal) else { return false }
        defer { fileSystem.removeItem(at: journal) }
        guard let (path, key, ranges, end) = parse([UInt8](data)),
            data.count == end,  // a committed journal carries the mark after the checksum
            (try? FileIdentity(url: URL(fileURLWithPath: path)).key) == key
        else { return false }
        let url = URL(fileURLWithPath: path)
        let descriptor = try fileSystem.openForWriting(url)
        defer { fileSystem.close(descriptor) }
        for (offset, old) in ranges {
            try fileSystem.write(old, to: descriptor, at: offset, path: path)
        }
        try fileSystem.fullSync(descriptor, path: path)
        return true
    }

    /// The journal's path, file key and ranges with their old bytes, and where its body
    /// and checksum end; nil if it's cut short or damaged.
    private static func parse(
        _ bytes: [UInt8]
    ) -> (
        path: String, key: FileIdentity.Key, ranges: [(UInt64, Data)], end: Int
    )? {
        func need(_ count: Int, _ at: Int) -> Bool { at + count <= bytes.count }
        guard need(8, 0), Array(bytes[0..<4]) == magic else { return nil }
        let pathCount = Int(JournalFormat.read(UInt32.self, bytes, 4))
        var at = 8 + pathCount
        guard need(16, at) else { return nil }
        let path = String(decoding: bytes[8..<at], as: UTF8.self)
        let key = FileIdentity.Key(
            device: JournalFormat.read(Int32.self, bytes, at),
            inode: JournalFormat.read(UInt64.self, bytes, at + 4))
        let count = Int(JournalFormat.read(UInt32.self, bytes, at + 12))
        at += 16
        var ranges: [(UInt64, Data)] = []
        for _ in 0..<count {
            guard need(16, at) else { return nil }
            let offset = JournalFormat.read(UInt64.self, bytes, at)
            let length = Int(min(JournalFormat.read(UInt64.self, bytes, at + 8), 1 << 40))
            at += 16
            guard need(length, at) else { return nil }
            ranges.append((offset, Data(bytes[at..<(at + length)])))
            at += length
        }
        guard need(4, at),
            JournalFormat.crc32c(bytes[0..<at]) == JournalFormat.read(UInt32.self, bytes, at)
        else { return nil }
        return (path, key, ranges, at + 4)
    }
}
