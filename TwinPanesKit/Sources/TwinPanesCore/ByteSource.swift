import Darwin
import Foundation
import Synchronization

/// Something that can hand out bytes by 64-bit offset. `ByteSource` reads a file;
/// later a piece-table snapshot reads the edited content (PLAN.md §4.5).
public protocol ByteReading: Sendable {
    var length: UInt64 { get }
    /// Reads `range`, blocking on I/O if needed. Throws if the file can't deliver it.
    func read(_ range: Range<UInt64>) throws -> Data
    /// Reads `range` for a one-pass scan (search, save) without filling any cache the
    /// view relies on. May return fewer bytes if the file got shorter.
    func readSequential(_ range: Range<UInt64>) throws -> Data
}

extension ByteReading {
    public func readSequential(_ range: Range<UInt64>) throws -> Data { try read(range) }
}

public enum ByteSourceError: Error, Equatable, CustomStringConvertible {
    case openFailed(path: String, errno: Int32)
    /// Only regular files are opened (D14); `kind` names what it is instead.
    case notRegularFile(path: String, kind: String)
    case readFailed(offset: UInt64, errno: Int32)
    /// The file got shorter while we were reading it.
    case truncated(expected: UInt64, available: UInt64)

    public var description: String {
        switch self {
        case .openFailed(let path, let code):
            return "Can't open \(path): \(String(cString: strerror(code)))"
        case .notRegularFile(let path, let kind):
            return "\(path) is a \(kind), not a regular file"
        case .readFailed(let offset, let code):
            return "Read failed at offset \(offset): \(String(cString: strerror(code)))"
        case .truncated(let expected, let available):
            return "The file is shorter than expected (\(available) of \(expected) bytes)"
        }
    }
}

/// Read-only access to one regular file (PLAN.md §4.1).
///
/// - Random access goes through an LRU page cache (64 KB pages, 256 of them = 16 MB),
///   guarded by a `Mutex` so drawing on the main thread and readers on background
///   threads can share it. The API is synchronous; nothing here is an actor.
/// - `cachedBytes(_:)` never touches the disk, so a view can draw from it without
///   blocking; `prefetch(_:completion:)` loads missing pages on a background queue.
/// - `readSequential(_:)` bypasses the cache (`F_NOCACHE`, no LRU) so a full-file scan
///   doesn't evict the pages the view needs.
public final class ByteSource: ByteReading {
    public static let pageSize: UInt64 = 64 * 1024
    public static let defaultPageCapacity = 256

    public let url: URL
    public let length: UInt64
    /// Device and inode at open time, for identity checks (§4.9).
    public let fileID: (device: Int32, inode: UInt64)

    private let fd: Int32
    private let sequentialFD: Int32
    private let cache: Mutex<PageCache>
    private let ioQueue = DispatchQueue(label: "ByteSource.io", qos: .userInitiated)
    /// Counts prefetch requests; only the newest one keeps loading pages.
    private let latestPrefetch = Mutex<UInt64>(0)

    public init(url: URL, pageCapacity: Int = ByteSource.defaultPageCapacity) throws {
        let path = url.path
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ByteSourceError.openFailed(path: path, errno: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            throw ByteSourceError.openFailed(path: path, errno: code)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw ByteSourceError.notRegularFile(path: path, kind: Self.kind(of: info.st_mode))
        }
        let sequentialFD = open(path, O_RDONLY | O_CLOEXEC)
        if sequentialFD >= 0 { _ = fcntl(sequentialFD, F_NOCACHE, 1) }

        self.url = url
        self.fd = fd
        self.sequentialFD = sequentialFD >= 0 ? sequentialFD : fd
        self.length = UInt64(info.st_size)
        self.fileID = (info.st_dev, info.st_ino)
        self.cache = Mutex(PageCache(capacity: max(1, pageCapacity)))
    }

    deinit {
        if sequentialFD != fd { close(sequentialFD) }
        close(fd)
    }

    // MARK: Cached access

    /// The bytes in `range` if every page they touch is already cached; never blocks
    /// on I/O. Safe to call from `draw(_:)`.
    public func cachedBytes(_ range: Range<UInt64>) -> Data? {
        let range = clamp(range)
        if range.isEmpty { return Data() }
        return cache.withLock { cache -> Data? in
            var out = Data(capacity: Int(range.count))
            for page in Self.pages(covering: range) {
                guard let data = cache.lookup(page) else { return nil }
                Self.append(data, page: page, clippedTo: range, to: &out)
            }
            // A page cached after the file got shorter holds less than asked for; callers
            // rely on getting all of `range` or nothing.
            return out.count == range.count ? out : nil
        }
    }

    /// Reads `range`, loading missing pages from disk. Blocks; don't call from drawing.
    public func read(_ range: Range<UInt64>) throws -> Data {
        let range = clamp(range)
        if range.isEmpty { return Data() }
        var out = Data(capacity: Int(range.count))
        for page in Self.pages(covering: range) {
            let data = try loadPage(page)
            Self.append(data, page: page, clippedTo: range, to: &out)
        }
        guard UInt64(out.count) == range.count else {
            throw ByteSourceError.truncated(
                expected: range.upperBound, available: range.lowerBound + UInt64(out.count))
        }
        return out
    }

