import AppKit
import BrowserKit
import WorkspaceKit

extension SmokeTest {
    /// The sidebar in the real window (docs/plans/M5.md, D-d): shown, toggled with ⌃⌘S,
    /// and a chosen row opens in the active panel, whose folder it highlights.
    func sidebar(_ check: (Bool, String) -> Void, in controller: MainWindowController) async {
        let frame = controller.frameController
        guard let window = controller.window, let content = window.contentView,
            let outline = Self.view(in: content, id: "sidebar") as? NSOutlineView,
            let browser = controller.layout.focusedPanelItem as? BrowserItem
        else { return check(false, "the window shows the sidebar beside a browser") }
        let width = outline.enclosingScrollView?.frame.width ?? 0
        check(
            frame.isSidebarShown && abs(width - 180) < 2,
            "the sidebar is shown, \(Int(width)) pt wide")
        let toggle = KeyChord("s", [.control, .command])
        check(dispatch(toggle, in: window) && !frame.isSidebarShown, "⌃⌘S hides the sidebar")
        check(dispatch(toggle, in: window) && frame.isSidebarShown, "and shows it again")

        let title = { (row: Int) in
            (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?
                .textField?.stringValue
        }
        guard let row = (0..<outline.numberOfRows).first(where: { title($0) == "Applications" })
        else {
            return check(false, "the sidebar lists Applications")
        }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        await browser.listed()
        check(
            browser.folder.path == "/Applications",
            "choosing a favorite opens it in the active panel")
        check(outline.selectedRow == row, "and the sidebar highlights it")
        browser.go(to: FileManager.default.temporaryDirectory)
        await browser.listed()
        check(outline.selectedRow == -1, "a folder the sidebar doesn't list clears the highlight")
    }
}
