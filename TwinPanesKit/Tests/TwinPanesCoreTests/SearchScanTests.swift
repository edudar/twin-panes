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
    /// Random data over a small alphabet, checked against a naive search, with exact,
    /// case-folded and UTF-16 patterns. The seed is in every failure message.
    @Test func matchesANaiveSearch() throws {
        let seed = UInt64.random(in: .min ... .max)
        var rng = SplitMix64(seed: seed)
        for _ in 0..<600 {
            let alphabet: [UInt8]
            let pattern: SearchPattern
            if Bool.random(using: &rng) {
                alphabet = [0x00, 0x01, 0x02]
                pattern = try SearchPattern(
                    bytes: (0..<Int.random(in: 1...4, using: &rng)).map { _ in
                        alphabet.randomElement(using: &rng)!
                    })
            } else {
                alphabet = [0x00, 0x31, 0x41, 0x42, 0x61, 0x62]
                let text = String(
                    (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                        "aAbB1".randomElement(using: &rng)!
                    })
                pattern = try .text(
                    text, encoding: SearchPattern.TextEncoding.allCases.randomElement(using: &rng)!,
                    ignoringCase: Bool.random(using: &rng))
            }
            let data = (0..<Int.random(in: 0...60, using: &rng)).map { _ in
                alphabet.randomElement(using: &rng)!
            }
            let m = pattern.count
            let source = MemoryBytes(Data(data))
            func scan() -> SearchScan {
                SearchScan(
                    source, chunkSize: UInt64.random(in: 1...9, using: &rng), pattern: pattern)
            }
            let starts = (0..<max(0, data.count - m + 1)).filter { start in
                zip(pattern.elements, data[start..<start + m]).allSatisfy { $0.matches($1) }
            }
            let a = Int.random(in: 0...data.count, using: &rng)
            let b = Int.random(in: a...data.count, using: &rng)
            let window = UInt64(a)..<UInt64(b)
            let context: Comment = "seed \(seed), pattern \(pattern.elements), data \(data)"

            var first = scan()
            #expect(
                try first.first(window) == starts.first { $0 >= a && $0 < b }.map(UInt64.init),
                context)
            var last = scan()
            #expect(
                try last.last(window) == starts.last { $0 >= a && $0 < b }.map(UInt64.init),
                context)

            var expected: [UInt64] = []
            for start in starts where start >= (expected.last.map { Int($0) + m } ?? 0) {
                expected.append(UInt64(start))
            }
            var all = scan()
            var found: [UInt64] = []
            try all.forward(0..<source.length) { start in
                found.append(start)
                return start + UInt64(m)
            }
            #expect(found == expected, context)
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

/// A small seeded generator, so a failing random test can be replayed from its seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
