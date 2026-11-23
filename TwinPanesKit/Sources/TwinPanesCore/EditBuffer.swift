import Foundation

/// One version of an edited file: a piece tree over the original and the add buffer
/// (decision D-c, docs/plans/M3a.md). Snapshots are immutable and `Sendable`, so a
/// search or a save reads one on a background thread while editing goes on.
public struct EditSnapshot: ByteReading {
    public let tree: PieceTree
    public let original: ByteSource
    /// Nil until the first edit; a tree has `.add` pieces only once it exists.
    public let add: AddBuffer?

    public init(tree: PieceTree, original: ByteSource, add: AddBuffer?) {
        self.tree = tree
        self.original = original
        self.add = add
    }

    public var length: UInt64 { tree.length }

    /// Reads `range`, blocking on I/O if needed.
    public func read(_ range: Range<UInt64>) throws -> Data {
        var out = Data(capacity: clampedCount(range))
        for (_, piece) in spans(range) {
            let range = piece.offset..<(piece.offset + piece.length)
            out.append(try piece.source == .original ? original.read(range) : add!.read(range))
        }
        return out
    }

    /// Reads `range` for a one-pass scan, bypassing both sources' page caches.
    public func readSequential(_ range: Range<UInt64>) throws -> Data {
        var out = Data(capacity: clampedCount(range))
        for (_, piece) in spans(range) {
            let range = piece.offset..<(piece.offset + piece.length)
            let data =
                try piece.source == .original
                ? original.readSequential(range) : add!.readSequential(range)
            out.append(data)
            // The original got shorter: later bytes would land at the wrong offsets.
            if data.count < range.count { break }
        }
        return out
    }

    /// All of `range` if every byte is in memory, else nil; never blocks.
    public func cachedBytes(_ range: Range<UInt64>) -> Data? {
        var out = Data(capacity: clampedCount(range))
        for (_, piece) in spans(range) {
            let range = piece.offset..<(piece.offset + piece.length)
            let data =
                piece.source == .original ? original.cachedBytes(range) : add!.cachedBytes(range)
            guard let data else { return nil }
            out.append(data)
        }
        return out
    }

    /// Loads what `range` needs from both sources in the background, then calls
    /// `completion` on the main queue with any error.
    public func prefetch(
        _ range: Range<UInt64>, supersede: Bool = true,
        completion: @escaping @MainActor @Sendable (ByteSourceError?) -> Void
    ) {
        let pieces = spans(range).map(\.piece)
        let originalRanges = Self.coalesce(
            pieces.filter { $0.source == .original }.map { $0.offset..<($0.offset + $0.length) },
            maxGap: ByteSource.pageSize)
        let addRanges = pieces.filter { $0.source == .add }.map {
            $0.offset..<($0.offset + $0.length)
        }
        let addTicket = add?.nextPrefetchTicket(supersede: supersede)
        original.prefetch(originalRanges, supersede: supersede) { [add] error in
            if let error {
                completion(error)
            } else if let add, !addRanges.isEmpty {
                add.prefetch(addRanges, ticket: addTicket, completion: completion)
            } else {
                completion(nil)
            }
        }
    }

    /// The parts of `range` that hold edited bytes, in order and merged.
    public func modifiedRanges(in range: Range<UInt64>) -> [Range<UInt64>] {
        var result: [Range<UInt64>] = []
        for (start, piece) in spans(range) where piece.source == .add {
            let end = start + piece.length
            if let last = result.last, last.upperBound == start {
                result[result.count - 1] = last.lowerBound..<end
            } else {
                result.append(start..<end)
            }
        }
        return result
    }

    /// The pieces of `range` with the file offset each starts at.
    private func spans(_ range: Range<UInt64>) -> [(start: UInt64, piece: Piece)] {
        var position = min(range.lowerBound, length)
        return tree.pieces(in: range).map { piece in
            defer { position += piece.length }
            return (position, piece)
        }
    }

