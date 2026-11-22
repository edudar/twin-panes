/// Edits. Each returns a new tree and leaves `self` untouched, so earlier trees stay
/// valid as snapshots and undo entries. A new piece that continues its neighbour in the
/// same source merges into it, so typing a run of bytes stays one piece.
extension PieceTree {
    /// `range` replaced by `piece` (nil deletes `range`). `range` must lie in the tree.
    public func replacing(_ range: Range<UInt64>, with piece: Piece?) -> PieceTree {
        precondition(range.upperBound <= length, "range \(range) outside the tree (\(length))")
        let (left, rest) = Self.split(root, at: range.lowerBound)
        let (_, right) = Self.split(rest, at: range.upperBound - range.lowerBound)
        guard let piece, piece.length > 0 else {
            return PieceTree(root: Self.concatMerging(left, right))
        }
        return PieceTree(root: Self.joinMerging(left, piece, right))
    }

    /// The bytes at `offset` overwritten by `piece`; the length doesn't change.
    public func overwriting(at offset: UInt64, with piece: Piece) -> PieceTree {
        replacing(offset..<(offset + piece.length), with: piece)
    }

    /// `piece` inserted before the byte at `offset` (`offset == length` appends).
    public func inserting(_ piece: Piece, at offset: UInt64) -> PieceTree {
        replacing(offset..<offset, with: piece)
    }

    /// Whether both trees are the same version (shared root), not just equal bytes.
    public func isSameVersion(as other: PieceTree) -> Bool { root === other.root }

    /// The tree without `range`.
    public func removing(_ range: Range<UInt64>) -> PieceTree { replacing(range, with: nil) }

    // MARK: Merging joins

    /// Whether `second` continues `first` in the same source.
    static func continues(_ first: Piece, _ second: Piece) -> Bool {
        first.source == second.source && first.offset + first.length == second.offset
    }

    static func lastPiece(_ node: PieceNode) -> Piece {
        var node = node
        while let right = node.right { node = right }
        return node.piece
    }

    static func firstPiece(_ node: PieceNode) -> Piece {
        var node = node
        while let left = node.left { node = left }
        return node.piece
    }

    /// `join`, merging `piece` into the neighbours it continues.
    static func joinMerging(_ left: PieceNode?, _ piece: Piece, _ right: PieceNode?) -> PieceNode {
        var left = left, piece = piece, right = right
        if let node = left, continues(lastPiece(node), piece) {
            let (rest, last) = removeLast(node)
            piece = Piece(last.source, offset: last.offset, length: last.length + piece.length)
            left = rest
        }
        if let node = right, continues(piece, firstPiece(node)) {
            let (rest, first) = removeFirst(node)
            piece.length += first.length
            right = rest
        }
        return join(left, piece, right)
    }

    /// `left` followed by `right`, merging the two pieces where they meet if they continue
    /// each other.
    static func concatMerging(_ left: PieceNode?, _ right: PieceNode?) -> PieceNode? {
        guard let right else { return left }
        guard left != nil else { return right }
        let (rest, first) = removeFirst(right)
        return joinMerging(left, first, rest)
    }
}
