import AppKit
import HexViewKit
import TwinPanesCore

/// Typing and undo in the editor tab (docs/plans/M3a.md). The hex view works out the
/// bytes; the item writes them and keeps the history.
extension HexEditorViewController {
    func hexView(
        _ view: HexView, overwrite bytes: Data, at offset: UInt64, column: HexLayout.Column,
        cursorAfter: UInt64
    ) -> Bool {
        guard let item,
            item.overwrite(
                bytes, at: offset, column: column, selectionBefore: view.selection.range,
                cursorAfter: cursorAfter)
        else { return false }
        clearFindResults()
        // `HexView` immediately moves the cursor and calls `hexViewSelectionDidChange`,
        // which refreshes the view, status line and inspector once with the new cursor.
        applyingTypingEdit = true
        return true
    }

    func hexView(_ view: HexView, cannotEncode character: Character) {
        let encoding = view.options.textEncoding == .ascii ? "ASCII" : "Latin-1"
        item?.host?.showStatus("“\(character)” can't be typed in the \(encoding) text column")
    }

    @objc func undo(_ sender: Any?) { show(item?.undo()) }
    @objc func redo(_ sender: Any?) { show(item?.redo()) }

    private func show(_ state: UndoStack.State?) {
        guard let state else { return NSSound.beep() }
        bytesChanged()
        hexView.select(state.selection)
    }

    /// Find results may no longer match the bytes, so they go; the view and the
    /// inspector redraw from the new version.
    func bytesChanged() {
        clearFindResults()
        hexView.needsDisplay = true
        item?.updateStatus()
        updateInspector()
    }

    func clearFindResults() {
        hexView.highlights = []
        allMatches = nil
        lastMatch = nil
    }
}
