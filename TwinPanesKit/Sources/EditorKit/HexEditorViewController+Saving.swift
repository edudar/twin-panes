import AppKit
import TwinPanesCore

/// File › Save and Revert to Saved for the editor tab (docs/plans/M3b.md, step 8).
extension HexEditorViewController {
    /// Saves the session; a failure is shown as a sheet and in the status line, and the
    /// tab stays modified. Asked for again while a save runs, it queues one more.
    @objc func editorSave(_ sender: Any?) {
        Task { await saveShowingErrors() }
    }

    /// Asks first (`confirmRevert`), then drops every unsaved edit and the undo history.
    @objc func editorRevertToSaved(_ sender: Any?) {
        Task { await revertToSaved() }
    }

    /// Asks, then reverts; for the menu action and its tests.
    func revertToSaved() async {
        guard let item, item.isDirty, await confirmRevert(self, item.title) else { return }
        item.discardChanges()
    }

    /// Saves and reports a failure; for the menu action and its tests.
    func saveShowingErrors() async {
        guard let item else { return }
        do {
            try await item.save()
        } catch {
            let reason = Self.describe(error)
            item.host?.showStatus("Couldn't save “\(item.title)”: \(reason)")
            guard let window = view.window else { return }
            let alert = NSAlert()
            alert.messageText = "Couldn't save “\(item.title)”."
            alert.informativeText = reason + ". Your changes are still here."
            await alert.beginSheetModal(for: window)
        }
    }

    /// The Revert to Saved sheet.
    static func askToRevert(_ controller: HexEditorViewController, _ title: String) async -> Bool {
        guard let window = controller.view.window else { return false }
        let alert = NSAlert()
        alert.messageText = "Revert to the saved version of “\(title)”?"
        alert.informativeText = "Your unsaved changes and their undo history will be lost."
        alert.addButton(withTitle: "Revert").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    /// Our own errors read well as they are; others (Cocoa's) have a localized text.
    static func describe(_ error: Error) -> String {
        switch error {
        case let error as Saver.SaveError: return error.description
        case let error as FileSystemError: return error.description
        case let error as ByteSourceError: return error.description
        case let error as EditorSessionError: return error.description
        default: return error.localizedDescription
        }
    }
}
