import Foundation

/// Streaming search over any `ByteReading` (PLAN.md §4.5), built on `SearchScan`:
/// large chunks through `readSequential`, so a full scan of a 4 GB file doesn't evict
/// the view's pages.
///
/// The search calls are synchronous and run on the caller's thread. `run(_:)` puts one
/// on the searcher's own serial queue and cancels it with the calling task.
public struct Searcher: Sendable {
    public static let defaultChunkSize = 4 << 20
    /// "Find all" keeps at most this many matches and then reports that there are more.
    public static let defaultLimit = 100_000

    public enum Direction: Sendable { case forward, backward }

    public struct Match: Equatable, Sendable {
        public let range: Range<UInt64>
        /// The search went past the end (or start) of the file and continued from the
        /// other end.
        public let wrapped: Bool
    }

    public struct AllMatches: Equatable, Sendable {
        public let ranges: [Range<UInt64>]
        /// More matches exist than `ranges` holds.
        public let isTruncated: Bool
    }

    public typealias Progress = SearchProgress

    public let source: any ByteReading
    let chunkSize: UInt64

    public init(source: any ByteReading, chunkSize: Int = Searcher.defaultChunkSize) {
        self.source = source
        self.chunkSize = UInt64(max(1, chunkSize))
    }

    /// Forward: the first match starting at or after `offset`. Backward: the last match
    /// starting before `offset`. With `wraps`, continues from the other end of the file.
    public func next(
        _ pattern: SearchPattern, from offset: UInt64, direction: Direction,
        wraps: Bool = true, cancellation: SearchCancellation = .init(),
        progress: Progress? = nil
    ) throws -> Match? {
        let split = min(offset, source.length)
        let length = source.length
        var scan = SearchScan(
            source, chunkSize: chunkSize, pattern: pattern, cancellation: cancellation,
            progress: progress)
        let (first, second) =
            direction == .forward ? (split..<length, 0..<split) : (0..<split, split..<length)
        func find(_ starts: Range<UInt64>) throws -> UInt64? {
            direction == .forward ? try scan.first(starts) : try scan.last(starts)
        }
        let m = UInt64(pattern.count)
        if let start = try find(first) { return Match(range: start..<start + m, wrapped: false) }
        guard wraps, let start = try find(second) else { return nil }
        return Match(range: start..<start + m, wrapped: true)
    }

    /// Every non-overlapping match from the start of the file, up to `limit`.
    public func all(
        _ pattern: SearchPattern, limit: Int = Searcher.defaultLimit,
        cancellation: SearchCancellation = .init(), progress: Progress? = nil
    ) throws -> AllMatches {
        var scan = SearchScan(
            source, chunkSize: chunkSize, pattern: pattern, cancellation: cancellation,
            progress: progress)
        let m = UInt64(pattern.count)
        var ranges: [Range<UInt64>] = []
        var truncated = false
        try scan.forward(0..<source.length) { start in
            guard ranges.count < limit else {
                truncated = true
                return nil
            }
            ranges.append(start..<start + m)
            return start + m
        }
        return AllMatches(ranges: ranges, isTruncated: truncated)
    }

    private static let queue = DispatchQueue(label: "Searcher", qos: .userInitiated)

    /// Runs `work` on the search queue. Cancelling the calling task cancels the search,
    /// which then throws `CancellationError` at the next chunk.
    public static func run<T: Sendable>(
        _ work: @escaping @Sendable (SearchCancellation) throws -> T
    ) async throws -> T {
        let token = SearchCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { continuation.resume(with: Result { try work(token) }) }
            }
        } onCancel: {
            token.cancel()
        }
    }
}
