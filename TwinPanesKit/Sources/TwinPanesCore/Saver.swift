import Foundation

/// Saves a version over its file with strategy A (docs/plans/M3b.md, D-d; PLAN.md §4.3):
/// clone the file into a staging folder on its volume, patch the planned ranges, flush
/// with `F_FULLFSYNC`, then swap it in with a coordinated replace. Until the swap the
/// file is untouched, so a failure at any step leaves the old contents.
///
/// Runs on any thread; it only reads the snapshot it's given.
public struct Saver: Sendable {
    public enum SaveError: Error, Equatable, CustomStringConvertible {
        /// The file has other hard links; a replace would break them (and the sandbox
        /// refuses it), and writing in place (strategy B) needs the session's clone and a
        /// ranged plan.
        case hardLinked
        /// The volume can't clone and has no room for a full copy.
        case notEnoughSpace(needed: UInt64, available: UInt64)

        public var description: String {
            switch self {
            case .hardLinked:
                return "The file has hard links and can’t be saved in place here; use Save As"
            case .notEnoughSpace(let needed, let available):
                let format = { (bytes: UInt64) in
                    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                }
                return
                    "Not enough space to save: needs \(format(needed)), \(format(available)) free"
            }
        }
    }

    /// How much of a save is done, from 0 to 1 (docs/plans/M8.md, D-f). Called on the
    /// saving thread after each chunk, and with 1 once every byte is written.
    public typealias Progress = @Sendable (Double) -> Void

    /// Bytes read from the snapshot and written per step.
    public static let chunkSize = 1 << 20

    public let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem = RealFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// Writes `plan`'s ranges of `version` over the file at `url` and returns the file's
    /// new identity (a replace gives it a new inode). A hard-linked file is written in
    /// place (strategy B) when `inPlaceJournal` says where its save journal goes and the
    /// plan isn't the whole file; otherwise it's refused. In place, `version` must not
    /// read `url` itself (the session reads its clone): a write would change bytes it has
    /// yet to read, which a change of length moves.
    public func save(
        _ version: some ByteReading, plan: SavePlan, to url: URL, inPlaceJournal: URL? = nil,
        progress: Progress? = nil
    ) throws
        -> FileIdentity
    {
        let identity = try FileIdentity(url: url)
        guard identity.linkCount <= 1 else {
            guard let journal = inPlaceJournal, !plan.writesWholeFile else {
                throw SaveError.hardLinked
            }
            return try saveInPlace(
                version, plan: plan, to: url, as: identity,
                journal: journal, progress: progress)
        }
        let folder = try fileSystem.replacementDirectory(for: url)
        defer { fileSystem.removeItem(at: folder) }
        let staged = folder.appendingPathComponent(url.lastPathComponent)
        // Any volume that can't clone gets a copy instead. A clone shares blocks until
        // they're written, so it needs room for the bytes written; a copy needs room for
        // all of the file (docs/plans/M8.md, D-e).
        let cloned = (try? fileSystem.clone(url, to: staged)) != nil
        try requireSpace(cloned ? plan.byteCount : max(identity.size, plan.length), on: url)
        if !cloned { try fileSystem.copy(url, to: staged) }
        let descriptor = try fileSystem.openForWriting(staged)
        do {
            try write(
                plan.ranges, of: version, length: plan.length, to: descriptor, staged.path,
                counting: SaveWork(total: plan.byteCount, report: progress))
        } catch {
            fileSystem.close(descriptor)
            throw error
        }
        fileSystem.close(descriptor)
        try fileSystem.replaceItem(at: url, with: staged)
        return try FileIdentity(url: url)
    }

