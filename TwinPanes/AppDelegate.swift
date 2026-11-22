import AppKit
import BrowserKit
import EditorKit
import TwinPanesCore
import WorkspaceKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let registry = DefaultCommands.makeRegistry()
    lazy var dispatcher = CommandDispatcher(registry: registry)
    lazy var menuUpdater = MenuBindingUpdater(registry: registry)
    let workspace = WorkspaceRegistry()
    lazy var closeCoordinator = CloseCoordinator(
        openItems: { [workspace] in workspace.allItems },
        prompt: { [weak self] session in await self?.askToSave(session) ?? .cancel })
    lazy var spike = SandboxSpike(app: self)
    let recentFiles = RecentFiles()

    private(set) var windowControllers: [MainWindowController] = []
    private var editorCount = 0
    let folderGrants = FolderGrants()

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(updater: menuUpdater, recentFiles: recentFiles)
        if CommandLine.arguments.contains("--smoke-test") {
            SmokeTest(app: self, includeBenchmarks: CommandLine.arguments.contains("--bench")).run()
            return
        }
        if CommandLine.arguments.contains("--bench") {
            SmokeTest(app: self, includeBenchmarks: true).run()
            return
        }
        // Files from Finder's Open With may already have opened a window.
        if windowControllers.isEmpty { openMainWindow() }
        NSApp.activate()
    }

    /// Finder "Open With", dropping files on the Dock icon, `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openFile(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    )
        -> Bool
    {
        if !hasVisibleWindows { openMainWindow() }
        return true
    }

    /// Quitting runs the same close workflow as closing a tab or window: one sheet per
    /// dirty session, then quit (PLAN.md §4).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let items = workspace.allItems
        if closeCoordinator.dirtySessions(closing: items).isEmpty { return .terminateNow }
        Task {
            let approved = await closeCoordinator.confirmClose(items)
            NSApp.reply(toApplicationShouldTerminate: approved)
        }
        return .terminateLater
    }

    // MARK: Windows and items

    @discardableResult
    func openMainWindow() -> MainWindowController {
        let layout = MainFrameLayout()
        let controller = MainWindowController(
            layout: layout, workspace: workspace, dispatcher: dispatcher,
            closeCoordinator: closeCoordinator)
        controller.onClose = { [weak self] closed in
            self?.windowControllers.removeAll { $0 === closed }
        }
        windowControllers.append(controller)
        if let mainWindow = controller.window as? MainWindow {
            mainWindow.onDropFiles = { [weak self, weak controller] urls in
                guard let self, let controller else { return }
                self.openDropped(urls, in: controller)
            }
            mainWindow.onFocusChange = { [weak self] window in
                if let menu = NSApp.mainMenu { self?.menuUpdater.refresh(menu, for: window) }
            }
        }
        layout.insert(makeBrowser())
        if let frame = NSApp.keyWindow?.frame {
            controller.window?.setFrameTopLeftPoint(
                NSPoint(x: frame.minX + 24, y: frame.maxY - 24))
        } else {
            controller.window?.center()
        }
        controller.showWindow(nil)
        return controller
    }

    /// A browser tab at `folder`, or the active browser's folder, or the real home.
    func makeBrowser(at folder: URL? = nil) -> BrowserItem {
        let current = activeController?.layout.focusedPanelItem as? BrowserItem
        return BrowserItem(
            folder: folder ?? current?.folder ?? DirectoryReader.realHomeDirectory,
            grants: folderGrants
        ) { [weak self] url, scope in
            self?.openFile(url, scope: scope)
        }
    }

    func makeEditorSession() -> PlaceholderEditorSession {
        editorCount += 1
        return PlaceholderEditorSession(name: "Untitled \(editorCount)")
    }

    /// The main window that menu commands act on.
    var activeController: MainWindowController? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        return windowControllers.first { $0.window === window } ?? windowControllers.first
    }

    func controller(containing id: ItemID) -> MainWindowController? {
        windowControllers.first { $0.layout.item(id) != nil }
    }

    /// Adds an item to `target` (or the active window, opening one if needed).
    func show(_ item: any WorkspaceItem, in target: MainWindowController? = nil) {
        let controller = target ?? activeController ?? openMainWindow()
        controller.layout.insert(item)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Commands

    @objc func newMainWindow(_ sender: Any?) { openMainWindow() }

    // MARK: Opening files

    /// Handles items dropped onto `controller`: folders open in a browser tab (and save
    /// their grant); regular files open in a hex editor tab.
    func openDropped(_ urls: [URL], in controller: MainWindowController) {
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true, values?.isPackage != true {
                try? folderGrants.add(url)
                show(makeBrowser(at: url), in: controller)
            } else {
                openFile(url, in: controller)
            }
        }
    }

    /// Opens `url` as a hex editor tab in `target` (or the active window). `scope` keeps
    /// sandbox access when the URL came from a bookmark; panel, drop and Finder URLs carry
    /// their own access for this run.
    @discardableResult
    func openFile(
        _ url: URL, scope: SecurityScope? = nil, in target: MainWindowController? = nil
    ) -> HexEditorItem? {
        do {
            let item = try HexEditorItem(url: url, scope: scope)
            show(item, in: target)
            recentFiles.note(url)
            return item
        } catch {
            presentOpenError(error, url: url, in: target)
            return nil
        }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openFile(url) }
    }

    @objc func openRecentFile(_ sender: Any?) {
        guard let data = (sender as? NSMenuItem)?.representedObject as? Data else { return }
        if let (url, scope) = recentFiles.open(data) {
            openFile(url, scope: scope)
        } else {
            NSSound.beep()
        }
    }

    @objc func clearRecentFiles(_ sender: Any?) {
        recentFiles.clear()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    private func presentOpenError(
        _ error: Error, url: URL, in target: MainWindowController? = nil
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(url.lastPathComponent)” can’t be opened"
        alert.informativeText =
            (error as? ByteSourceError)?.description
            ?? error.localizedDescription
        if let window = (target ?? activeController)?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc func newBrowserTab(_ sender: Any?) { show(makeBrowser()) }

    @objc func newEditorTab(_ sender: Any?) { show(makeEditorSession().makeView()) }

    @objc func newEditorView(_ sender: Any?) {
        guard let editor = activeController?.layout.focusedPanelItem as? PlaceholderEditorItem
        else { return }
        show(editor.session.makeView())
    }

    @objc func showTestSheet(_ sender: Any?) {
        guard let window = activeController?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Test sheet"
        alert.informativeText =
            "While a sheet is up the command registry intercepts nothing: F3 and Tab behave "
            + "as the sheet's controls expect."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.placeholderString = "Type here; Tab moves between controls"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window)
    }

    @objc func probeFile(_ sender: Any?) { spike.probeFile() }
    @objc func probeFolder(_ sender: Any?) { spike.probeFolder() }
    @objc func resolveSavedBookmarks(_ sender: Any?) { spike.resolveSavedBookmarks() }
    @objc func showSpikeReport(_ sender: Any?) { spike.showReport() }
    @objc func exportSpikeReport(_ sender: Any?) { spike.exportReport() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newEditorView(_:)):
            return activeController?.layout.focusedPanelItem is PlaceholderEditorItem
        default:
            return true
        }
    }

    // MARK: Close prompt

    private func askToSave(_ session: DirtySession) async -> CloseDecision {
        let alert = NSAlert()
        let title = session.representative.title
        let canSave = session.representative.canSave
        if canSave {
            alert.messageText = "Do you want to save the changes made to “\(title)”?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save")
        } else {
            alert.messageText = "Discard the changes made to “\(title)”?"
            alert.informativeText =
                "This version of Twin Panes can’t save edits yet, so closing discards them."
        }
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: canSave ? "Don’t Save" : "Discard Changes")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command

        let response: NSApplication.ModalResponse
        if let window = controller(containing: session.representative.id)?.window {
            if let controller = controller(containing: session.representative.id) {
                controller.layout.select(session.representative.id)
            }
            window.makeKeyAndOrderFront(nil)
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        switch (response, canSave) {
        case (.alertFirstButtonReturn, true): return .save
        case (.alertThirdButtonReturn, true), (.alertSecondButtonReturn, false): return .discard
        default: return .cancel
        }
    }
}
