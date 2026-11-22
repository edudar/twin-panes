import Testing

@testable import TwinPanesCore

/// Every byte of a tree as (source, offset in source), the reference the tree is
/// compared with.
private func identities(_ pieces: [Piece]) -> [Piece] {
    pieces.flatMap { piece in
        (0..<piece.length).map { Piece(piece.source, offset: piece.offset + $0, length: 1) }
    }
}

struct PieceTreeTests {
    @Test func emptyAndOriginal() {
        #expect(PieceTree().length == 0)
        #expect(PieceTree(originalLength: 0).pieceCount == 0)
        let tree = PieceTree(originalLength: 100)
        #expect(tree.length == 100)
        #expect(tree.pieces(in: 0..<100) == [Piece(.original, offset: 0, length: 100)])
        #expect(tree.pieces(in: 10..<20) == [Piece(.original, offset: 10, length: 10)])
        #expect(tree.pieces(in: 90..<500) == [Piece(.original, offset: 90, length: 10)])
        #expect(tree.pieces(in: 100..<200).isEmpty)
    }

    @Test func splitCutsAStraddlingPiece() {
        let (left, right) = PieceTree(originalLength: 10).split(at: 4)
        #expect(left.pieces(in: 0..<10) == [Piece(.original, offset: 0, length: 4)])
        #expect(right.pieces(in: 0..<10) == [Piece(.original, offset: 4, length: 6)])
        let (all, none) = PieceTree(originalLength: 10).split(at: 10)
        #expect(all.length == 10 && none.length == 0)
    }

    /// Builds trees from random pieces, splits and rejoins them at random offsets, and
    /// checks the balance invariants and the byte mapping against a flat reference.
    @Test func randomSplitsAndJoinsKeepTheInvariants() {
        let seed: UInt64 = 0x7EE5_0000_1234_ABCD
        var rng = SplitMix64(seed: seed)
        for round in 0..<200 {
            var tree = PieceTree()
            var reference: [Piece] = []
            for _ in 0..<Int.random(in: 1...60, using: &rng) {
                let piece = Piece(
                    Bool.random(using: &rng) ? .original : .add,
                    offset: UInt64.random(in: 0..<10_000, using: &rng),
                    length: UInt64.random(in: 1...8, using: &rng))
                tree = tree.appending(piece)
                reference.append(piece)
            }
            let context: Comment = "seed \(seed), round \(round)"
            #expect(tree.isValid(), context)
            #expect(tree.pieceCount == reference.count, context)
            let flat = identities(reference)
            #expect(identities(tree.pieces(in: 0..<tree.length)) == flat, context)

            let cut = UInt64.random(in: 0...tree.length, using: &rng)
            let (left, right) = tree.split(at: cut)
            #expect(left.isValid() && right.isValid(), context)
            #expect(identities(left.pieces(in: 0..<cut)) == Array(flat[..<Int(cut)]), context)
            #expect(left.length == cut, context)
            let rejoined = right.appending(left)
            #expect(rejoined.isValid(), context)
            #expect(
                identities(rejoined.pieces(in: 0..<rejoined.length))
                    == Array(flat[Int(cut)...] + flat[..<Int(cut)]), context)

            let start = UInt64.random(in: 0...tree.length, using: &rng)
            let end = UInt64.random(in: start...tree.length, using: &rng)
            #expect(
                identities(tree.pieces(in: start..<end)) == Array(flat[Int(start)..<Int(end)]),
                context)
        }
    }

    @Test func heightStaysLogarithmic() {
        var tree = PieceTree()
        for index in 0..<4096 {
            tree = tree.appending(Piece(.add, offset: UInt64(index) * 2, length: 1))
        }
        #expect(tree.isValid())
        // An AVL tree of n nodes is at most 1.44 log2(n) high: 18 for 4096.
        #expect(tree.root.height <= 18)
    }
}
