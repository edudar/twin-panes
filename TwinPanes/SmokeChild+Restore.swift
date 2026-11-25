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
    var stateFile: URL { folder.appendingPathComponent("window.state") }

    /// Sets up a window the way someone would leave it, and saves its state.
    func saveWindow(app: AppDelegate) async throws {
        let controller = app.openMainWindow()
        let layout = controller.layout
        guard let window = controller.window,
            let left = layout.selectedItem(in: .leftPanel) as? BrowserItem,
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
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        controller.frameController.toggleSidebarShown(nil)
        if let panelSplit = Self.panelSplitView(
            in: controller.frameController.view, delegate: controller.frameController)
        {
            panelSplit.setPosition(240, ofDividerAt: 0)
        }
        window.layoutIfNeeded()
        editor.hexView.select(100..<120)
        editor.hexView.scroll(toTopRow: 5)
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        controller.window(window, willEncodeRestorableState: archiver)
        archiver.finishEncoding()
        try archiver.encodedData.write(to: stateFile)
    }

    /// Restores a window from the saved state through `MainWindowRestoration` and reports
    /// what it shows.
    func loadWindow(app: AppDelegate) async throws -> ShownWindow {
        let data = try Data(contentsOf: stateFile)
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        var restoredWindow: NSWindow?
        var restoreError: (any Error)?
        MainWindowRestoration.restoreWindow(
            withIdentifier: MainWindowRestoration.identifier, state: unarchiver
        ) { window, error in
            restoredWindow = window
            restoreError = error
        }
        if let restoreError { throw restoreError }
        guard let restoredWindow,
            let controller = app.windowControllers.first(where: { $0.window === restoredWindow })
        else { throw SmokeChildError.missing("a restored window") }
        controller.showWindow(nil)
        restoredWindow.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        let layout = controller.layout
        for case let browser as BrowserItem in layout.allItems { await browser.listed() }
        guard let left = layout.selectedItem(in: .leftPanel) as? BrowserItem else {
            throw SmokeChildError.missing("a browser selected in the left panel")
        }
        let editor = layout.items(in: .rightPanel).lazy.compactMap { $0 as? HexEditorItem }.first
        let selection = editor?.hexView.selection.range
        let state = controller.frameController.windowState
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
            editorIsDirty: editor?.isDirty,
            dividerFraction: state.dividerFraction,
            sidebarShown: state.sidebarShown,
            sidebarWidth: state.sidebarWidth,
            editorTopRow: editor?.hexView.topRow)
    }

    private static func panelSplitView(in root: NSView, delegate: AnyObject) -> NSSplitView? {
        if let split = root as? NSSplitView, split.delegate === delegate { return split }
        for child in root.subviews {
            if let found = panelSplitView(in: child, delegate: delegate) { return found }
        }
        return nil
    }
}
