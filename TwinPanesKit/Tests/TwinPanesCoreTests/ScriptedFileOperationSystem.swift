import Foundation
import Synchronization

@testable import TwinPanesCore

/// The real seam, with failures and progress steps a test chooses: an errno for the
/// items whose path ends with a given suffix, and a copy's data reported in chunks
/// (clones report none) with a hook the test runs at each one.
final class ScriptedFileOperationSystem: FileOperationSystem {
    private let real = RealFileOperationSystem()
    private struct Script {
        var copyFailures: [String: Int32] = [:]
        var folderFailures: [String: Int32] = [:]
        var chunks = 0
        var onChunk: (@Sendable (_ path: String, _ chunk: Int) -> Void)?
        var copied: [String] = []
        var renameFailures: [String: Int32] = [:]
        var removeFailures: [String: Int32] = [:]
        var truncated: [String] = []
        var dataless: Set<String> = []
        var downloads: [String] = []
        var downloadFailures: [String: Int32] = [:]
        var onDownload: (@Sendable (String) -> Void)?
        var trashFolder: URL?
        var trashFailures: [String: Int32] = [:]
    }
    private let script = Mutex(Script())

    func failCopy(endingWith suffix: String, errno: Int32) {
        script.withLock { $0.copyFailures[suffix] = errno }
    }

    func failMakingFolder(endingWith suffix: String, errno: Int32) {
        script.withLock { $0.folderFailures[suffix] = errno }
    }

    /// Each file copy reports `count` chunks of progress before copying, running
    /// `onChunk` with the source path and the chunk's number at each.
    func reportChunks(_ count: Int, onChunk: @escaping @Sendable (String, Int) -> Void) {
        script.withLock {
            $0.chunks = count
            $0.onChunk = onChunk
        }
    }

    /// Copies of these sources come out one byte short, as a copy cut off unnoticed.
    func truncateCopies(endingWith suffix: String) {
        script.withLock { $0.truncated.append(suffix) }
    }

    func failRemove(endingWith suffix: String, errno: Int32) {
        script.withLock { $0.removeFailures[suffix] = errno }
    }

    /// `EXDEV` here stands for a move to another volume.
    func failRename(endingWith suffix: String, errno: Int32) {
        script.withLock { $0.renameFailures[suffix] = errno }
    }

    /// These items' bytes are only in iCloud until `download` brings them down.
    func markDataless(_ paths: [String]) { script.withLock { $0.dataless.formUnion(paths) } }

    func failDownload(endingWith suffix: String, errno: Int32) {
        script.withLock { $0.downloadFailures[suffix] = errno }
    }

    /// Runs `hook` with the path when a download starts, before it finishes.
    func onDownload(_ hook: @escaping @Sendable (String) -> Void) {
        script.withLock { $0.onDownload = hook }
    }

    /// The paths downloaded, in order.
    var downloads: [String] { script.withLock { $0.downloads } }

    /// Where `trash` moves items, so tests never touch the real Trash.
    func useTrash(_ folder: URL) { script.withLock { $0.trashFolder = folder } }

    func failTrash(endingWith suffix: String, errno: Int32) {
        script.withLock { $0.trashFailures[suffix] = errno }
    }

    /// The source paths `copyFile` was asked to copy, in order.
    var copied: [String] { script.withLock { $0.copied } }

    func metadata(of url: URL) throws(FileSystemError) -> FileItemMetadata {
        let metadata = try real.metadata(of: url)
        guard script.withLock({ $0.dataless.contains(url.path) }) else { return metadata }
        return FileItemMetadata(
            kind: metadata.kind, size: metadata.size, device: metadata.device, isDataless: true)
    }

    func download(_ url: URL, isCancelled: () -> Bool) throws(FileSystemError) {
        let (failure, hook) = script.withLock { script in
            (script.downloadFailures.first { url.path.hasSuffix($0.key) }?.value, script.onDownload)
        }
        hook?(url.path)
        if let failure { throw FileSystemError("download", url.path, errno: failure) }
        if isCancelled() { throw FileSystemError("download", url.path, errno: ECANCELED) }
        script.withLock { script in
            script.downloads.append(url.path)
            script.dataless.remove(url.path)
        }
    }

    func contents(of folder: URL) throws(FileSystemError) -> [String] {
        try real.contents(of: folder)
    }

    func canWrite(into folder: URL) -> Bool { real.canWrite(into: folder) }

    func copyFile(
        _ source: URL, to destination: URL, progress: (UInt64) -> Bool
    ) throws(FileSystemError) {
        let (failure, chunks, onChunk) = script.withLock { script in
            script.copied.append(source.path)
            return (
                script.copyFailures.first { source.path.hasSuffix($0.key) }?.value,
                script.chunks, script.onChunk
            )
        }
        if let failure { throw FileSystemError("copy", source.path, errno: failure) }
        for chunk in 0..<chunks {
            // A partial copy, as copyfile leaves one when stopped.
            FileManager.default.createFile(atPath: destination.path, contents: Data([1]))
            onChunk?(source.path, chunk)
            if !progress(UInt64(chunk + 1)) {
                throw FileSystemError("copy", source.path, errno: ECANCELED)
            }
        }
        if chunks > 0 { try? FileManager.default.removeItem(at: destination) }
        try real.copyFile(source, to: destination, progress: progress)
        let truncates = script.withLock { $0.truncated.contains { source.path.hasSuffix($0) } }
        if truncates, let size = try? real.metadata(of: destination).size, size > 0 {
            truncate(destination.path, off_t(size - 1))
        }
    }

    func makeFolder(at url: URL) throws(FileSystemError) {
        let failure = script.withLock { script in
            script.folderFailures.first { url.path.hasSuffix($0.key) }?.value
        }
        if let failure { throw FileSystemError("make folder", url.path, errno: failure) }
        try real.makeFolder(at: url)
    }

    func copyMetadata(from source: URL, to destination: URL) throws(FileSystemError) {
        try real.copyMetadata(from: source, to: destination)
    }

    func remove(_ url: URL) throws(FileSystemError) {
        let failure = script.withLock { script in
            script.removeFailures.first { url.path.hasSuffix($0.key) }?.value
        }
        if let failure { throw FileSystemError("remove", url.path, errno: failure) }
        try real.remove(url)
    }

    func rename(_ source: URL, to destination: URL) throws(FileSystemError) {
        let failure = script.withLock { script in
            script.renameFailures.first { source.path.hasSuffix($0.key) }?.value
        }
        if let failure { throw FileSystemError("move", source.path, errno: failure) }
        try real.rename(source, to: destination)
    }

    func trash(_ url: URL) throws(FileSystemError) -> URL {
        let (folder, failure) = script.withLock { script in
            (script.trashFolder, script.trashFailures.first { url.path.hasSuffix($0.key) }?.value)
        }
        if let failure { throw FileSystemError("move to the Trash", url.path, errno: failure) }
        guard let folder else { preconditionFailure("call useTrash(_:) before trashing") }
        let trashed = folder.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(
                at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trashed)
        } catch {
            throw FileSystemError("move to the Trash", url.path, errno: EIO)
        }
        return trashed
    }
}
