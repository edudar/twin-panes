import AppKit
import TwinPanesCore

/// Where a typed destination points: `~` is the real home folder, and a path that
/// doesn't start with "/" is relative to `folder` (docs/plans/M6.md, D-f).
enum DestinationPath {
    static func resolve(_ text: String, from folder: URL, home: URL) -> URL? {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path == "~" || path.hasPrefix("~/") { path = home.path + path.dropFirst() }
        let url =
            path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : URL(fileURLWithPath: path, isDirectory: true, relativeTo: folder)
        return url.standardizedFileURL
    }
}

/// A sheet asking for one line of text: F5 and F6's destination, F2's new name, F7's
/// folder name (docs/plans/M6.md, D-f). Return confirms, Escape cancels.
@MainActor
final class TextSheet {
    /// What's selected in the field when the sheet opens.
    enum Selection {
        case all
        /// Finder's rename: the name without its extension.
        case nameWithoutExtension
    }

    let alert = NSAlert()
    let field = NSTextField()
    private let selecting: Selection
    private var completion: ((String?) -> Void)?

    init(message: String, text: String, selecting: Selection, confirm: String) {
        self.selecting = selecting
        alert.messageText = message
        field.stringValue = text
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 22)
        field.setAccessibilityIdentifier("operationSheetField")
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
    }

    /// Shows the sheet on `window`; `completion` gets the text, or nil when cancelled.
    func begin(on window: NSWindow, completion: @escaping (String?) -> Void) {
        self.completion = completion
        alert.beginSheetModal(for: window) { [self] response in
            self.completion?(response == .alertFirstButtonReturn ? field.stringValue : nil)
            self.completion = nil
        }
        alert.window.initialFirstResponder = field
        alert.window.makeFirstResponder(field)
        selectText()
    }

    /// Shows `message` under the field and keeps the sheet open: a destination that
    /// isn't a folder, a name that's taken.
    func refuse(_ message: String) {
        alert.informativeText = message
        alert.layout()
        alert.window.makeFirstResponder(field)
        selectText()
    }

    private func selectText() {
        guard let editor = field.currentEditor() else { return }
        let name = field.stringValue as NSString
        switch selecting {
        case .all:
            editor.selectedRange = NSRange(location: 0, length: name.length)
        case .nameWithoutExtension:
            // A leading dot is part of the name (".profile"), not an extension.
            let stem = name.deletingPathExtension as NSString
            let length = stem.length == 0 ? name.length : stem.length
            editor.selectedRange = NSRange(location: 0, length: length)
        }
    }
}

/// ⇧F8's confirmation: Delete is destructive and needs ⌘D, Escape cancels, and Return
/// does nothing, as the app's other destructive sheets (HIG).
@MainActor
enum DeleteConfirmation {
    static func makeAlert(for items: [URL]) -> NSAlert {
        let alert = NSAlert()
        let what = items.count == 1 ? "“\(items[0].lastPathComponent)”" : "\(items.count) items"
        alert.messageText = "Delete \(what) permanently?"
        alert.informativeText = "This can't be undone."
        alert.alertStyle = .warning
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        delete.keyEquivalent = "d"
        delete.keyEquivalentModifierMask = .command
        cancel.keyEquivalent = "\u{1b}"
        return alert
    }
}
