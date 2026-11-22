import Testing

@testable import TwinPanesCore

/// Undo or redo, failing the test if there was nothing to do.
private func undo(_ stack: inout UndoStack) throws -> UndoStack.State {
    let state = stack.undo()
    return try #require(state)
}

private func redo(_ stack: inout UndoStack) throws -> UndoStack.State {
    let state = stack.redo()
    return try #require(state)
}

struct UndoStackTests {
    typealias State = UndoStack.State

    let opened = PieceTree(originalLength: 10)

    func typed(_ tree: PieceTree, at offset: UInt64, add: UInt64) -> PieceTree {
        tree.overwriting(at: offset, with: Piece(.add, offset: add, length: 1))
    }

    @Test func undoAndRedoSwapVersions() throws {
        var stack = UndoStack()
        let none = (stack.undo(), stack.redo())
        #expect(none.0 == nil && none.1 == nil)
        let first = typed(opened, at: 0, add: 0)
        let second = typed(first, at: 5, add: 1)
        stack.record(
            before: State(tree: opened, selection: 0..<0),
            after: State(tree: first, selection: 1..<1))
        stack.record(
            before: State(tree: first, selection: 5..<5),
            after: State(tree: second, selection: 6..<6))
        let back = try undo(&stack)
        #expect(back.tree.isSameVersion(as: first) && back.selection == 5..<5)
        #expect(try undo(&stack).tree.isSameVersion(as: opened))
        #expect(!stack.canUndo && stack.canRedo)
        #expect(try redo(&stack).tree.isSameVersion(as: first))
        // A new edit clears what's left to redo.
        stack.record(
            before: State(tree: first, selection: 2..<2),
            after: State(tree: typed(first, at: 2, add: 2), selection: 3..<3))
        #expect(!stack.canRedo)
        #expect(stack.undoCount == 2)
    }

    @Test func coalescingExtendsTheTopEntry() throws {
        var stack = UndoStack()
        var tree = opened
        for index in 0..<5 {
            let next = typed(tree, at: UInt64(index), add: UInt64(index))
            stack.record(
                before: State(tree: tree, selection: UInt64(index)..<UInt64(index)),
                after: State(tree: next, selection: UInt64(index + 1)..<UInt64(index + 1)),
                coalescing: true)
            tree = next
        }
        #expect(stack.undoCount == 1)
        let back = try undo(&stack)
        #expect(back.tree.isSameVersion(as: opened) && back.selection == 0..<0)
        #expect(try redo(&stack).tree.isSameVersion(as: tree))
        // Coalescing never joins an edit that doesn't follow the top entry's version.
        stack.record(
            before: State(tree: opened, selection: 0..<0),
            after: State(tree: typed(opened, at: 9, add: 9), selection: 9..<9), coalescing: true)
        #expect(stack.undoCount == 2)
    }

    /// Random edits, undos and redos against the list of byte arrays they stand for.
    @Test func randomHistoryMatchesTheModel() throws {
        let seed: UInt64 = 0x0DD0_5EED_0000_0077
        var rng = SplitMix64(seed: seed)
        let original = (0..<64).map { _ in UInt8.random(in: 0...255, using: &rng) }
        var add: [UInt8] = []
        func bytes(_ tree: PieceTree) -> [UInt8] {
            tree.pieces(in: 0..<tree.length).flatMap { piece in
                (piece.source == .original ? original : add)[
                    Int(piece.offset)..<Int(piece.offset + piece.length)]
            }
        }
        var stack = UndoStack()
        var tree = PieceTree(originalLength: 64)
        var history = [original]  // versions undo can reach, oldest first
        var position = 0  // index in `history` of the current version
        for step in 0..<2000 {
            let context: Comment = "seed \(seed), step \(step)"
            switch Int.random(in: 0..<4, using: &rng) {
            case 0 where stack.canUndo:
                tree = try undo(&stack).tree
                position -= 1
            case 1 where stack.canRedo:
                tree = try redo(&stack).tree
                position += 1
            default:
                let offset = UInt64.random(in: 0..<64, using: &rng)
                let next = tree.overwriting(
                    at: offset, with: Piece(.add, offset: UInt64(add.count), length: 1))
                add.append(UInt8.random(in: 0...255, using: &rng))
                stack.record(
                    before: State(tree: tree, selection: 0..<0),
                    after: State(tree: next, selection: 0..<0))
                tree = next
                history = Array(history[...position]) + [bytes(tree)]
                position += 1
            }
            #expect(bytes(tree) == history[position], context)
            #expect(
                stack.canUndo == (position > 0) && stack.canRedo == (position < history.count - 1),
                context)
        }
    }
}
