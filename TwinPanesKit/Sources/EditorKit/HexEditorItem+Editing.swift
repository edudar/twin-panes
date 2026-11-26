import Foundation
import HexViewKit
import TwinPanesCore

/// Overwrite editing and undo for the tab (docs/plans/M3a.md), through its session
/// (docs/plans/M3b.md).
extension HexEditorItem {
    /// Typing within this long of the last keystroke, right where it left the cursor and
    /// in the same column, joins the same undo step.
    static let typingPause: Duration = .seconds(2)

    public var isDirty: Bool { session.isDirty }
    /// A read-only file can't be saved; its close sheet offers only Discard.
    public var canSave: Bool { session.access.isWritable }
    public var isSaving: Bool { session.isSaving }
    public func finishSaving() async { await session.finishSaving() }

    /// Saves the session (File › Save, and Save in the close sheet).
    public func save() async throws { try await session.save() }

    /// Saves the session to `url` and keeps editing that file (File › Save As…).
    public func saveAs(to url: URL, scope: SecurityScope? = nil) async throws {
        try await session.saveAs(to: url, scope: scope)
        didSaveAs?(url)
    }
    public var canUndo: Bool { session.canUndo }
    public var canRedo: Bool { session.canRedo }

    /// Drops every edit and its history (the close prompt's Discard).
    public func discardChanges() { session.revert() }

    /// Starts a new undo step on the next keystroke (after a cursor move or column switch).
    func breakTypingBurst() { lastTyping = nil }

    /// Checks readiness before an edit reads uncached bytes, surfacing the same status
    /// messages as `overwrite` and returning false if the edit must wait or fail.
    func prepareForEdit() -> Bool {
        do {
            try session.prepareForFirstEdit()
            return true
        } catch {
            reportEditError(error, at: nil)
            return false
        }
    }

    /// Overwrites `bytes` at `offset` and records the undo step, from `selectionBefore` to
    /// a cursor at `cursorAfter`. Returns false (and shows why) if the write failed or the
    /// file is read-only.
    func overwrite(
        _ bytes: Data, at offset: UInt64, column: HexLayout.Column,
        selectionBefore: Range<UInt64>, cursorAfter: UInt64,
        now: ContinuousClock.Instant = .now
    ) -> Bool {
        let continues =
            lastTyping.map {
                $0.column == column && now - $0.time < Self.typingPause
                    && selectionBefore == $0.cursorAfter..<($0.cursorAfter + 1)
            } ?? false
        do {
            try session.overwrite(
                bytes, at: offset, selectionBefore: selectionBefore,
                selectionAfter: cursorAfter..<(cursorAfter + 1), coalescing: continues)
        } catch {
            reportEditError(error, at: offset)
            return false
        }
        lastTyping = Typing(column: column, cursorAfter: cursorAfter, time: now)
        return true
    }

    private func reportEditError(_ error: Error, at offset: UInt64?) {
        switch error {
        case EditorSessionError.readOnly(let reason):
            host?.showStatus("“\(title)” is read-only: \(reason)")
        case EditorSessionError.reloadedBeforeEdit:
            controller.bytesChanged()
            host?.showStatus("“\(title)” changed on disk and was reloaded")
        case EditorSessionError.downloadingBeforeEdit:
            host?.showStatus("“\(title)” is downloading from iCloud. Edit again once it’s here.")
        default:
            let action =
                offset.map { "Can't change the byte at \(Self.hex($0))" } ?? "Can't edit “\(title)”"
            host?.showStatus("\(action): \(error)")
        }
    }

    /// Goes back one undo step; returns the state to show, or nil if there's none.
    func undo() -> UndoStack.State? { session.undo() }

    /// Goes forward one step; returns the state to show, or nil if there's none.
    func redo() -> UndoStack.State? { session.redo() }

    /// The session changed, from this tab or elsewhere (a revert, later another view).
    /// This tab's own keystroke only needs the old find results gone and a redraw; the
    /// hex view then moves the cursor, which refreshes the status line and inspector
    /// once. Anything else also ends the typing burst and drops a half-typed byte.
    func sessionChanged(_ change: EditorSession.Change) {
        guard change == .edited else {  // a save, or the file changing on disk
            updateStatus()
            onChange?()
            if change == .fileChanged { Task { await controller.outsideChange() } }
            return
        }
        let ownTyping = controller.applyingTypingEdit
        if !ownTyping { lastTyping = nil }
        if controller.isViewLoaded {
            if ownTyping {
                controller.clearFindResults()
                hexView.needsDisplay = true
            } else {
                hexView.clearPendingNibble()
                controller.bytesChanged()
            }
        }
        onChange?()
    }
}
