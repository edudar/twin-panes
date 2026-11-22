import Foundation
import HexViewKit
import TwinPanesCore

/// Overwrite editing and undo for the tab (docs/plans/M3a.md).
extension HexEditorItem {
    /// Typing within this long of the last keystroke, right where it left the cursor and
    /// in the same column, joins the same undo step.
    static let typingPause: Duration = .seconds(2)

    public var isDirty: Bool { buffer.isModified }
    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }

    /// Overwrites `bytes` at `offset` and records the undo step, from `selectionBefore`
    /// to a cursor at `cursorAfter`. Returns false (and shows why) if the write failed.
    func overwrite(
        _ bytes: Data, at offset: UInt64, column: HexLayout.Column,
        selectionBefore: Range<UInt64>, cursorAfter: UInt64,
        now: ContinuousClock.Instant = .now
    ) -> Bool {
        let before = UndoStack.State(tree: buffer.tree, selection: selectionBefore)
        do {
            try buffer.overwrite(at: offset, with: bytes)
        } catch {
            host?.showStatus("Can't change the byte at \(Self.hex(offset)): \(error)")
            return false
        }
        let after = UndoStack.State(tree: buffer.tree, selection: cursorAfter..<(cursorAfter + 1))
        let continues =
            lastTyping.map {
                $0.column == column && now - $0.time < Self.typingPause
                    && selectionBefore == $0.cursorAfter..<($0.cursorAfter + 1)
            } ?? false
        undoStack.record(before: before, after: after, coalescing: continues)
        lastTyping = Typing(column: column, cursorAfter: cursorAfter, time: now)
        onChange?()
        return true
    }

    /// Goes back one undo step; returns the state to show, or nil if there's none.
    func undo() -> UndoStack.State? { restore(undoStack.undo()) }

    /// Goes forward one step; returns the state to show, or nil if there's none.
    func redo() -> UndoStack.State? { restore(undoStack.redo()) }

    private func restore(_ state: UndoStack.State?) -> UndoStack.State? {
        guard let state else { return nil }
        buffer.restore(state.tree)
        lastTyping = nil
        onChange?()
        return state
    }
}
