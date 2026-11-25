import Darwin
import Foundation

/// What a file operation needs to know about one item, read without following symlinks.
public struct FileItemMetadata: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file, folder, symbolicLink
        /// Sockets, FIFOs and devices: listed, never copied.
        case other
    }

    public let kind: Kind
    /// Bytes for a file; 0 for anything else.
    public let size: UInt64
    /// The volume it lives on (`st_dev`): a move between two of them is a copy.
    public let device: Int32
    /// Its bytes are only in iCloud (`SF_DATALESS`); reading them downloads it first.
    public let isDataless: Bool

    public init(kind: Kind, size: UInt64, device: Int32, isDataless: Bool) {
        self.kind = kind
        self.size = size
        self.device = device
        self.isDataless = isDataless
    }
}

/// Every change a file operation makes to the disk goes through this seam
/// (docs/plans/M6.md, D-c), and so does what it reads to plan, so tests can fail any
/// step on any item (`EXDEV`, `ENOSPC`, `EACCES`, a volume going away). Calls block;
/// operations run them off the main actor. `RealFileOperationSystem` is the app's.
public protocol FileOperationSystem: Sendable {
    /// `url` itself, not what a symlink points to.
    func metadata(of url: URL) throws(FileSystemError) -> FileItemMetadata
    /// The names in `folder`, hidden ones included, in no particular order.
    func contents(of folder: URL) throws(FileSystemError) -> [String]
    /// Whether this process may create items in `folder`.
    func canWrite(into folder: URL) -> Bool
}

public struct RealFileOperationSystem: FileOperationSystem {
    public init() {}

    public func metadata(of url: URL) throws(FileSystemError) -> FileItemMetadata {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw FileSystemError("read", url.path, errno: errno)
        }
        let kind: FileItemMetadata.Kind
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .folder
        case S_IFLNK: kind = .symbolicLink
        default: kind = .other
        }
        return FileItemMetadata(
            kind: kind, size: kind == .file ? UInt64(info.st_size) : 0, device: info.st_dev,
            isDataless: info.st_flags & UInt32(SF_DATALESS) != 0)
    }

    public func contents(of folder: URL) throws(FileSystemError) -> [String] {
        guard let directory = opendir(folder.path) else {
            throw FileSystemError("list", folder.path, errno: errno)
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    public func canWrite(into folder: URL) -> Bool { access(folder.path, W_OK) == 0 }
}
