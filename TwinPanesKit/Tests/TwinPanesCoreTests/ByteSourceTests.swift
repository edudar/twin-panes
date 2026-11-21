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

    /// A sparse 4 GiB file opens and reads its last page quickly (M1 target: < 100 ms).
    @Test func opensFourGiBQuickly() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sparse.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try FileHandle(forWritingTo: url).truncate(atOffset: TwinPanesCore.testedFileSizeLimit)
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            let source = try ByteSource(url: url)
            let tail = try source.read((source.length - 16)..<source.length)
            #expect(tail == Data(count: 16))
        }
        #expect(elapsed < .milliseconds(100), "took \(elapsed)")
    }
}
