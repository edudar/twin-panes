import Darwin
import Foundation

public struct FileSystemError: Error, Equatable, CustomStringConvertible {
    public let operation: String
    public let path: String
    public let errno: Int32

    public init(_ operation: String, _ path: String, errno: Int32) {
        self.operation = operation
        self.path = path
        self.errno = errno
    }

    public var description: String {
        "Can't \(operation) \(path): \(String(cString: strerror(errno)))"
    }
}

/// Every write a save makes goes through this seam (docs/plans/M3b.md, D-d), so M3c's
/// fault injection can fail or "crash" at any step. `RealFileSystem` is the one the app
/// uses.
public protocol FileSystem: Sendable {
    /// A fresh staging folder on `url`'s volume (`itemReplacementDirectory`).
    func replacementDirectory(for url: URL) throws -> URL
    /// `clonefile`: instant on APFS, and keeps the metadata.
    func clone(_ source: URL, to destination: URL) throws
    /// A full copy with metadata, for volumes that can't clone.
    func copy(_ source: URL, to destination: URL) throws
    /// Free bytes on `url`'s volume, if known.
    func availableCapacity(for url: URL) -> UInt64?
    func openForWriting(_ url: URL) throws -> Int32
    func write(_ data: Data, to descriptor: Int32, at offset: UInt64, path: String) throws
    func truncate(_ descriptor: Int32, to length: UInt64, path: String) throws
    /// `F_FULLFSYNC`: on macOS only this flushes the drive's cache.
    func fullSync(_ descriptor: Int32, path: String) throws
    func close(_ descriptor: Int32)
    /// Swaps `staged` in for `url` (coordinated, atomic); `staged` is gone afterwards.
    func replaceItem(at url: URL, with staged: URL) throws
    func removeItem(at url: URL)
}

public struct RealFileSystem: FileSystem {
    public init() {}

    public func replacementDirectory(for url: URL) throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url,
            create: true)
    }

    public func clone(_ source: URL, to destination: URL) throws {
        guard clonefile(source.path, destination.path, 0) == 0 else {
            throw FileSystemError("clone", source.path, errno: errno)
        }
    }

    public func copy(_ source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public func availableCapacity(for url: URL) -> UInt64? {
        let folder = url.deletingLastPathComponent()
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map { UInt64(max(0, $0)) }
    }

    public func openForWriting(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw FileSystemError("open", url.path, errno: errno) }
        return descriptor
    }

    public func write(_ data: Data, to descriptor: Int32, at offset: UInt64, path: String) throws {
        try data.withUnsafeBytes { buffer in
            var done = 0
            while done < buffer.count {
                let n = pwrite(
                    descriptor, buffer.baseAddress! + done, buffer.count - done,
                    off_t(offset) + off_t(done))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else {
                    throw FileSystemError("write", path, errno: n < 0 ? errno : EIO)
                }
                done += n
            }
        }
    }

    public func truncate(_ descriptor: Int32, to length: UInt64, path: String) throws {
        guard ftruncate(descriptor, off_t(length)) == 0 else {
            throw FileSystemError("resize", path, errno: errno)
        }
    }

    public func fullSync(_ descriptor: Int32, path: String) throws {
        guard fcntl(descriptor, F_FULLFSYNC) != -1 else {
            throw FileSystemError("flush", path, errno: errno)
        }
    }

    public func close(_ descriptor: Int32) { _ = Darwin.close(descriptor) }

    public func replaceItem(at url: URL, with staged: URL) throws {
        var coordinationError: NSError?
        var replaceError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { target in
            do {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
            } catch {
                replaceError = error
            }
        }
        if let error = coordinationError ?? replaceError { throw error }
    }

    public func removeItem(at url: URL) { try? FileManager.default.removeItem(at: url) }
}