    /// Strategy B: journal the old bytes, write the ranges into the file itself, commit.
    /// A failure rolls the file back at once; a crash leaves the journal for recovery.
    private func saveInPlace(
        _ version: some ByteReading, plan: SavePlan, to url: URL, as identity: FileIdentity,
        journal: URL, progress: Progress?
    ) throws -> FileIdentity {
        // The journal is in the session folder, beside the clone, so on the file's volume.
        let kept = SaveJournal.keptRanges(
            plan.ranges, oldLength: identity.size, newLength: plan.length)
        let growth = plan.length > identity.size ? plan.length - identity.size : 0
        let keptBytes = kept.reduce(0) { $0 + UInt64($1.count) }
        try requireSpace(keptBytes + growth, on: url)
        let work = SaveWork(total: keptBytes + plan.byteCount, report: progress)
        try SaveJournal.begin(
            journal, file: url, identity: identity, ranges: plan.ranges,
            newLength: plan.length, fileSystem: fileSystem, counting: work)
        var writesFlushed = false
        do {
            let descriptor = try fileSystem.openForWriting(url)
            do {
                try write(
                    plan.ranges, of: version, length: plan.length, to: descriptor, url.path,
                    counting: work)
            } catch {
                fileSystem.close(descriptor)
                throw error
            }
            fileSystem.close(descriptor)
            writesFlushed = true
            try SaveJournal.commit(journal, fileSystem: fileSystem)
        } catch {
            let rolled = try? SaveJournal.rollBackIfNeeded(
                journal, targetURL: url, fileSystem: fileSystem)
            if rolled == false, writesFlushed, let id = try? FileIdentity(url: url),
                id.key == identity.key
            {
                return id
            }
            throw error
        }
        return try FileIdentity(url: url)
    }

    /// Writes all of `version` to `url` (Save As): staged in a new file next to it, then
    /// moved in, or swapped in for a file already there. Returns the file's identity.
    public func write(
        _ version: some ByteReading, to url: URL, progress: Progress? = nil
    ) throws -> FileIdentity {
        let folder = try fileSystem.replacementDirectory(for: url.deletingLastPathComponent())
        defer { fileSystem.removeItem(at: folder) }
        let staged = folder.appendingPathComponent(url.lastPathComponent)
        let descriptor = try fileSystem.create(staged)
        let length = version.length
        do {
            try write(
                length > 0 ? [0..<length] : [], of: version, length: length, to: descriptor,
                staged.path, counting: SaveWork(total: length, report: progress))
        } catch {
            fileSystem.close(descriptor)
            throw error
        }
        fileSystem.close(descriptor)
        if FileManager.default.fileExists(atPath: url.path) {
            try fileSystem.replaceItem(at: url, with: staged)
        } else {
            try fileSystem.move(staged, to: url)
        }
        return try FileIdentity(url: url)
    }

    /// Throws `notEnoughSpace` when `url`'s volume has less than `needed` bytes free (and
    /// says how much it has); a volume that won't say is let through.
    private func requireSpace(_ needed: UInt64, on url: URL) throws {
        if let free = fileSystem.availableCapacity(for: url), free < needed {
            throw SaveError.notEnoughSpace(needed: needed, available: free)
        }
    }

    /// Writes `ranges` of `version` in chunks, sets the length and flushes, counting each
    /// chunk in `work`.
    private func write(
        _ ranges: [Range<UInt64>], of version: some ByteReading, length: UInt64,
        to descriptor: Int32, _ path: String, counting work: SaveWork
    ) throws {
        for range in ranges {
            var at = range.lowerBound
            while at < range.upperBound {
                let end = min(range.upperBound, at + UInt64(Self.chunkSize))
                let data = try version.readSequential(at..<end)
                guard UInt64(data.count) == end - at else {
                    throw ByteSourceError.truncated(
                        expected: end, available: at + UInt64(data.count))
                }
                try fileSystem.write(data, to: descriptor, at: at, path: path)
                work.didWrite(end - at)
                at = end
            }
        }
        try fileSystem.truncate(descriptor, to: length, path: path)
        work.finish()
        try fileSystem.fullSync(descriptor, path: path)
    }
}

/// The bytes a save has written out of all it will, reported as `Saver.Progress`. Lives
/// on the saving thread for one save.
final class SaveWork {
    private let total: UInt64
    private let report: Saver.Progress?
    private var done: UInt64 = 0
    private var reportedAll = false

    init(total: UInt64, report: Saver.Progress?) {
        (self.total, self.report) = (total, report)
    }

    func didWrite(_ count: UInt64) {
        done += count
        reportedAll = done >= total
        report?(total > 0 ? Double(min(done, total)) / Double(total) : 1)
    }

    /// Reports 1 if the writes haven't already, as when there was nothing to write.
    func finish() {
        guard !reportedAll else { return }
        reportedAll = true
        report?(1)
    }
}
