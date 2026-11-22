import Testing

@testable import TwinPanesCore

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
