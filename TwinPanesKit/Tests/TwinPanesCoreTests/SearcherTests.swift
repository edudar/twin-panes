import Foundation
import Synchronization
import Testing

@testable import TwinPanesCore

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
    }

    @Test func ignoresCaseWithoutAnAnchor() throws {
        let searcher = Searcher(source: MemoryBytes("xxHeLLo hello"), chunkSize: 5)
        let hello = try SearchPattern.text("hello", encoding: .utf8, ignoringCase: true)
        #expect(try searcher.all(hello).ranges == [2..<7, 8..<13])
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
        let started = Atomic(false)
        let release = Atomic(false)
        let long = Task {
            try await Searcher.run { _ in
                started.store(true, ordering: .relaxed)
                while !release.load(ordering: .relaxed) { usleep(1000) }
                return 1
            }
        }
        while !started.load(ordering: .relaxed) { await Task.yield() }
        let short = Task { try await Searcher.run { _ in 2 } }
        let shortFinishedFirst = await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await short.value) == 2 }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                release.store(true, ordering: .relaxed)
                return false
            }
            let first = await group.next() ?? false
            release.store(true, ordering: .relaxed)
            group.cancelAll()
            return first
        }
        #expect(try await long.value == 1)
        #expect(shortFinishedFirst)
    }

    @Test func runCancelsWithItsTask() async throws {
        let started = Atomic(false)
        let task = Task {
            try await Searcher.run { token in
                started.store(true, ordering: .relaxed)
                while !token.isCancelled { usleep(1000) }
                throw CancellationError()
            }
        }
        while !started.load(ordering: .relaxed) { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
