import Darwin
import Foundation
import Synchronization

/// Stops a running search at its next chunk.
public final class SearchCancellation: Sendable {
    private let flag = Atomic(false)
    public init() {}
    public func cancel() { flag.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

/// Called after each chunk with bytes scanned so far and the total to scan.
public typealias SearchProgress = @Sendable (_ scanned: UInt64, _ total: UInt64) -> Void

/// One search pass over `source` (PLAN.md §4.5): reads chunks of `chunkSize` through
/// `readSequential`, each overlapping the next by the pattern length − 1 so matches
/// across a boundary count; checks for cancellation and reports progress per chunk.
struct SearchScan {
    let source: any ByteReading
    let chunkSize: UInt64
    let pattern: SearchPattern
    /// What progress reports as the total (a wrapped search scans in two passes).
    let total: UInt64
    let cancellation: SearchCancellation
    let progress: SearchProgress?
    var scanned: UInt64 = 0

    init(
        _ source: any ByteReading, chunkSize: UInt64, pattern: SearchPattern,
        total: UInt64? = nil, cancellation: SearchCancellation = .init(),
        progress: SearchProgress? = nil
    ) {
        self.source = source
        self.chunkSize = max(1, chunkSize)
        self.pattern = pattern
        self.total = total ?? source.length
        self.cancellation = cancellation
        self.progress = progress
    }

    /// The first match whose start lies in `starts`.
    mutating func first(_ starts: Range<UInt64>) throws -> UInt64? {
        var found: UInt64?
        try forward(starts) { start in
            found = start
            return nil
        }
        return found
    }

    /// The last match whose start lies in `starts`, reading chunks from the end.
    mutating func last(_ starts: Range<UInt64>) throws -> UInt64? {
        var end = starts.upperBound
        while end > starts.lowerBound {
            let begin = end - min(chunkSize, end - starts.lowerBound)
            var found: UInt64?
            try chunk(begin..<end) { start in
                found = start
                return start + 1
            }
            if let found { return found }
            end = begin
        }
        return nil
    }

    /// Calls `body` with each match starting in `starts`, in order. `body` returns where
    /// the next match may start, or nil to stop.
    mutating func forward(
        _ starts: Range<UInt64>, _ body: (UInt64) -> UInt64?
    ) throws {
        var begin = starts.lowerBound
        var stopped = false
        // Carries across chunks, so a match that straddles a boundary counts once.
        var resume = begin
        while begin < starts.upperBound, !stopped {
            let end = min(starts.upperBound, begin + chunkSize)
            try chunk(begin..<end) { start in
                guard start >= resume else { return resume }
                guard let next = body(start) else {
                    stopped = true
                    return nil
                }
                resume = next
                return next
            }
            begin = end
        }
    }

    /// Scans the matches starting in `starts` (one chunk), reading `pattern.count - 1`
    /// bytes past its end. `body` returns the next start to look at, or nil to stop.
    private mutating func chunk(
        _ starts: Range<UInt64>, _ body: (UInt64) -> UInt64?
    ) throws {
        if cancellation.isCancelled { throw CancellationError() }
        let m = UInt64(pattern.count)
        let readEnd = min(source.length, starts.upperBound + m - 1)
        let data = try source.readSequential(starts.lowerBound..<readEnd)
        let base = starts.lowerBound
        data.withUnsafeBytes { buffer in
            Self.matches(
                pattern, in: buffer, before: starts.count,
                from: 0
            ) { index in
                body(base + UInt64(index)).map { Int($0 - base) }
            }
        }
        scanned += UInt64(starts.count)
        progress?(min(scanned, total), total)
    }

    /// Matches in `buffer` starting in `from..<before`; `body` returns the next index to
    /// look at, or nil to stop. Finds the anchor byte with `memchr`, then verifies; with no
    /// anchor, finds either case of the first byte the same way.
    static func matches(
        _ pattern: SearchPattern, in buffer: UnsafeRawBufferPointer, before limit: Int,
        from start: Int, _ body: (Int) -> Int?
    ) {
        let elements = pattern.elements
        let m = elements.count
        let last = min(limit, buffer.count - m + 1)
        guard start < last, let raw = buffer.baseAddress else { return }
        let bytes = raw.assumingMemoryBound(to: UInt8.self)

        @inline(__always) func verify(_ at: Int) -> Bool {
            for k in 0..<m where !elements[k].matches(bytes[at + k]) { return false }
            return true
        }

        var i = start
        if let anchor = pattern.anchor {
            let target = Int32(elements[anchor].byte)
            while i < last {
                guard let hit = memchr(bytes + i + anchor, target, last - i) else { return }
                let at = bytes.distance(to: hit.assumingMemoryBound(to: UInt8.self)) - anchor
                if verify(at) {
                    guard let next = body(at) else { return }
                    i = max(next, at + 1)
                } else {
                    i = at + 1
                }
            }
        } else {
            // Every position folds case: find the first element's two bytes with one
            // `memchr` each, keeping each hit until the scan passes it.
            let first = elements[0]
            @inline(__always) func find(_ byte: UInt8, from i: Int) -> Int {
                guard let hit = memchr(bytes + i, Int32(byte), last - i) else { return last }
                return bytes.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            }
            var nextByte = find(first.byte, from: i)
            var nextAlternative = find(first.alternative, from: i)
            while true {
                if nextByte < i { nextByte = find(first.byte, from: i) }
                if nextAlternative < i { nextAlternative = find(first.alternative, from: i) }
                let at = min(nextByte, nextAlternative)
                guard at < last else { return }
                if verify(at) {
                    guard let next = body(at) else { return }
                    i = max(next, at + 1)
                } else {
                    i = at + 1
                }
                guard i < last else { return }
            }
        }
    }
}
