import AppKit
import BrowserKit
import EditorKit
import TwinPanesCore
import WorkspaceKit

enum SmokeChildError: Error {
    case unknownStep(String)
    case missing(String)
}

/// The restore relaunch's two launches (docs/plans/M5.md, D-f, 1). The window's state
/// goes through a file in the test folder, never AppKit's saved state, so the checks
/// leave the user's saved windows alone (D-c).
extension SmokeChild {
    var stateFile: URL { folder.appendingPathComponent("window.json") }

    /// Sets up a window the way someone would leave it, and saves its state.
    func saveWindow(app: AppDelegate) async throws {
        let controller = app.openMainWindow()
        let layout = controller.layout
        guard let left = layout.selectedItem(in: .leftPanel) as? BrowserItem,
            let right = layout.selectedItem(in: .rightPanel) as? BrowserItem
        else { throw SmokeChildError.missing("a browser in each panel") }
        for path in ["", "a", "a/inner"] {
            left.go(to: folder.appendingPathComponent(path))
            await left.listed()
        }
        left.goBack()
        await left.listed()
        left.sort(by: ListingOrder(column: .size, ascending: false))
        left.showHidden(true)
        await left.listed()
        right.go(to: folder.appendingPathComponent("b"))
        await right.listed()
        guard let editor = app.openFile(folder.appendingPathComponent("data.bin"), in: controller)
        else { throw SmokeChildError.missing("an editor on data.bin") }
        layout.move(editor.id, to: .rightPanel)
        let eightPerRow = NSMenuItem()
        eightPerRow.representedObject = 8
        NSApp.sendAction(
            #selector(HexEditorActions.setBytesPerRow(_:)), to: editor.viewController,
            from: eightPerRow)
        editor.hexView.select(100..<120)
        try controller.frameController.windowState.encoded().write(to: stateFile)
    }

    /// Restores a window from the saved state, as AppKit would, and reports what it shows.
    func loadWindow(app: AppDelegate) async throws -> ShownWindow {
        let state = try WindowState(decoding: Data(contentsOf: stateFile))
        let layout = app.openMainWindow(restoring: state).layout
        for case let browser as BrowserItem in layout.allItems { await browser.listed() }
        guard let left = layout.selectedItem(in: .leftPanel) as? BrowserItem else {
            throw SmokeChildError.missing("a browser selected in the left panel")
        }
        let editor = layout.items(in: .rightPanel).lazy.compactMap { $0 as? HexEditorItem }.first
        let selection = editor?.hexView.selection.range
        return ShownWindow(
            leftTabs: layout.items(in: .leftPanel).map(\.title),
            rightTabs: layout.items(in: .rightPanel).map(\.title),
            activePanel: layout.activePanel.rawValue,
            leftFolder: left.folder.resolvingSymlinksInPath().path,
            leftSelection: left.selectedName,
            leftCanGoBack: left.canGoBack, leftCanGoForward: left.canGoForward,
            leftSort: "\(left.order.column.rawValue) \(left.order.ascending ? "up" : "down")",
            leftShowsHidden: left.showsHidden,
            editorFile: editor?.url.lastPathComponent,
            editorSelection: selection.map { [$0.lowerBound, $0.upperBound] },
            editorBytesPerRow: editor.map { String(describing: $0.hexView.options.bytesPerRow) },
            editorIsDirty: editor?.isDirty)
    }
}
