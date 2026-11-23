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
        fileSystem.removeItem(at: journal)
        let descriptor = try fileSystem.create(journal)
        var done = false
        defer { fileSystem.close(descriptor); if !done { fileSystem.removeItem(at: journal) } }
        var offset: UInt64 = 0, crc = JournalFormat.crc32c(body, finish: false)
        func emit(_ part: Data, hash: Bool = true) throws {
            if hash { crc = JournalFormat.crc32c(part, seed: crc, finish: false) }
            try fileSystem.write(part, to: descriptor, at: offset, path: journal.path)
            offset += UInt64(part.count)
        }
        try emit(Data(body), hash: false)
        for range in ranges {
            let count = range.upperBound - range.lowerBound
            var entry: [UInt8] = []; JournalFormat.append(range.lowerBound, to: &entry)
            JournalFormat.append(count, to: &entry); try emit(Data(entry))
            try streamChunks(from: handle, start: range.lowerBound, length: count) { c, _ in
                try emit(c)
            }
        }
        var sum = JournalFormat.crc32c([], seed: crc).littleEndian
        try emit(Data(bytes: &sum, count: 4), hash: false)
        try fileSystem.fullSync(descriptor, path: journal.path); done = true
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
    /// file (`targetURL` or stored path, when still the same file) and returns true.
    @discardableResult
    public static func rollBackIfNeeded(
        _ journal: URL, targetURL: URL? = nil, fileSystem: any FileSystem
    ) throws -> Bool {
        func drop() -> Bool { fileSystem.removeItem(at: journal); return false }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: journal)
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            return false
        }
        defer { try? handle.close() }
        let total = try handle.seekToEnd(); try handle.seek(toOffset: 0)
        var at: UInt64 = 0, crc: UInt32 = 0xFFFF_FFFF
        func next(_ n: Int, hash: Bool = true) throws -> Data? {
            guard UInt64(n) <= total - at, let c = try handle.read(upToCount: n), c.count == n
            else { return nil }
            if hash { crc = JournalFormat.crc32c(c, seed: crc, finish: false) }
            at += UInt64(n); return c
        }
        guard let head = try next(8), Array(head[0..<4]) == magic else { return drop() }
        let pathLen = Int(JournalFormat.read(UInt32.self, head, 4))
        guard pathLen <= 1 << 20, let meta = try next(pathLen + 16) else { return drop() }
        let key = FileIdentity.Key(
            device: JournalFormat.read(Int32.self, meta, pathLen),
            inode: JournalFormat.read(UInt64.self, meta, pathLen + 4))
        let count = UInt64(JournalFormat.read(UInt32.self, meta, pathLen + 12))
        guard count <= (total - at) / 16 else { return drop() }
        var ranges: [(UInt64, UInt64, UInt64)] = []
        for _ in 0..<count {
            guard let entry = try next(16) else { return drop() }
            var rem = JournalFormat.read(UInt64.self, entry, 8)
            guard rem <= total - at else { return drop() }
            ranges.append((JournalFormat.read(UInt64.self, entry, 0), rem, at))
            while rem > 0 {
                let want = Int(min(rem, UInt64(Saver.chunkSize)))
                guard try next(want) != nil else { return drop() }
                rem -= UInt64(want)
            }
        }
        guard let sum = try next(4, hash: false), total == at,
            JournalFormat.crc32c([], seed: crc) == JournalFormat.read(UInt32.self, sum, 0)
        else { return drop() }
        let url =
            targetURL ?? URL(fileURLWithPath: String(decoding: meta[0..<pathLen], as: UTF8.self))
        guard try FileIdentity(url: url).key == key else { return drop() }
        let descriptor = try fileSystem.openForWriting(url)
        defer { fileSystem.close(descriptor) }
        for (offset, length, dataAt) in ranges {
            try streamChunks(from: handle, start: dataAt, length: length) { chunk, done in
                try fileSystem.write(chunk, to: descriptor, at: offset + done, path: url.path)
            }
        }
        try fileSystem.fullSync(descriptor, path: url.path)
        fileSystem.removeItem(at: journal); return true
    }

    private static func streamChunks(
        from h: FileHandle, start: UInt64, length: UInt64, consume: (Data, UInt64) throws -> Void
    ) throws {
        var done: UInt64 = 0; try h.seek(toOffset: start)
        while done < length {
            let want = Int(min(length - done, UInt64(Saver.chunkSize)))
            let chunk = try h.read(upToCount: want) ?? Data()
            guard chunk.count == want else {
                throw ByteSourceError.truncated(
                    expected: start + length, available: start + done + UInt64(chunk.count))
            }
            try consume(chunk, done); done += UInt64(want)
        }
    }
}
