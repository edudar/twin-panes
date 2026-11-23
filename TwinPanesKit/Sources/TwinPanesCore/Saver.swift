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
        /// refuses it). Strategy B, in place, comes in M3c.
        case hardLinked
        /// The volume can't clone and has no room for a full copy.
        case notEnoughSpace(needed: UInt64, available: UInt64)

        public var description: String {
            switch self {
            case .hardLinked:
                return "The file has hard links, so it can’t be saved in place yet; use Save As"
            case .notEnoughSpace(let needed, let available):
                let format = { (bytes: UInt64) in
                    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                }
                return
                    "Not enough space to save: needs \(format(needed)), \(format(available)) free"
            }
        }
    }

    /// Bytes read from the snapshot and written per step.
    public static let chunkSize = 1 << 20

    public let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem = RealFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// Writes `plan`'s ranges of `version` over the file at `url` and returns the file's
    /// new identity (a replace gives it a new inode).
    public func save(
        _ version: some ByteReading, plan: SavePlan, to url: URL
    ) throws
        -> FileIdentity
    {
        let identity = try FileIdentity(url: url)
        guard identity.linkCount <= 1 else { throw SaveError.hardLinked }
        let folder = try fileSystem.replacementDirectory(for: url)
        defer { fileSystem.removeItem(at: folder) }
        let staged = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try fileSystem.clone(url, to: staged)
        } catch {
            let needed = max(identity.size, plan.length)
            if let free = fileSystem.availableCapacity(for: url), free < needed {
                throw SaveError.notEnoughSpace(needed: needed, available: free)
            }
            try fileSystem.copy(url, to: staged)
        }
        let descriptor = try fileSystem.openForWriting(staged)
        do {
            try patch(staged.path, descriptor, from: version, plan: plan)
        } catch {
            fileSystem.close(descriptor)
            throw error
        }
        fileSystem.close(descriptor)
        try fileSystem.replaceItem(at: url, with: staged)
        return try FileIdentity(url: url)
    }

    /// Writes the planned ranges in chunks, sets the length and flushes.
    private func patch(
        _ path: String, _ descriptor: Int32, from version: some ByteReading, plan: SavePlan
    ) throws {
        for range in plan.ranges {
            var at = range.lowerBound
            while at < range.upperBound {
                let end = min(range.upperBound, at + UInt64(Self.chunkSize))
                let data = try version.readSequential(at..<end)
                guard UInt64(data.count) == end - at else {
                    throw ByteSourceError.truncated(
                        expected: end, available: at + UInt64(data.count))
                }
                try fileSystem.write(data, to: descriptor, at: at, path: path)
                at = end
            }
        }
        try fileSystem.truncate(descriptor, to: plan.length, path: path)
        try fileSystem.fullSync(descriptor, path: path)
    }
}
