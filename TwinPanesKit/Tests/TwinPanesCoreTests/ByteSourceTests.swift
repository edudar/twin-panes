import Foundation
import Testing

@testable import TwinPanesCore

@Suite struct ByteSourceTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ByteSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func makeFile(_ count: Int, name: String = "data.bin") throws -> (URL, Data) {
        let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return (url, data)
    }

    @Test func readsAcrossPageBoundaries() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = Int(ByteSource.pageSize)
        let (url, data) = try makeFile(page * 3 + 123)
        let source = try ByteSource(url: url, pageCapacity: 2)
        #expect(source.length == UInt64(data.count))
        let range: Range<UInt64> = UInt64(page - 10)..<UInt64(page * 2 + 10)
        #expect(try source.read(range) == data[Int(range.lowerBound)..<Int(range.upperBound)])
        #expect(try source.read(UInt64(page * 3)..<UInt64(page * 4)) == data[(page * 3)...])
        #expect(try source.readSequential(0..<10) == data[0..<10])
        #expect(try source.read(5..<5).isEmpty)
    }

    @Test func cachedBytesNeverReadsDisk() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, data) = try makeFile(1000)
        let source = try ByteSource(url: url)
        #expect(source.cachedBytes(0..<16) == nil)
        _ = try source.read(0..<1)
        #expect(source.cachedBytes(0..<16) == data[0..<16])
        #expect(source.cachedBytes(990..<2000) == data[990...])
    }

    @Test func evictsLeastRecentlyUsedPage() {
        var cache = PageCache(capacity: 2)
        cache.insert(0, Data([0]))
        cache.insert(1, Data([1]))
        _ = cache.lookup(0)
        cache.insert(2, Data([2]))
        #expect(cache.count == 2)
        #expect(cache.lookup(1) == nil)
        #expect(cache.lookup(0) == Data([0]))
    }

    @Test func refusesNonRegularFiles() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ByteSourceError.notRegularFile(path: dir.path, kind: "folder")) {
            _ = try ByteSource(url: dir)
        }
        let missing = dir.appendingPathComponent("missing")
        #expect(throws: ByteSourceError.openFailed(path: missing.path, errno: ENOENT)) {
            _ = try ByteSource(url: missing)
        }
        let fifo = dir.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        // Open O_NONBLOCK to avoid hanging? ByteSource opens without O_NONBLOCK, so
        // keep a writer open on the FIFO while checking ByteSource rejects it.
        let writer = open(fifo.path, O_RDWR | O_CLOEXEC)
        defer { if writer >= 0 { close(writer) } }
        #expect(throws: ByteSourceError.notRegularFile(path: fifo.path, kind: "pipe")) {
            _ = try ByteSource(url: fifo)
        }
        let broken = dir.appendingPathComponent("broken-link")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: missing)
        #expect(throws: ByteSourceError.openFailed(path: broken.path, errno: ENOENT)) {
            _ = try ByteSource(url: broken)
        }
        let (target, data) = try makeFile(16, name: "target.bin")
        let link = dir.appendingPathComponent("file-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try ByteSource(url: link).read(0..<16) == data)

        let secret = dir.appendingPathComponent("unreadable.bin")
        try Data([1, 2, 3]).write(to: secret)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: secret.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: secret.path)
        }
        #expect(throws: ByteSourceError.openFailed(path: secret.path, errno: EACCES)) {
            _ = try ByteSource(url: secret)
        }
    }

    @Test func evictsPagesInByteSourceAndReloads() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = ByteSource.pageSize
        let (url, data) = try makeFile(Int(page) * 3)
        let source = try ByteSource(url: url, pageCapacity: 2)
        _ = try source.read(0..<16)
        _ = try source.read(page..<(page + 16))
        _ = try source.read((page * 2)..<(page * 2 + 16))
        #expect(source.cachedPageCount == 2)
        #expect(source.cachedBytes(0..<16) == nil)
        #expect(try source.read(0..<16) == data[0..<16])
    }

    @Test func multiPageTruncationReportsExactAvailableBytes() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = ByteSource.pageSize
        let (url, _) = try makeFile(Int(page) * 2)
        let source = try ByteSource(url: url)
        let cut = page + 123
        try FileHandle(forWritingTo: url).truncate(atOffset: cut)
        #expect(throws: ByteSourceError.truncated(expected: page * 2, available: cut)) {
            _ = try source.read(0..<(page * 2))
        }
        #expect(
            await prefetch(source, 0..<(page * 2)) == .truncated(expected: page * 2, available: cut)
        )
    }

    @Test func reportsTruncation() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, _) = try makeFile(1000)
        let source = try ByteSource(url: url)
        try FileHandle(forWritingTo: url).truncate(atOffset: 100)
        #expect(throws: ByteSourceError.truncated(expected: 1000, available: 100)) {
            _ = try source.read(0..<1000)
        }
    }

    @Test func prefetchFillsTheCache() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, data) = try makeFile(200_000)
        let source = try ByteSource(url: url)
        let error: ByteSourceError? = await withCheckedContinuation { done in
            source.prefetch(150_000..<150_100) { done.resume(returning: $0) }
        }
        #expect(error == nil)
        #expect(source.cachedBytes(150_000..<150_100) == data[150_000..<150_100])
    }

    @Test func emptyFileAndOutOfBoundsPrefetchDoNotTrap() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let (emptyURL, _) = try makeFile(0, name: "empty.bin")
        let empty = try ByteSource(url: emptyURL)
        #expect(empty.length == 0)
        #expect(try empty.read(0..<0).isEmpty)
        #expect(empty.cachedBytes(0..<0) == Data())
        #expect(try empty.readSequential(0..<0).isEmpty)
        #expect(await prefetch(empty, 0..<0) == nil)
        #expect(await prefetch(empty, 0..<16) == nil)

        let page = ByteSource.pageSize
        let (alignedURL, _) = try makeFile(Int(page), name: "aligned.bin")
        let aligned = try ByteSource(url: alignedURL)
        #expect(await prefetch(aligned, page..<page) == nil)
        #expect(await prefetch(aligned, page..<page + 16) == nil)
    }

    func prefetch(_ source: ByteSource, _ range: Range<UInt64>) async -> ByteSourceError? {
        await withCheckedContinuation { done in
            source.prefetch(range) { done.resume(returning: $0) }
        }
    }

    /// A file that got shorter after opening: the cache never hands out fewer bytes than
    /// asked for (the view would index past the end), and prefetch reports it (review bug 1).
    @Test func cachedBytesAndPrefetchAfterTruncation() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, data) = try makeFile(1000)
        let source = try ByteSource(url: url)
        try FileHandle(forWritingTo: url).truncate(atOffset: 100)
        #expect(await prefetch(source, 0..<1000) == .truncated(expected: 1000, available: 100))
        #expect(source.cachedBytes(0..<1000) == nil)
        #expect(source.cachedBytes(0..<50) == data[0..<50])
        #expect(await prefetch(source, 0..<50) == nil)
    }

    @Test func sequentialReadsSkipTheCache() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, _) = try makeFile(300_000)
        let source = try ByteSource(url: url)
        _ = try source.readSequential(0..<300_000)
        #expect(source.cachedPageCount == 0)
    }

    /// Fast scrolling queues prefetches; only the newest one loads (review bug 5).
    @MainActor @Test func newerPrefetchSupersedesQueuedOnes() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = ByteSource.pageSize
        let (url, _) = try makeFile(Int(page) * 30)
        let source = try ByteSource(url: url)
        let ranges: [Range<UInt64>] = [0..<page * 4, page * 10..<page * 14, page * 20..<page * 24]
        final class Results { var errors: [ByteSourceError?] = [] }
        let results = Results()
        source.holdIOForTesting()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            for range in ranges {
                source.prefetch(range) { error in
                    results.errors.append(error)
                    if results.errors.count == ranges.count { done.resume() }
                }
            }
            source.releaseIOForTesting()
        }
        #expect(results.errors.allSatisfy { $0 == nil })
        #expect(source.cachedBytes(ranges[0]) == nil)
        #expect(source.cachedBytes(ranges[1]) == nil)
        #expect(source.cachedBytes(ranges[2]) != nil)
    }

    @MainActor @Test func nonSupersedingPrefetchCoexistsWithViewportPrefetch() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = ByteSource.pageSize
        let (url, _) = try makeFile(Int(page) * 25)
        let source = try ByteSource(url: url)
        let pointRange: Range<UInt64> = 0..<16
        let viewportRange: Range<UInt64> = (page * 20)..<(page * 22)
        final class Counter { var done = 0 }
        let counter = Counter()
        source.holdIOForTesting()
        await withCheckedContinuation { (finish: CheckedContinuation<Void, Never>) in
            source.prefetch(pointRange, supersede: false) { _ in
                counter.done += 1
                if counter.done == 2 { finish.resume() }
            }
            source.prefetch(viewportRange, supersede: true) { _ in
                counter.done += 1
                if counter.done == 2 { finish.resume() }
            }
            source.releaseIOForTesting()
        }
        #expect(source.cachedBytes(pointRange) != nil)
        #expect(source.cachedBytes(viewportRange) != nil)
    }

    /// PLAN.md §7: several threads read, look up the cache, scan and prefetch at once,
    /// with a cache small enough to keep evicting. Run under
    /// Thread Sanitizer in CI (`swift test --sanitize=thread`).
    @Test func concurrentReadersShareOneCache() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = Int(ByteSource.pageSize)
        let (url, data) = try makeFile(page * 32 + 999)
        let source = try ByteSource(url: url, pageCapacity: 8)
        let length = UInt64(data.count)
        let mismatches = try await withThrowingTaskGroup(of: Int.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    var seed = UInt64(worker) &* 0x9E37_79B9_7F4A_7C15 | 1
                    var wrong = 0
                    for step in 0..<400 {
                        seed ^= seed << 13
                        seed ^= seed >> 7
                        seed ^= seed << 17
                        let start = seed % length
                        let range = start..<min(length, start + 1 + seed % 20_000)
                        let expected = data[Int(range.lowerBound)..<Int(range.upperBound)]
                        if try source.read(range) != expected { wrong += 1 }
                        if let cached = source.cachedBytes(range), cached != expected { wrong += 1 }
                        if step % 50 == 0, try source.readSequential(range) != expected {
                            wrong += 1
                        }
                        if step % 40 == 0 { source.prefetch(range) { _ in } }
                    }
                    return wrong
                }
            }
            return try await group.reduce(0, +)
        }
        #expect(mismatches == 0)
    }
}
