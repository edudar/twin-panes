import AppKit
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

    private(set) var windowControllers: [MainWindowController] = []
    private var editorCount = 0
    private var browserCount = 0

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(updater: menuUpdater)
        if CommandLine.arguments.contains("--smoke-test") {
            SmokeTest(app: self).run()
            return
        }
        openMainWindow()
        NSApp.activate()
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

    func makeBrowser() -> PlaceholderBrowserItem {
        browserCount += 1
        return PlaceholderBrowserItem(title: "Browser \(browserCount)")
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

    /// Adds an item to the active window, opening one if needed.
    func show(_ item: any WorkspaceItem) {
        let controller = activeController ?? openMainWindow()
        controller.layout.insert(item)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Commands

    @objc func newMainWindow(_ sender: Any?) { openMainWindow() }

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
        alert.messageText =
            "Do you want to save the changes made to “\(session.representative.title)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don’t Save")
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
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }
}
