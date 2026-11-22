/// A run of bytes taken from one of the edit model's two sources (PLAN.md §4.2).
public struct Piece: Equatable, Sendable, CustomStringConvertible {
    public enum Source: Equatable, Sendable {
        /// The file as opened (or, from M3b, its clone).
        case original
        /// The append-only add buffer holding every byte typed or pasted.
        case add
    }

    public var source: Source
    /// Where the run starts in `source`.
    public var offset: UInt64
    /// Never zero inside a tree.
    public var length: UInt64

    public init(_ source: Source, offset: UInt64, length: UInt64) {
        self.source = source
        self.offset = offset
        self.length = length
    }

    public var description: String { "\(source)[\(offset)+\(length)]" }
}

/// An immutable node of a `PieceTree`. Nodes are shared between trees, so they never
/// change after they're made.
final class PieceNode: Sendable {
    let piece: Piece
    let left: PieceNode?
    let right: PieceNode?
    let height: Int
    /// Bytes in this subtree.
    let length: UInt64
    /// Pieces in this subtree.
    let count: Int

    init(_ left: PieceNode?, _ piece: Piece, _ right: PieceNode?) {
        self.piece = piece
        self.left = left
        self.right = right
        height = max(left.height, right.height) + 1
        length = left.length + piece.length + right.length
        count = left.count + 1 + right.count
    }
}

extension Optional where Wrapped == PieceNode {
    var height: Int { self?.height ?? 0 }
    var length: UInt64 { self?.length ?? 0 }
    var count: Int { self?.count ?? 0 }
}

/// The edit model's sequence of pieces: a persistent AVL tree keyed by cumulative
/// length (decision D-a, docs/plans/M3a.md). Every operation returns a new tree and
/// copies only O(log n) nodes, so keeping an old tree around (a snapshot, an undo
/// entry) costs nothing and is safe from any thread.
public struct PieceTree: Sendable {
    let root: PieceNode?

    init(root: PieceNode?) { self.root = root }

    /// An empty tree.
    public init() { root = nil }

    /// The unedited file: one original piece covering `length` bytes.
    public init(originalLength length: UInt64) {
        root = length == 0 ? nil : PieceNode(nil, Piece(.original, offset: 0, length: length), nil)
    }

    public var length: UInt64 { root.length }
    public var pieceCount: Int { root.count }

    /// The pieces covering `range` (clamped to the tree), the first and last cut to fit,
    /// in order.
    public func pieces(in range: Range<UInt64>) -> [Piece] {
        var result: [Piece] = []
        let upper = min(range.upperBound, length)
        if range.lowerBound < upper { Self.collect(root, range.lowerBound..<upper, into: &result) }
        return result
    }

    /// The bytes before `offset` and the bytes from `offset` on. A piece that straddles
    /// `offset` is cut in two.
    public func split(at offset: UInt64) -> (PieceTree, PieceTree) {
        let (left, right) = Self.split(root, at: offset)
        return (PieceTree(root: left), PieceTree(root: right))
    }

    /// `self` followed by `other`.
    public func appending(_ other: PieceTree) -> PieceTree {
        guard let otherRoot = other.root else { return self }
        guard root != nil else { return other }
        let (rest, first) = Self.removeFirst(otherRoot)
        return PieceTree(root: Self.join(root, first, rest))
    }

    /// `self` followed by one more piece.
    public func appending(_ piece: Piece) -> PieceTree {
        precondition(piece.length > 0, "empty piece")
        return PieceTree(root: Self.join(root, piece, nil))
    }

    /// Checks the AVL balance and the cached heights, lengths and counts; for tests.
    func isValid() -> Bool { Self.check(root) != nil }

    // MARK: Tree algorithms (join-based AVL, Blelloch et al. 2016)

    private static func collect(
        _ node: PieceNode?, _ range: Range<UInt64>, into result: inout [Piece]
    ) {
        guard let node, !range.isEmpty else { return }
        let leftLength = node.left.length
        let pieceEnd = leftLength + node.piece.length
        if range.lowerBound < leftLength {
            collect(node.left, range.lowerBound..<min(range.upperBound, leftLength), into: &result)
        }
        let lower = max(range.lowerBound, leftLength), upper = min(range.upperBound, pieceEnd)
        if lower < upper {
            var piece = node.piece
            piece.offset += lower - leftLength
            piece.length = upper - lower
            result.append(piece)
        }
        if range.upperBound > pieceEnd {
            let from = max(range.lowerBound, pieceEnd) - pieceEnd
            collect(node.right, from..<(range.upperBound - pieceEnd), into: &result)
        }
    }

