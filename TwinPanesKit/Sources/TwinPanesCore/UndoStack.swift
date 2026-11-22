/// Undo as a stack of earlier versions (PLAN.md §4.2): each entry keeps the tree and
/// selection from before and after one edit, so undo and redo just swap versions back in.
/// A typing burst coalesces into one entry by replacing the top entry's "after".
public struct UndoStack: Sendable {
    /// A version plus the selection to restore with it.
    public struct State: Sendable {
        public var tree: PieceTree
        public var selection: Range<UInt64>

        public init(tree: PieceTree, selection: Range<UInt64>) {
            self.tree = tree
            self.selection = selection
        }
    }

    private var undoEntries: [(before: State, after: State)] = []
    private var redoEntries: [(before: State, after: State)] = []

    public init() {}

    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    /// Entries that undo would step through; for tests and memory checks.
    public var undoCount: Int { undoEntries.count }

    /// Records an edit from `before` to `after` and clears redo. With `coalescing`, an
    /// edit that continues the top entry (its "after" is `before`'s version) extends that
    /// entry instead of pushing a new one.
    public mutating func record(before: State, after: State, coalescing: Bool = false) {
        redoEntries.removeAll()
        if coalescing, let top = undoEntries.last, top.after.tree.isSameVersion(as: before.tree) {
            undoEntries[undoEntries.count - 1].after = after
        } else {
            undoEntries.append((before, after))
        }
    }

    /// The state to go back to, or nil if there's nothing to undo.
    public mutating func undo() -> State? {
        guard let entry = undoEntries.popLast() else { return nil }
        redoEntries.append(entry)
        return entry.before
    }

    /// The state to go forward to, or nil if there's nothing to redo.
    public mutating func redo() -> State? {
        guard let entry = redoEntries.popLast() else { return nil }
        undoEntries.append(entry)
        return entry.after
    }
}
