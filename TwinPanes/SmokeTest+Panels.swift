import AppKit
import BrowserKit
import WorkspaceKit

extension SmokeTest {
    /// Two panels, always (docs/plans/M5.md, D-a): a new window shows a browser in each
    /// panel, a panel's only browser can't be closed, and closing a panel's last other tab
    /// leaves a browser at the other panel's folder.
    func twoPanels(_ check: (Bool, String) -> Void, in controller: MainWindowController) async {
        let layout = controller.layout
        guard let window = controller.window, let content = window.contentView,
            let left = layout.selectedItem(in: .leftPanel) as? BrowserItem,
            let right = layout.selectedItem(in: .rightPanel) as? BrowserItem
        else {
            check(false, "a new window shows a browser in each panel")
            return
        }
        check(right.folder == left.folder, "the right panel starts in the left panel's folder")
        let widths = [SlotID.leftPanel, .rightPanel].map { slot in
            Self.view(in: content, id: slot.rawValue).map { $0.isHidden ? 0 : $0.frame.width } ?? 0
        }
        check(
            widths[0] >= 240 && abs(widths[0] - widths[1]) <= 1,
            "both panels are shown as equal halves: \(widths.map { Int($0) }) pt")

        window.makeFirstResponder(left.preferredFirstResponder)
        check(
            !dispatch(KeyChord("w", .command), in: window),
            "⌘W is disabled on a panel's only browser")
        check(layout.items(in: .leftPanel).map(\.id) == [left.id], "the panel's only browser stays")

        layout.insert(app.makeEditorSession().makeView(), in: .rightPanel)
        controller.frameController.closeItem(right.id)
        await settle()
        check(
            layout.items(in: .rightPanel).map(\.kind) == [.editor],
            "a panel's browser closes while the panel has another tab")
        check(dispatch(KeyChord("w", .command), in: window), "⌘W closes a panel's last editor")
        await settle()
        let replacement = layout.items(in: .rightPanel).first as? BrowserItem
        check(
            layout.items(in: .rightPanel).count == 1 && replacement?.folder == left.folder,
            "closing a panel's last editor leaves a browser at the other panel's folder")
    }
}