    /// Loads the pages covering `range` on a background queue, then calls `completion`
    /// on the main queue with any error: `.truncated` if the file is now shorter than
    /// `range`. When `supersede` is true (the default, used for viewport scrolling), a
    /// newer superseding prefetch makes queued older ones stop early and complete with nil;
    /// pass `false` for independent point reads such as the data inspector.
    public func prefetch(
        _ range: Range<UInt64>,
        supersede: Bool = true,
        completion: @escaping @MainActor @Sendable (ByteSourceError?) -> Void
    ) {
        let range = clamp(range)
        if range.isEmpty {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let request: UInt64? =
            supersede
            ? latestPrefetch.withLock { latest -> UInt64 in
                latest += 1
                return latest
            }
            : nil
        ioQueue.async { [self] in
            var failure: ByteSourceError?
            for page in Self.pages(covering: range) {
                // A newer superseding request (the view scrolled on) makes this one moot.
                if let request, latestPrefetch.withLock({ $0 }) != request { break }
                do {
                    let data = try loadPage(page)
                    // The page came back shorter than the part of `range` it should hold.
                    let available = page * Self.pageSize + UInt64(data.count)
                    if available < min(range.upperBound, (page + 1) * Self.pageSize) {
                        failure = .truncated(expected: range.upperBound, available: available)
                        break
                    }
                } catch {
                    failure = error as? ByteSourceError
                    break
                }
            }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    // MARK: Sequential, uncached access

    /// Reads `range` straight from disk without touching the page cache.
    public func readSequential(_ range: Range<UInt64>) throws -> Data {
        let range = clamp(range)
        var data = Data(count: Int(range.count))
        let got = try data.withUnsafeMutableBytes { buffer -> Int in
            try Self.preadFully(sequentialFD, buffer, offset: range.lowerBound)
        }
        data.count = got
        return data
    }

    // MARK: Test hooks

    /// Pages currently in the cache.
    var cachedPageCount: Int { cache.withLock { $0.count } }

    /// Stops the prefetch queue so tests can queue several requests before any runs.
    func holdIOForTesting() { ioQueue.suspend() }
    func releaseIOForTesting() { ioQueue.resume() }

    // MARK: Internals

    private func clamp(_ range: Range<UInt64>) -> Range<UInt64> {
        min(range.lowerBound, length)..<min(range.upperBound, length)
    }

    private func loadPage(_ page: UInt64) throws -> Data {
        if let hit = cache.withLock({ $0.lookup(page) }) { return hit }
        let start = page * Self.pageSize
        let count = Int(min(Self.pageSize, length - start))
        var data = Data(count: count)
        let got = try data.withUnsafeMutableBytes { buffer in
            try Self.preadFully(fd, buffer, offset: start)
        }
        data.count = got
        cache.withLock { $0.insert(page, data) }
        return data
    }

    private static func preadFully(
        _ fd: Int32, _ buffer: UnsafeMutableRawBufferPointer, offset: UInt64
    ) throws -> Int {
        var done = 0
        while done < buffer.count {
            let n = pread(
                fd, buffer.baseAddress! + done, buffer.count - done, off_t(offset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw ByteSourceError.readFailed(offset: offset + UInt64(done), errno: errno)
            }
            if n == 0 { break }  // end of file: the file got shorter
            done += n
        }
        return done
    }

    static func pages(covering range: Range<UInt64>) -> ClosedRange<UInt64> {
        (range.lowerBound / pageSize)...((range.upperBound - 1) / pageSize)
    }

    private static func append(
        _ data: Data, page: UInt64, clippedTo range: Range<UInt64>, to out: inout Data
    ) {
        let pageStart = page * pageSize
        let from = Int(max(range.lowerBound, pageStart) - pageStart)
        let to = Int(min(range.upperBound, pageStart + UInt64(data.count)) - pageStart)
        if from < to { out.append(data[data.startIndex + from..<data.startIndex + to]) }
    }

    private static func kind(of mode: mode_t) -> String {
        switch mode & S_IFMT {
        case S_IFDIR: return "folder"
        case S_IFCHR: return "character device"
        case S_IFBLK: return "block device"
        case S_IFIFO: return "pipe"
        case S_IFSOCK: return "socket"
        case S_IFLNK: return "symbolic link"
        default: return "special file"
        }
    }
}

/// Least-recently-used page store. Capacity is small (hundreds), so eviction scans.
struct PageCache {
    let capacity: Int
    private var pages: [UInt64: (data: Data, tick: UInt64)] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int) { self.capacity = capacity }

    var count: Int { pages.count }

    mutating func lookup(_ page: UInt64) -> Data? {
        guard let entry = pages[page] else { return nil }
        clock += 1
        pages[page] = (entry.data, clock)
        return entry.data
    }

    mutating func insert(_ page: UInt64, _ data: Data) {
        clock += 1
        pages[page] = (data, clock)
        if pages.count > capacity, let oldest = pages.min(by: { $0.value.tick < $1.value.tick }) {
            pages[oldest.key] = nil
        }
    }
}
