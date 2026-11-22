import Foundation
import Synchronization

public enum AddBufferError: Error, Equatable, CustomStringConvertible {
    case createFailed(path: String, errno: Int32)
    case writeFailed(offset: UInt64, errno: Int32)

    public var description: String {
        switch self {
        case .createFailed(let path, let code):
            return "Can't create \(path): \(String(cString: strerror(code)))"
        case .writeFailed(let offset, let code):
            return "Write failed at offset \(offset): \(String(cString: strerror(code)))"
        }
    }
}

/// The append-only file holding every byte typed or pasted into an edit (decision D-b,
/// docs/plans/M3a.md). Bytes never change once written, so snapshots on any thread can
/// read earlier ranges while new bytes are appended. Recently written pages stay in
/// memory, so drawing what was just typed never blocks. The file and its folder are
/// deleted when the buffer goes away.
public final class AddBuffer: Sendable {
    public static let pageSize: UInt64 = 64 * 1024

    /// The backing file.
    public let url: URL

    private let folder: URL
    private let fd: Int32
    /// Serializes `pwrite` calls without holding `state` across blocking disk I/O.
    private let writeLock = Mutex(())
    private let state: Mutex<State>
    private let ioQueue = DispatchQueue(label: "AddBuffer.io", qos: .userInitiated)
    private let latestPrefetch = Mutex<UInt64>(0)

    private struct State {
        var length: UInt64 = 0
        /// The last, partly filled page; full pages move to `cache`.
        var tail = Data()
        var cache: PageCache
    }

