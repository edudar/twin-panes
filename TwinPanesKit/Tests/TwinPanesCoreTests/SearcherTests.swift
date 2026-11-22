import Foundation
import Synchronization
import Testing

@testable import TwinPanesCore

/// A flag tasks share. A class, so closures capture a Sendable reference: Xcode 16 and
/// 26 reject closures that capture an `Atomic` local directly.
final class Flag: Sendable {
    private let value = Atomic(false)
    func set() { value.store(true, ordering: .relaxed) }
    var isSet: Bool { value.load(ordering: .relaxed) }
}

@Suite struct SearcherTests {
    func text(_ s: String) throws -> SearchPattern { try .text(s, encoding: .utf8) }

    @Test func findsAcrossChunkBoundaries() throws {
        let source = MemoryBytes("0123456789abcdef")
        let searcher = Searcher(source: source, chunkSize: 4)
        for start in 0..<14 {
            let needle = try SearchPattern(bytes: Array(source.data[start..<start + 3]))
            let match = try searcher.next(needle, from: 0, direction: .forward)
            #expect(match == .init(range: UInt64(start)..<UInt64(start + 3), wrapped: false))
        }
        #expect(source.cachedReads.load(ordering: .relaxed) == 0)
    }

    @Test func nextWrapsInBothDirections() throws {
        let searcher = Searcher(source: MemoryBytes("ab..ab..ab"), chunkSize: 3)
        let ab = try text("ab")
        #expect(try searcher.next(ab, from: 1, direction: .forward)?.range == 4..<6)
        #expect(
            try searcher.next(ab, from: 9, direction: .forward)
                == .init(range: 0..<2, wrapped: true))
        #expect(try searcher.next(ab, from: 9, direction: .forward, wraps: false) == nil)
        #expect(try searcher.next(ab, from: 8, direction: .backward)?.range == 4..<6)
        #expect(try searcher.next(ab, from: 4, direction: .backward)?.range == 0..<2)
        #expect(
            try searcher.next(ab, from: 0, direction: .backward)
                == .init(range: 8..<10, wrapped: true))
        #expect(try searcher.next(try text("zz"), from: 3, direction: .forward) == nil)
    }

    @Test func findAllIsNonOverlappingAndCapped() throws {
        let searcher = Searcher(source: MemoryBytes("aaaaaaa"), chunkSize: 2)
        let aa = try text("aa")
        #expect(try searcher.all(aa).ranges == [0..<2, 2..<4, 4..<6])
        let capped = try searcher.all(aa, limit: 2)
        #expect(capped == .init(ranges: [0..<2, 2..<4], isTruncated: true))
        #expect(try searcher.all(aa, limit: 3).isTruncated == false)
        #expect(try searcher.all(aa, limit: 0) == .init(ranges: [], isTruncated: true))
    }

    @Test func edgeCasesAndReadErrors() throws {
        let empty = Searcher(source: MemoryBytes(Data()), chunkSize: 4)
        #expect(try empty.next(try text("a"), from: 0, direction: .forward) == nil)
        #expect(try empty.all(try text("a")).ranges.isEmpty)

        let short = Searcher(source: MemoryBytes("ab"), chunkSize: 4)
        #expect(try short.next(try text("abcd"), from: 0, direction: .forward) == nil)
        #expect(
            try short.next(try text("a"), from: 99, direction: .forward)
                == .init(range: 0..<1, wrapped: true))

        // Progress across a wrapped two-pass search reaches the full file length.
        let lastProgress = Mutex<UInt64>(0)
        _ = try Searcher(source: MemoryBytes(Data(count: 20)), chunkSize: 4).next(
            try text("z"), from: 8, direction: .forward
        ) { scanned, _ in lastProgress.withLock { $0 = scanned } }
        #expect(lastProgress.withLock { $0 } == 20)

        struct FailingBytes: ByteReading {
            var length: UInt64 { 32 }
            func read(_ range: Range<UInt64>) throws -> Data {
                throw ByteSourceError.readFailed(offset: range.lowerBound, errno: EIO)
            }
        }
        #expect(throws: ByteSourceError.readFailed(offset: 0, errno: EIO)) {
            _ = try Searcher(source: FailingBytes(), chunkSize: 8).all(try text("a"))
        }
    }

    @Test func reportsProgressAndStopsWhenCancelled() throws {
        let searcher = Searcher(source: MemoryBytes(Data(count: 100)), chunkSize: 10)
        let seen = Mutex<[UInt64]>([])
        _ = try searcher.all(try text("z")) { scanned, total in
            #expect(total == 100)
            seen.withLock { $0.append(scanned) }
        }
        #expect(seen.withLock { $0 } == Array(stride(from: 10, through: 100, by: 10)))

        let token = SearchCancellation()
        token.cancel()
        #expect(throws: CancellationError.self) {
            try searcher.next(try text("z"), from: 0, direction: .forward, cancellation: token)
        }
    }

    /// Review bug 3: every search shared one serial queue, so a long search in one tab
    /// held up every other tab's search. Searches now run on a small pool.
    @Test func aLongSearchDoesNotBlockAnother() async throws {
        let started = Flag()
        let release = Flag()
        let long = Task {
            try await Searcher.run { _ in
                started.set()
                while !release.isSet { usleep(1000) }
                return 1
            }
        }
        while !started.isSet { await Task.yield() }
        let short = Task { try await Searcher.run { _ in 2 } }
        let shortFinishedFirst = await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await short.value) == 2 }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                release.set()
                return false
            }
            let first = await group.next() ?? false
            release.set()
            group.cancelAll()
            return first
        }
        #expect(try await long.value == 1)
        #expect(shortFinishedFirst)
    }

    @Test func runCancelsWithItsTask() async throws {
        let started = Flag()
        let task = Task {
            try await Searcher.run { token in
                started.set()
                while !token.isCancelled { usleep(1000) }
                throw CancellationError()
            }
        }
        while !started.isSet { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
