import AppKit
import TwinPanesCore

/// The path bar (docs/plans/M4.md, D-h): a path control whose folders can be clicked,
/// and the editable path field in its place while the user types a path. ⇧⌘G or a click
/// on the bar's empty part edits; Return goes there, Escape or leaving the field doesn't.
extension BrowserViewController: NSTextFieldDelegate {
    func configurePathBar() {
        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathControl.target = self
        pathControl.action = #selector(pathBarClicked(_:))
        pathControl.setAccessibilityIdentifier("browserPathBar")
        pathField.isHidden = true
    }

    var isEditingPath: Bool { !pathField.isHidden }

    /// The folders of `folder`'s path as the bar's items, each with the cached folder
    /// icon: setting the control's `url` looks up every folder's own icon, 50-90 ms per
    /// navigation on a busy system.
    func showPath(_ folder: URL) {
        let parts = folder.standardizedFileURL.pathComponents
        pathURLs = parts.indices.map { i in
            URL(
                fileURLWithPath: NSString.path(withComponents: Array(parts[...i])),
                isDirectory: true)
        }
        pathControl.pathItems = pathURLs.map { url in
            let item = NSPathControlItem()
            item.title = url.path == "/" ? "/" : url.lastPathComponent
            item.image = IconCache.shared.folder
            return item
        }
    }

    @objc func pathBarClicked(_ sender: NSPathControl) {
        if let clicked = sender.clickedPathItem,
            let index = sender.pathItems.firstIndex(of: clicked), pathURLs.indices.contains(index)
        {
            goToPathComponent(pathURLs[index])
        } else {
            editPath()
        }
    }

    /// A folder of the path was clicked: go there, selecting the folder you were in
    /// (or the one leading to it).
    func goToPathComponent(_ url: URL) {
        guard let item else { return }
        let here = item.folder.standardizedFileURL.pathComponents
        let there = url.standardizedFileURL.pathComponents
        let selecting = here.count > there.count ? here[there.count] : nil
        item.go(to: url, selecting: selecting)
        view.window?.makeFirstResponder(tableView)
    }

    /// Swaps the field in, with the whole path selected.
    func editPath() {
        guard let item else { return }
        pathField.stringValue = item.folder.path
        pathField.isHidden = false
        pathControl.isHidden = true
        view.window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    func showPathBar() {
        pathField.isHidden = true
        pathControl.isHidden = false
    }

    func controlTextDidEndEditing(_ notification: Notification) { showPathBar() }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        guard selector == #selector(cancelOperation(_:)) else { return false }
        view.window?.makeFirstResponder(tableView)
        showPathBar()
        return true
    }
}