    static func split(_ node: PieceNode?, at offset: UInt64) -> (PieceNode?, PieceNode?) {
        guard let node else { return (nil, nil) }
        let leftLength = node.left.length
        let pieceEnd = leftLength + node.piece.length
        if offset <= leftLength {
            let (low, high) = split(node.left, at: offset)
            return (low, join(high, node.piece, node.right))
        }
        if offset >= pieceEnd {
            let (low, high) = split(node.right, at: offset - pieceEnd)
            return (join(node.left, node.piece, low), high)
        }
        let cut = offset - leftLength
        var head = node.piece, tail = node.piece
        head.length = cut
        tail.offset += cut
        tail.length -= cut
        return (join(node.left, head, nil), join(nil, tail, node.right))
    }

    static func removeFirst(_ node: PieceNode) -> (PieceNode?, Piece) {
        guard let left = node.left else { return (node.right, node.piece) }
        let (rest, first) = removeFirst(left)
        return (join(rest, node.piece, node.right), first)
    }

    static func removeLast(_ node: PieceNode) -> (PieceNode?, Piece) {
        guard let right = node.right else { return (node.left, node.piece) }
        let (rest, last) = removeLast(right)
        return (join(node.left, node.piece, rest), last)
    }

    /// `left`, then `piece`, then `right`, rebalanced. Every key of `left` comes before
    /// every key of `right`; their heights may differ by any amount.
    static func join(_ left: PieceNode?, _ piece: Piece, _ right: PieceNode?) -> PieceNode {
        if left.height > right.height + 1 { return joinRight(left!, piece, right) }
        if right.height > left.height + 1 { return joinLeft(left, piece, right!) }
        return PieceNode(left, piece, right)
    }

    private static func joinRight(
        _ left: PieceNode, _ piece: Piece, _ right: PieceNode?
    ) -> PieceNode {
        let inner = left.right
        if inner.height <= right.height + 1 {
            let joined = PieceNode(inner, piece, right)
            if joined.height <= left.left.height + 1 {
                return PieceNode(left.left, left.piece, joined)
            }
            return rotateLeft(PieceNode(left.left, left.piece, rotateRight(joined)))
        }
        let joined = joinRight(inner!, piece, right)
        let node = PieceNode(left.left, left.piece, joined)
        return joined.height <= left.left.height + 1 ? node : rotateLeft(node)
    }

    private static func joinLeft(
        _ left: PieceNode?, _ piece: Piece, _ right: PieceNode
    ) -> PieceNode {
        let inner = right.left
        if inner.height <= left.height + 1 {
            let joined = PieceNode(left, piece, inner)
            if joined.height <= right.right.height + 1 {
                return PieceNode(joined, right.piece, right.right)
            }
            return rotateRight(PieceNode(rotateLeft(joined), right.piece, right.right))
        }
        let joined = joinLeft(left, piece, inner!)
        let node = PieceNode(joined, right.piece, right.right)
        return joined.height <= right.right.height + 1 ? node : rotateRight(node)
    }

    private static func rotateLeft(_ node: PieceNode) -> PieceNode {
        guard let right = node.right else { return node }
        return PieceNode(PieceNode(node.left, node.piece, right.left), right.piece, right.right)
    }

    private static func rotateRight(_ node: PieceNode) -> PieceNode {
        guard let left = node.left else { return node }
        return PieceNode(left.left, left.piece, PieceNode(left.right, node.piece, node.right))
    }

    /// The subtree's height if it's a valid AVL tree with correct caches, else nil.
    private static func check(_ node: PieceNode?) -> Int? {
        guard let node else { return 0 }
        guard let left = check(node.left), let right = check(node.right), abs(left - right) <= 1,
            node.piece.length > 0, node.height == max(left, right) + 1,
            node.length == node.left.length + node.piece.length + node.right.length,
            node.count == node.left.count + 1 + node.right.count
        else { return nil }
        return node.height
    }
}
