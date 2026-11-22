import Testing

@testable import TwinPanesCore

/// The bytes a tree stands for, given its two sources.
private func bytes(_ tree: PieceTree, original: [UInt8], add: [UInt8]) -> [UInt8] {
    tree.pieces(in: 0..<tree.length).flatMap { piece in
        let source = piece.source == .original ? original : add
        return source[Int(piece.offset)..<Int(piece.offset + piece.length)]
    }
}

struct PieceTreeEditTests {
    @Test func overwriteInsertAndRemove() {
        let original: [UInt8] = Array(0..<10)
        let add: [UInt8] = [0xA0, 0xA1, 0xA2]
        let tree = PieceTree(originalLength: 10)
        let written = tree.overwriting(at: 4, with: Piece(.add, offset: 0, length: 2))
        #expect(
            bytes(written, original: original, add: add) == [0, 1, 2, 3, 0xA0, 0xA1, 6, 7, 8, 9])
        let inserted = written.inserting(Piece(.add, offset: 2, length: 1), at: 10)
        #expect(inserted.length == 11)
        #expect(bytes(inserted, original: original, add: add).last == 0xA2)
        let removed = inserted.removing(0..<5)
        #expect(bytes(removed, original: original, add: add) == [0xA1, 6, 7, 8, 9, 0xA2])
        // The earlier trees are untouched.
        #expect(bytes(tree, original: original, add: add) == original)
        #expect(written.length == 10)
    }

    /// Typing 500 bytes in a row (each landing right after the last in the add buffer)
    /// stays three pieces: before, typed, after.
    @Test func sequentialTypingCoalesces() {
        var tree = PieceTree(originalLength: 1000)
        for index in 0..<500 {
            tree = tree.overwriting(
                at: 100 + UInt64(index), with: Piece(.add, offset: UInt64(index), length: 1))
        }
        #expect(tree.pieceCount == 3)
        #expect(tree.isValid())
        // Deleting what was typed in between joins the original back into one piece.
        let inserted = PieceTree(originalLength: 1000).inserting(
            Piece(.add, offset: 0, length: 5), at: 300)
        #expect(inserted.pieceCount == 3)
        #expect(inserted.removing(300..<305).pieceCount == 1)

        // Right-neighbour coalescing: inserting right before a piece it continues merges them.
        let rightMerged = PieceTree(originalLength: 10)
            .inserting(Piece(.add, offset: 5, length: 2), at: 4)
            .inserting(Piece(.add, offset: 3, length: 2), at: 4)
        #expect(rightMerged.pieceCount == 3)
        #expect(rightMerged.pieces(in: 4..<8) == [Piece(.add, offset: 3, length: 4)])

        // Zero-length replace and deleting the whole tree keep invariants intact.
        let unchanged = rightMerged.replacing(4..<4, with: nil)
        #expect(unchanged.length == rightMerged.length && unchanged.isValid())
        let empty = rightMerged.removing(0..<rightMerged.length)
        #expect(empty.length == 0 && empty.pieceCount == 0 && empty.isValid())
    }

    /// Random overwrites, inserts and deletes against a flat byte array, with snapshots
    /// taken along the way checked again at the end.
    @Test func randomEditsMatchAFlatModel() {
        let seed: UInt64 = 0xED17_5EED_0000_0042
        var rng = SplitMix64(seed: seed)
        for round in 0..<300 {
            let original = (0..<Int.random(in: 0...200, using: &rng)).map { _ in
                UInt8.random(in: 0...255, using: &rng)
            }
            var add: [UInt8] = []
            var tree = PieceTree(originalLength: UInt64(original.count))
            var model = original
            var snapshots: [(PieceTree, [UInt8])] = []
            for step in 0..<60 {
                let context: Comment = "seed \(seed), round \(round), step \(step)"
                let typed = (0..<Int.random(in: 1...8, using: &rng)).map { _ in
                    UInt8.random(in: 0...255, using: &rng)
                }
                let offset = Int.random(in: 0...model.count, using: &rng)
                switch Int.random(in: 0..<3, using: &rng) {
                case 0 where offset < model.count:
                    let count = min(typed.count, model.count - offset)
                    let piece = Piece(.add, offset: UInt64(add.count), length: UInt64(count))
                    add += typed[..<count]
                    tree = tree.overwriting(at: UInt64(offset), with: piece)
                    model.replaceSubrange(offset..<(offset + count), with: typed[..<count])
                case 1:
                    let piece = Piece(.add, offset: UInt64(add.count), length: UInt64(typed.count))
                    add += typed
                    tree = tree.inserting(piece, at: UInt64(offset))
                    model.insert(contentsOf: typed, at: offset)
                default:
                    let end = Int.random(in: offset...min(model.count, offset + 10), using: &rng)
                    tree = tree.removing(UInt64(offset)..<UInt64(end))
                    model.removeSubrange(offset..<end)
                }
                #expect(tree.isValid(), context)
                #expect(bytes(tree, original: original, add: add) == model, context)
                if step % 10 == 0 { snapshots.append((tree, model)) }
            }
            for (index, (snapshot, expected)) in snapshots.enumerated() {
                #expect(
                    bytes(snapshot, original: original, add: add) == expected,
                    "seed \(seed), round \(round), snapshot \(index)")
            }
        }
    }
}