    private func clampedCount(_ range: Range<UInt64>) -> Int {
        let lower = min(range.lowerBound, length), upper = min(range.upperBound, length)
        return Int(min(upper - lower, UInt64(Int.max)))
    }

    /// Merges adjacent ascending ranges separated by at most `maxGap`, so small scattered
    /// edits share one read while large deleted or overwritten spans are skipped.
    private static func coalesce(
        _ ranges: [Range<UInt64>], maxGap: UInt64
    ) -> [Range<UInt64>] {
        var merged: [Range<UInt64>] = []
        for range in ranges where !range.isEmpty {
            if let last = merged.last, range.lowerBound >= last.upperBound,
                range.lowerBound - last.upperBound <= maxGap
            {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// The edit model of one open file: the original, the add buffer and the current tree.
/// Not thread-safe; it belongs to the editor's actor, and other threads use snapshots.
public final class EditBuffer {
    /// The file the original pieces read: the file as opened, or the session's clone
    /// once `attach` swapped it in (docs/plans/M3c.md).
    public private(set) var original: ByteSource
    /// Holds typed bytes; made on the first edit (or given by `attach`), so viewing a file
    /// writes nothing.
    public private(set) var add: AddBuffer?
    /// The current version.
    public private(set) var tree: PieceTree
    /// The version the file was opened with.
    public let openedTree: PieceTree

    /// A buffer that makes its add buffer, in the temporary folder, on the first edit.
    public init(original: ByteSource) {
        self.original = original
        tree = PieceTree(originalLength: original.length)
        openedTree = tree
    }

    /// A recovered buffer: `tree` over `original` (the clone) and `add`, as replayed.
    init(original: ByteSource, add: AddBuffer, tree: PieceTree) {
        self.original = original
        self.add = add
        self.tree = tree
        openedTree = PieceTree(originalLength: original.length)
    }

    public init(original: ByteSource, addDirectory: URL?) throws {
        self.original = original
        add = try AddBuffer(directory: addDirectory)
        tree = PieceTree(originalLength: original.length)
        openedTree = tree
    }

    init(original: ByteSource, addDirectory: URL? = nil, addPageCapacity: Int) throws {
        self.original = original
        add = try AddBuffer(directory: addDirectory, pageCapacity: addPageCapacity)
        tree = PieceTree(originalLength: original.length)
        openedTree = tree
    }

    public var length: UInt64 { tree.length }
    /// Whether the current version differs from the one opened (by identity: undoing
    /// every edit makes it unmodified again).
    public var isModified: Bool { !tree.isSameVersion(as: openedTree) }

    /// Switches to `original` (the session's clone: same length, same bytes) and `add`
    /// (in the session folder), once, before the first edit. Snapshots taken before keep
    /// reading what they had.
    public func attach(original: ByteSource, add: AddBuffer) {
        precondition(original.length == self.original.length, "a clone of another length")
        precondition((self.add?.length ?? 0) == 0, "attach after an edit")
        self.original = original
        self.add = add
    }

    public func snapshot() -> EditSnapshot {
        EditSnapshot(tree: tree, original: original, add: add)
    }

    /// Overwrites the bytes at `offset` with `bytes`, which must fit in the file, and
    /// returns the range changed.
    @discardableResult
    public func overwrite(at offset: UInt64, with bytes: Data) throws -> Range<UInt64> {
        let count = UInt64(bytes.count)
        guard offset <= length, count <= length - offset else {
            throw ByteSourceError.truncated(expected: offset + count, available: length)
        }
        guard count > 0 else { return offset..<offset }
        let add = try self.add ?? AddBuffer()
        self.add = add
        let added = try add.append(bytes)
        tree = tree.overwriting(
            at: offset, with: Piece(.add, offset: added.lowerBound, length: count))
        return offset..<(offset + count)
    }

    /// Makes `version` current (an undo or redo).
    public func restore(_ version: PieceTree) { tree = version }
}
