import Darwin
import Foundation

/// Which file a session edits and what it looked like when last seen (docs/plans/M3b.md,
/// D-a): the registry keys sessions by `fileKey`, and a save checks `isUnchanged(from:)`
/// before patching only the changed ranges (D-c).
public struct FileIdentity: Equatable, Hashable, Sendable {
    /// The volume and inode: the same file, whatever its contents. A strategy-A save
    /// replaces the file, so the key changes.
    public struct Key: Hashable, Sendable {
        public let device: Int32
        public let inode: UInt64
    }

    public let key: Key
    public let size: UInt64
    /// Last modification, to the nanosecond.
    public let modified: timespec
    /// Hard links to the inode; a file with more than one can't be replaced (strategy A).
    public let linkCount: UInt16

    public init(_ info: stat) {
        key = Key(device: info.st_dev, inode: info.st_ino)
        size = UInt64(max(0, info.st_size))
        modified = info.st_mtimespec
        linkCount = info.st_nlink
    }

    /// The identity of the open file `descriptor`.
    public init(descriptor: Int32, path: String) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw ByteSourceError.openFailed(path: path, errno: errno)
        }
        self.init(info)
    }

    /// The identity of the file at `url`, following symbolic links.
    public init(url: URL) throws {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw ByteSourceError.openFailed(path: url.path, errno: errno)
        }
        self.init(info)
    }

    /// Same file, same size, same modification time: nothing wrote to it since `other`
    /// was taken (as far as the file system can tell).
    public func isUnchanged(from other: FileIdentity) -> Bool {
        key == other.key && size == other.size && modified.tv_sec == other.modified.tv_sec
            && modified.tv_nsec == other.modified.tv_nsec
    }

    public static func == (a: FileIdentity, b: FileIdentity) -> Bool {
        a.key == b.key && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec
            && a.modified.tv_nsec == b.modified.tv_nsec && a.linkCount == b.linkCount
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(size)
        hasher.combine(modified.tv_sec)
        hasher.combine(modified.tv_nsec)
    }
}

/// Whether a session may write its file (docs/plans/M3b.md, D-b).
public enum AccessMode: Equatable, Sendable {
    case writable
    case readOnly(ReadOnlyReason)

    public enum ReadOnlyReason: Equatable, Sendable, CustomStringConvertible {
        /// The volume is mounted read-only.
        case readOnlyVolume
        /// The file is locked (`uchg` or `schg`).
        case locked
        /// We have no write permission (mode bits, ownership, or the sandbox grant).
        case noWritePermission

        public var description: String {
            switch self {
            case .readOnlyVolume: return "the volume is read-only"
            case .locked: return "the file is locked"
            case .noWritePermission: return "you don’t have permission to change it"
            }
        }
    }

    public var isWritable: Bool { self == .writable }

    /// The mode for the file at `url`, checked in the order a user can fix it least:
    /// the volume, then the lock, then permission.
    public static func of(_ url: URL) -> AccessMode {
        var volume = statfs()
        let volumeReadOnly =
            statfs(url.path, &volume) == 0 && (volume.f_flags & UInt32(MNT_RDONLY)) != 0
        var info = stat()
        let flags = stat(url.path, &info) == 0 ? info.st_flags : 0
        return classify(
            volumeReadOnly: volumeReadOnly, fileFlags: flags,
            canWrite: access(url.path, W_OK) == 0)
    }

    /// The decision itself, from what the file system reported.
    static func classify(volumeReadOnly: Bool, fileFlags: UInt32, canWrite: Bool) -> AccessMode {
        if volumeReadOnly { return .readOnly(.readOnlyVolume) }
        if fileFlags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 { return .readOnly(.locked) }
        return canWrite ? .writable : .readOnly(.noWritePermission)
    }
}
