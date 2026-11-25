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

    /// Copies one file or symlink (not followed) with its metadata, as a clone where the
    /// volume can. Never replaces: `EEXIST` if `destination` is taken. `progress` is
    /// called with the bytes copied so far while data is copied (a clone has none);
    /// returning false stops the copy, which then throws `ECANCELED` and leaves the
    /// partial copy for the caller to remove.
    func copyFile(
        _ source: URL, to destination: URL, progress: (UInt64) -> Bool
    ) throws(FileSystemError)
    /// A new, empty folder; `EEXIST` if the name is taken.
    func makeFolder(at url: URL) throws(FileSystemError)
    /// Gives `destination` the dates, permissions and extended attributes of `source`,
    /// for a folder once its contents are in.
    func copyMetadata(from source: URL, to destination: URL) throws(FileSystemError)
    /// Removes one file, symlink or empty folder.
    func remove(_ url: URL) throws(FileSystemError)
    /// Moves `url` to its volume's Trash and returns where it went.
    func trash(_ url: URL) throws(FileSystemError) -> URL
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

    public func copyFile(
        _ source: URL, to destination: URL, progress: (UInt64) -> Bool
    ) throws(FileSystemError) {
        try copy(source, to: destination, flags: COPYFILE_CLONE, progress: progress)
    }

    /// `copyFile` as it runs across volumes, where there's no clone; for tests.
    func copyFileWithoutCloning(
        _ source: URL, to destination: URL, progress: (UInt64) -> Bool
    ) throws(FileSystemError) {
        try copy(source, to: destination, flags: 0, progress: progress)
    }

    /// `copyfile(3)` with everything (`COPYFILE_ALL`), never following a symlink or
    /// replacing what's there, plus `extraFlags`.
    private func copy(
        _ source: URL, to destination: URL, flags extraFlags: Int32,
        progress: (UInt64) -> Bool
    ) throws(FileSystemError) {
        let failure: Int32? = withoutActuallyEscaping(progress) { progress in
            let box = ProgressBox(report: progress)
            guard let state = copyfile_state_alloc() else { return errno }
            defer { copyfile_state_free(state) }
            let context = Unmanaged.passUnretained(box).toOpaque()
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context)
            let callback: copyfile_callback_t = { what, stage, state, _, _, context in
                guard what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let context
                else { return COPYFILE_CONTINUE }
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
                return box.report(UInt64(max(copied, 0))) ? COPYFILE_CONTINUE : COPYFILE_QUIT
            }
            copyfile_state_set(
                state, UInt32(COPYFILE_STATE_STATUS_CB),
                unsafeBitCast(callback, to: UnsafeRawPointer.self))
            let flags = copyfile_flags_t(
                COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_EXCL | extraFlags)
            return copyfile(source.path, destination.path, state, flags) == 0 ? nil : errno
        }
        if let failure { throw FileSystemError("copy", source.path, errno: failure) }
    }

    public func makeFolder(at url: URL) throws(FileSystemError) {
        guard mkdir(url.path, 0o777) == 0 else {
            throw FileSystemError("make folder", url.path, errno: errno)
        }
    }

    public func copyMetadata(from source: URL, to destination: URL) throws(FileSystemError) {
        guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0
        else { throw FileSystemError("copy metadata to", destination.path, errno: errno) }
    }

    public func trash(_ url: URL) throws(FileSystemError) -> URL {
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        } catch {
            // Foundation wraps the POSIX error when there is one; a volume without a
            // Trash gives a Cocoa error alone.
            var code = ENOTSUP
            if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError,
                underlying.domain == NSPOSIXErrorDomain
            {
                code = Int32(underlying.code)
            }
            throw FileSystemError("move to the Trash", url.path, errno: code)
        }
        guard let trashed = trashed as URL? else {
            throw FileSystemError("move to the Trash", url.path, errno: ENOENT)
        }
        return trashed
    }

    public func remove(_ url: URL) throws(FileSystemError) {
        guard Darwin.remove(url.path) == 0 else {
            throw FileSystemError("remove", url.path, errno: errno)
        }
    }
}

/// Carries a copy's progress closure through `copyfile`'s C callback context.
private final class ProgressBox {
    let report: (UInt64) -> Bool
    init(report: @escaping (UInt64) -> Bool) { self.report = report }
}