    /// Opens a new, empty buffer in a fresh folder inside `directory` (the temporary
    /// folder by default).
    public init(directory: URL? = nil, pageCapacity: Int = 64) throws {
        let parent = directory ?? FileManager.default.temporaryDirectory
        folder = parent.appendingPathComponent("TwinPanes-edit-\(UUID().uuidString)")
        url = folder.appendingPathComponent("add-buffer")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            let nsError = error as NSError
            let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError) ?? nsError
            let code = underlying.domain == NSPOSIXErrorDomain ? Int32(underlying.code) : EIO
            throw AddBufferError.createFailed(path: folder.path, errno: code)
        }
        fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: folder)
            throw AddBufferError.createFailed(path: url.path, errno: code)
        }
        state = Mutex(State(cache: PageCache(capacity: max(1, pageCapacity))))
    }

    deinit {
        close(fd)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Bytes written so far.
    public var length: UInt64 { state.withLock { $0.length } }

    /// Appends `data` and returns the range it now occupies.
    public func append(_ data: Data) throws -> Range<UInt64> {
        try writeLock.withLock { _ in
            let start = state.withLock { $0.length }
            guard !data.isEmpty else { return start..<start }
            try data.withUnsafeBytes { buffer in
                var done = 0
                while done < buffer.count {
                    let n = pwrite(
                        fd, buffer.baseAddress! + done, buffer.count - done,
                        off_t(start) + off_t(done))
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw AddBufferError.writeFailed(offset: start + UInt64(done), errno: errno)
                    }
                    if n == 0 {
                        throw AddBufferError.writeFailed(offset: start + UInt64(done), errno: EIO)
                    }
                    done += n
                }
            }
            return state.withLock { state in
                var position = start
                var rest = data[...]
                while !rest.isEmpty {
                    let chunk = rest.prefix(Int(Self.pageSize) - state.tail.count)
                    state.tail.append(contentsOf: chunk)
                    rest = rest.dropFirst(chunk.count)
                    position += UInt64(chunk.count)
                    if position % Self.pageSize == 0 {
                        state.cache.insert(position / Self.pageSize - 1, state.tail)
                        state.tail = Data()
                    }
                }
                state.length = position
                return start..<position
            }
        }
    }

    /// The bytes in `range` if they're in memory; never blocks on I/O.
    public func cachedBytes(_ range: Range<UInt64>) -> Data? {
        state.withLock { state -> Data? in
            guard range.upperBound <= state.length else { return nil }
            if range.isEmpty { return Data() }
            var out = Data(capacity: Int(range.count))
            for page in Self.pages(covering: range) {
                guard let data = Self.page(page, in: &state) else { return nil }
                Self.append(data, page: page, clippedTo: range, to: &out)
            }
            return out
        }
    }

    /// Reads `range`, from memory or the file. Throws `.truncated` past the end.
    public func read(_ range: Range<UInt64>) throws -> Data {
        let written = length
        guard range.upperBound <= written else {
            throw ByteSourceError.truncated(expected: range.upperBound, available: written)
        }
        if range.isEmpty { return Data() }
        var out = Data(capacity: Int(range.count))
        for page in Self.pages(covering: range) {
            let data = try state.withLock { Self.page(page, in: &$0) } ?? loadPage(page)
            Self.append(data, page: page, clippedTo: range, to: &out)
        }
        return out
    }

    /// Reads `range` straight from the backing file without touching the page cache.
    public func readSequential(_ range: Range<UInt64>) throws -> Data {
        let written = length
        guard range.upperBound <= written else {
            throw ByteSourceError.truncated(expected: range.upperBound, available: written)
        }
        if range.isEmpty { return Data() }
        var data = Data(count: Int(range.count))
        try data.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < buffer.count {
                let n = pread(
                    fd, buffer.baseAddress! + done, buffer.count - done,
                    off_t(range.lowerBound) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ByteSourceError.readFailed(
                        offset: range.lowerBound + UInt64(done), errno: errno)
                }
                if n == 0 {
                    throw ByteSourceError.truncated(
                        expected: range.upperBound, available: range.lowerBound + UInt64(done))
                }
                done += n
            }
        }
        return data
    }

    /// Claims the next superseding prefetch ticket, or nil for non-superseding reads.
    func nextPrefetchTicket(supersede: Bool) -> UInt64? {
        guard supersede else { return nil }
        return latestPrefetch.withLock { latest -> UInt64 in
            latest += 1
            return latest
        }
    }

    /// Loads evicted pages covering `ranges` on a background serial queue, stopping early
    /// if a newer superseding ticket superseded `ticket`.
    func prefetch(
        _ ranges: [Range<UInt64>],
        ticket: UInt64?,
        completion: @escaping @MainActor @Sendable (ByteSourceError?) -> Void
    ) {
        if let ticket, latestPrefetch.withLock({ $0 }) != ticket {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let missing = ranges.filter { !$0.isEmpty && cachedBytes($0) == nil }
        guard !missing.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        ioQueue.async { [self] in
            var failure: ByteSourceError?
            for range in missing {
                if let ticket, latestPrefetch.withLock({ $0 }) != ticket { break }
                do {
                    _ = try read(range)
                } catch {
                    failure = error as? ByteSourceError ?? .readFailed(offset: 0, errno: EIO)
                    break
                }
            }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    // MARK: Internals

    private static func pages(covering range: Range<UInt64>) -> ClosedRange<UInt64> {
        (range.lowerBound / pageSize)...((range.upperBound - 1) / pageSize)
    }

    private static func page(_ page: UInt64, in state: inout State) -> Data? {
        if page == state.length / pageSize { return state.tail }
        return state.cache.lookup(page)
    }

    /// Reads a full page that is no longer in memory. Full pages never change.
    private func loadPage(_ page: UInt64) throws -> Data {
        var data = Data(count: Int(Self.pageSize))
        let start = page * Self.pageSize
        try data.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < buffer.count {
                let n = pread(
                    fd, buffer.baseAddress! + done, buffer.count - done, off_t(start) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ByteSourceError.readFailed(offset: start + UInt64(done), errno: errno)
                }
                if n == 0 {
                    throw ByteSourceError.truncated(
                        expected: start + Self.pageSize, available: start + UInt64(done))
                }
                done += n
            }
        }
        state.withLock { $0.cache.insert(page, data) }
        return data
    }

    private static func append(
        _ data: Data, page: UInt64, clippedTo range: Range<UInt64>, to out: inout Data
    ) {
        let pageStart = page * pageSize
        let from = Int(max(range.lowerBound, pageStart) - pageStart)
        let to = Int(min(range.upperBound, pageStart + UInt64(data.count)) - pageStart)
        if from < to { out.append(data[data.startIndex + from..<data.startIndex + to]) }
    }
}
