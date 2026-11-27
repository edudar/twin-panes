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
        let windowController = controller()
        let frame = windowController.frameController
        frame.sidebar = content
        frame.toggleSidebarShown(nil)
        let state = frame.windowState
        #expect(state.sidebarShown == false && state.sidebarWidth == 180)
        let restoredController = MainWindowController(
            layout: MainFrameLayout(filler: .testBrowsers), workspace: WorkspaceRegistry(),
            dispatcher: CommandDispatcher(registry: CommandRegistry()),
            closeCoordinator: CloseCoordinator(openItems: { [] }) { _ in .discard })
        let restored = restoredController.frameController
        let other = NSViewController()
        other.view = NSView()
        restored.sidebar = other
        restored.restore(state, using: ItemRestorer())
        #expect(!restored.isSidebarShown)
        _ = (windowController, restoredController)
    }

    @Test func restoreBeforeSidebarAssignmentRespectsHiddenState() {
        let windowController = controller()
        let frame = windowController.frameController
        var state = frame.windowState
        state.sidebarShown = false
        frame.restore(state, using: ItemRestorer())
        frame.sidebar = content
        #expect(!frame.isSidebarShown)
        _ = windowController
    }

    @Test func layoutChangesAreReported() {
        let windowController = controller()
        let frame = windowController.frameController
        var updates = 0
        frame.onUpdate = { updates += 1 }
        layout.insert(TestItem("a"))
        #expect(updates >= 1)
        _ = windowController
    }

    @Test func toolbarToggleReflectsSidebarAvailabilityAndTogglesSidebar() throws {
        let windowController = controller()
        let frame = windowController.frameController
        let item = try #require(
            windowController.window?.toolbar?.items.first { $0.itemIdentifier == .toggleSidebar })
        #expect(item.isBordered)
        #expect(!frame.validateToolbarItem(item))

        frame.sidebar = content
        #expect(frame.validateToolbarItem(item))
        #expect(frame.isSidebarShown)

        frame.toggleSidebarShown(item)
        #expect(!frame.isSidebarShown)
        frame.toggleSidebarShown(item)
        #expect(frame.isSidebarShown)
        _ = windowController
    }

    @Test func dragCollapsingSidebarUpdatesStateAndRestoresFocus() throws {
        final class FocusableView: NSView {
            override var acceptsFirstResponder: Bool { true }
        }
        let windowController = controller()
        let frame = windowController.frameController
        let window = try #require(windowController.window)
        let sidebarVC = NSViewController()
        sidebarVC.view = FocusableView()
        frame.sidebar = sidebarVC
        window.layoutIfNeeded()
        frame.viewDidAppear()
        window.makeFirstResponder(sidebarVC.view)
        #expect(frame.isSidebarShown)
        #expect((window.firstResponder as? NSView)?.isDescendant(of: sidebarVC.view) == true)

        let splitVC = try #require(frame.children.first as? NSSplitViewController)
        splitVC.splitView.setPosition(0, ofDividerAt: 0)
        window.layoutIfNeeded()

        #expect(!frame.isSidebarShown)
        #expect((window.firstResponder as? NSView)?.isDescendant(of: sidebarVC.view) != true)

        let replacement = NSViewController()
        replacement.view = FocusableView()
        frame.sidebar = replacement
        #expect(!frame.isSidebarShown)
    }
}
