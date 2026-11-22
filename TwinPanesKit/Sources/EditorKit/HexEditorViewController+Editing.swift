import AppKit
import HexViewKit
import TwinPanesCore

/// Typing and undo in the editor tab (docs/plans/M3a.md). The hex view works out the
/// bytes; the item writes them into its session, which keeps the history.
extension HexEditorViewController {
    func hexView(
        _ view: HexView, overwrite bytes: Data, at offset: UInt64, column: HexLayout.Column,
        cursorAfter: UInt64
    ) -> Bool {
        guard let item else { return false }
        // Set before writing: the session tells the item about the edit at once, and the
        // item leaves the status line and inspector to `hexViewSelectionDidChange`, which
        // `HexView` calls right after with the new cursor (and which clears the flag).
        applyingTypingEdit = true
        let written = item.overwrite(
            bytes, at: offset, column: column, selectionBefore: view.selection.range,
            cursorAfter: cursorAfter)
        if !written { applyingTypingEdit = false }
        return written
    }

    func hexView(_ view: HexView, cannotEncode character: Character) {
        let encoding = view.options.textEncoding == .ascii ? "ASCII" : "Latin-1"
        item?.host?.showStatus("“\(character)” can't be typed in the \(encoding) text column")
    }

    @objc func undo(_ sender: Any?) { show(item?.undo()) }
    @objc func redo(_ sender: Any?) { show(item?.redo()) }

    /// The session already told the item, which refreshed the tab; this restores the
    /// selection the step was made with.
    private func show(_ state: UndoStack.State?) {
        guard let state else { return NSSound.beep() }
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
