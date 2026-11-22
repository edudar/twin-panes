import Foundation
import Synchronization
import Testing

@testable import TwinPanesCore

/// In-memory bytes that count sequential and cached reads separately.
final class MemoryBytes: ByteReading {
    let data: Data
    let cachedReads = Atomic(0)
    let sequentialReads = Atomic(0)

    init(_ data: Data) { self.data = data }
    init(_ text: String) { self.data = Data(text.utf8) }

    var length: UInt64 { UInt64(data.count) }

    func read(_ range: Range<UInt64>) throws -> Data {
        cachedReads.add(1, ordering: .relaxed)
        return data[Int(range.lowerBound)..<Int(range.upperBound)]
    }

    func readSequential(_ range: Range<UInt64>) throws -> Data {
        sequentialReads.add(1, ordering: .relaxed)
        return data[Int(range.lowerBound)..<Int(range.upperBound)]
    }
}

@Suite struct SearchScanTests {
    /// Random data over a small alphabet, checked against a naive search.
    @Test func matchesANaiveSearch() throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let data = (0..<Int.random(in: 0...60, using: &rng)).map { _ in
                UInt8.random(in: 0...2, using: &rng)
            }
            let needle = (0..<Int.random(in: 1...4, using: &rng)).map { _ in
                UInt8.random(in: 0...2, using: &rng)
            }
            let source = MemoryBytes(Data(data))
            let pattern = try SearchPattern(bytes: needle)
            func scan() -> SearchScan {
                SearchScan(
                    source, chunkSize: UInt64.random(in: 1...9, using: &rng), pattern: pattern)
            }
            let starts = (0..<max(0, data.count - needle.count + 1)).filter {
                Array(data[$0..<$0 + needle.count]) == needle
            }
            let a = Int.random(in: 0...data.count, using: &rng)
            let b = Int.random(in: a...data.count, using: &rng)
            let window = UInt64(a)..<UInt64(b)

            var first = scan()
            #expect(try first.first(window) == starts.first { $0 >= a && $0 < b }.map(UInt64.init))
            var last = scan()
            #expect(try last.last(window) == starts.last { $0 >= a && $0 < b }.map(UInt64.init))

            var expected: [UInt64] = []
            for start in starts where start >= (expected.last.map { Int($0) + needle.count } ?? 0) {
                expected.append(UInt64(start))
            }
            var all = scan()
            var found: [UInt64] = []
            try all.forward(0..<source.length) { start in
                found.append(start)
                return start + UInt64(needle.count)
            }
            #expect(found == expected)
        }
    }

    @Test func readsOnlyThroughTheSequentialPath() throws {
        let source = MemoryBytes("0123456789abcdef")
        var scan = SearchScan(source, chunkSize: 4, pattern: try .text("cd", encoding: .utf8))
        #expect(try scan.first(0..<source.length) == 12)
        #expect(source.cachedReads.load(ordering: .relaxed) == 0)
        #expect(source.sequentialReads.load(ordering: .relaxed) == 4)
    }
}
