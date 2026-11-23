import Darwin
import Foundation
import Synchronization

@testable import TwinPanesCore

/// The real file system, made to "crash" at its `crashAt`-th operation (PLAN.md §7, the
/// fault-injection gate; docs/plans/M3c.md, D-g as built). From then on every operation
/// throws, as if the process had been killed. `powerLoss()` then also loses what wasn't
/// flushed: every file written since its last `fullSync` goes back to how it was then.
/// Creating, renaming, replacing and deleting count as durable at once, as APFS journals
/// metadata.
final class CrashingFileSystem: FileSystem {
    struct Crash: Error {}

    let real = RealFileSystem()
    let crashAt: Int?
    private struct State {
        var operations = 0
        var crashed = false
        /// Each written path's contents at its last flush (empty for a new file).
        var flushed: [String: Data] = [:]
    }
    private let state = Mutex(State())

    init(crashAt: Int?) { self.crashAt = crashAt }

    var crashed: Bool { state.withLock { $0.crashed } }
    var operations: Int { state.withLock { $0.operations } }

    /// Puts every file written since its last flush back to its flushed contents.
    func powerLoss() {
        for (path, data) in state.withLock({ $0.flushed }) {
            if FileManager.default.fileExists(atPath: path) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private func step() throws {
        try state.withLock { state in
            if state.crashed { throw Crash() }
            state.operations += 1
            if state.operations == crashAt {
                state.crashed = true
                throw Crash()
            }
        }
    }

    /// Remembers `path`'s contents before its first unflushed change.
    private func willChange(_ path: String, new: Bool = false) {
        state.withLock { state in
            guard state.flushed[path] == nil else { return }
            state.flushed[path] = new ? Data() : (try? Data(contentsOf: URL(fileURLWithPath: path)))
        }
    }

    func replacementDirectory(for url: URL) throws -> URL {
        try step()
        return try real.replacementDirectory(for: url)
    }
    func clone(_ source: URL, to destination: URL) throws {
        try step()
        try real.clone(source, to: destination)
    }
    func copy(_ source: URL, to destination: URL) throws {
        try step()
        try real.copy(source, to: destination)
    }
    func availableCapacity(for url: URL) -> UInt64? { real.availableCapacity(for: url) }
    func openForWriting(_ url: URL) throws -> Int32 {
        try step()
        return try real.openForWriting(url)
    }
    func create(_ url: URL) throws -> Int32 {
        try step()
        willChange(url.path, new: true)
        return try real.create(url)
    }
    func move(_ source: URL, to destination: URL) throws {
        try step()
        try real.move(source, to: destination)
    }
    func write(_ data: Data, to descriptor: Int32, at offset: UInt64, path: String) throws {
        try step()
        willChange(path)
        try real.write(data, to: descriptor, at: offset, path: path)
    }
    func truncate(_ descriptor: Int32, to length: UInt64, path: String) throws {
        try step()
        willChange(path)
        try real.truncate(descriptor, to: length, path: path)
    }
    func fullSync(_ descriptor: Int32, path: String) throws {
        try step()
        try real.fullSync(descriptor, path: path)
        _ = state.withLock { $0.flushed.removeValue(forKey: path) }
    }
    func close(_ descriptor: Int32) { real.close(descriptor) }
    func replaceItem(at url: URL, with staged: URL) throws {
        try step()
        try real.replaceItem(at: url, with: staged)
        // The staged file's flushed bytes are now the file's.
        state.withLock { $0.flushed[url.path] = $0.flushed.removeValue(forKey: staged.path) }
    }
    func removeItem(at url: URL) {
        guard (try? step()) != nil else { return }
        real.removeItem(at: url)
    }
}
