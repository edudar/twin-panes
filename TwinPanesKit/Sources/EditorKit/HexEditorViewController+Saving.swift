import AppKit
import TwinPanesCore

/// File › Save and Revert to Saved for the editor tab (docs/plans/M3b.md, step 8).
extension HexEditorViewController {
    /// Saves the session; a failure is shown as a sheet and in the status line, and the
    /// tab stays modified. Asked for again while a save runs, it queues one more.
    @objc func editorSave(_ sender: Any?) {
        Task { await saveShowingErrors() }
    }

    /// Asks where in a save panel, then saves there and keeps editing the new file.
    @objc func editorSaveAs(_ sender: Any?) {
        guard let item, let window = view.window else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.title
        panel.directoryURL = item.url.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self?.saveAsShowingErrors(to: url) }
        }
    }

    /// Saves as `url` and reports a failure; for the panel and its tests. The panel's URL
    /// carries sandbox access for this run; the scope token keeps it while the tab lives.
    func saveAsShowingErrors(to url: URL) async {
        guard let item else { return }
        do {
            try await item.saveAs(to: url, scope: SecurityScope(url: url))
        } catch {
            await report(error, saving: url.lastPathComponent)
        }
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
            await report(error, saving: item.title)
        }
    }

    /// A failed save: the reason in the status line and in a sheet.
    private func report(_ error: Error, saving name: String) async {
        let reason = Self.describe(error)
        item?.host?.showStatus("Couldn't save “\(name)”: \(reason)")
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't save “\(name)”."
        alert.informativeText = reason + ". Your changes are still here."
        await alert.beginSheetModal(for: window)
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
