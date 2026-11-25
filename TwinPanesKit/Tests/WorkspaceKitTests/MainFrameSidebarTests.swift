import AppKit
import Testing

@testable import WorkspaceKit

/// The main frame hosts the app's sidebar beside the panels (docs/plans/M5.md, D-d).
@MainActor
@Suite struct MainFrameSidebarTests {
    let layout = MainFrameLayout(filler: .testBrowsers)
    let content = NSViewController()

    init() {
        content.view = NSView()
    }

    func controller() -> MainWindowController {
        layout.fillEmptyPanels()
        return MainWindowController(
            layout: layout, workspace: WorkspaceRegistry(),
            dispatcher: CommandDispatcher(registry: CommandRegistry()),
            closeCoordinator: CloseCoordinator(openItems: { [] }) { _ in .discard })
    }

    func toggleItem(of frame: MainFrameViewController) -> NSMenuItem {
        let item = NSMenuItem(
            title: "", action: #selector(MainFrameViewController.toggleSidebarShown(_:)),
            keyEquivalent: "")
        item.isEnabled = frame.validateMenuItem(item)
        return item
    }

    @Test func aSidebarIsShownInTheWindow() {
        let frame = controller().frameController
        frame.sidebar = content
        #expect(content.view.window != nil && frame.isSidebarShown)
    }

    @Test func togglingHidesAndShowsTheSidebar() {
        let frame = controller().frameController
        frame.sidebar = content
        frame.toggleSidebarShown(nil)
        #expect(!frame.isSidebarShown && toggleItem(of: frame).title == "Show Sidebar")
        frame.toggleSidebarShown(nil)
        #expect(frame.isSidebarShown && toggleItem(of: frame).title == "Hide Sidebar")
    }

    @Test func withoutASidebarTheToggleIsDisabled() {
        let frame = controller().frameController
        #expect(!frame.isSidebarShown && !toggleItem(of: frame).isEnabled)
    }

    @Test func aHiddenSidebarIsSavedAndRestoredHidden() {
        let frame = controller().frameController
        frame.sidebar = content
        frame.toggleSidebarShown(nil)
        let state = frame.windowState
        #expect(state.sidebarShown == false)
        let restored = MainWindowController(
            layout: MainFrameLayout(filler: .testBrowsers), workspace: WorkspaceRegistry(),
            dispatcher: CommandDispatcher(registry: CommandRegistry()),
            closeCoordinator: CloseCoordinator(openItems: { [] }) { _ in .discard }
        ).frameController
        let other = NSViewController()
        other.view = NSView()
        restored.sidebar = other
        restored.restore(state, using: ItemRestorer())
        #expect(!restored.isSidebarShown)
    }

    @Test func layoutChangesAreReported() {
        let frame = controller().frameController
        var updates = 0
        frame.onUpdate = { updates += 1 }
        layout.insert(TestItem("a"))
        #expect(updates >= 1)
    }

    @Test func toolbarToggleReflectsSidebarAvailabilityAndTogglesSidebar() {
        let windowController = controller()
        let frame = windowController.frameController
        let item = NSToolbarItem(itemIdentifier: .toggleSidebar)
        item.action = #selector(MainFrameViewController.toggleSidebarShown(_:))
        #expect(!frame.validateToolbarItem(item))

        frame.sidebar = content
        #expect(frame.validateToolbarItem(item))
        #expect(frame.isSidebarShown)

        frame.toggleSidebarShown(item)
        #expect(!frame.isSidebarShown)
        frame.toggleSidebarShown(item)
        #expect(frame.isSidebarShown)
    }
}
