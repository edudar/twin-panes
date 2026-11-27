import AppKit
import Testing

@testable import WorkspaceKit

/// The main frame hosts an optional trailing preview pane (docs/plans/M7.md, D-d).
@MainActor
@Suite struct MainFramePreviewPaneTests {
    func makeController() -> MainWindowController {
        let layout = MainFrameLayout(filler: .testBrowsers)
        layout.fillEmptyPanels()
        return MainWindowController(
            layout: layout, workspace: WorkspaceRegistry(),
            dispatcher: CommandDispatcher(registry: CommandRegistry()),
            closeCoordinator: CloseCoordinator(openItems: { [] }) { _ in .discard })
    }

    func focusableVC() -> NSViewController {
        let vc = NSViewController()
        vc.view = FocusableView()
        return vc
    }

    @Test func toggleNotificationFocusAndValidation() throws {
        let controller = makeController()
        let frame = controller.frameController
        let window = try #require(controller.window)
        let toolbarItem = NSToolbarItem(itemIdentifier: .togglePreviewPane)
        let menuItem = NSMenuItem(
            title: "", action: #selector(MainFrameViewController.togglePreviewPane(_:)),
            keyEquivalent: "")
        #expect(!frame.isPreviewPaneShown)
        #expect(!frame.validateMenuItem(menuItem) && !frame.validateToolbarItem(toolbarItem))

        var notifications: [Bool] = []
        frame.onPreviewVisibilityChange = { notifications.append($0) }
        let previewVC = focusableVC()
        frame.previewPane = previewVC
        #expect(!frame.isPreviewPaneShown && notifications == [false])
        #expect(frame.validateMenuItem(menuItem) && menuItem.title == "Show Preview")

        frame.togglePreviewPane(nil)
        #expect(frame.isPreviewPaneShown && notifications == [false, true])
        #expect(frame.validateMenuItem(menuItem) && menuItem.title == "Hide Preview")
        #expect(frame.validateToolbarItem(toolbarItem) && toolbarItem.toolTip == "Hide Preview")

        // Focusing inside preview leaves activePanel untouched; collapsing restores focus.
        let panel = frame.layout.activePanel
        window.makeFirstResponder(previewVC.view)
        #expect(frame.layout.activePanel == panel)
        frame.togglePreviewPane(nil)
        #expect(!frame.isPreviewPaneShown && notifications == [false, true, false])
        #expect((window.firstResponder as? NSView)?.isDescendant(of: previewVC.view) != true)
    }

    @Test func saveRestoreClampsWidthAndSplitIgnoresToggleInspector() throws {
        let saved = makeController().frameController
        saved.previewPane = focusableVC()
        saved.togglePreviewPane(nil)
        var state = saved.windowState
        #expect(state.previewShown == true && state.previewWidth == 260)

        state.previewWidth = 999
        let restored = makeController().frameController
        var notifications: [Bool] = []
        restored.onPreviewVisibilityChange = { notifications.append($0) }
        restored.restore(state, using: ItemRestorer())
        let previewVC = focusableVC()
        restored.previewPane = previewVC
        #expect(restored.isPreviewPaneShown && restored.windowState.previewWidth == 480)
        #expect(notifications == [true])

        let splitVC = try #require(restored.children.first as? NSSplitViewController)
        let inspector = #selector(NSSplitViewController.toggleInspector(_:))
        #expect(splitVC.splitViewItems.count == 3 && !restored.responds(to: inspector))
        #expect(!CommandDispatcher.isEnabled(inspector, target: splitVC))

        state.previewShown = false
        state.previewWidth = 80
        restored.restore(state, using: ItemRestorer())
        #expect(!restored.isPreviewPaneShown && restored.windowState.previewWidth == 220)
        #expect(notifications == [true, false])
    }

    @Test func sidebarAndPreviewPaneFitTogether() throws {
        let controller = makeController()
        let frame = controller.frameController
        let window = try #require(controller.window)
        frame.sidebar = focusableVC()
        frame.previewPane = focusableVC()
        window.layoutIfNeeded()
        frame.viewDidAppear()
        frame.togglePreviewPane(nil)
        window.layoutIfNeeded()
        let panes = try #require(frame.children.first as? NSSplitViewController).splitView
            .arrangedSubviews
        #expect(panes.count == 3 && abs(panes[0].frame.width - 180) <= 1)
        #expect(abs(panes[2].frame.width - 260) <= 1 && panes[1].frame.width >= 481)
    }

    @Test func previewTogglePreservesPanelRatioAndHitTestsDropSlots() throws {
        let controller = makeController()
        let frame = controller.frameController
        let window = try #require(controller.window)
        frame.previewPane = focusableVC()
        window.layoutIfNeeded()
        frame.viewDidAppear()

        let innerSplit = try #require(
            frame.children.first?.children[1].view.subviews.first as? NSSplitView)
        let beforeWidth = innerSplit.bounds.width - innerSplit.dividerThickness
        innerSplit.setPosition(round(beforeWidth * 0.35), ofDividerAt: 0)
        window.layoutIfNeeded()
        let beforeRatio = try #require(frame.windowState.dividerFraction)

        frame.togglePreviewPane(nil)
        window.layoutIfNeeded()
        let afterOpenRatio = try #require(frame.windowState.dividerFraction)
        #expect(abs(afterOpenRatio - beforeRatio) < 0.02)

        let leftCenter = innerSplit.arrangedSubviews[0].convert(
            NSPoint(
                x: innerSplit.arrangedSubviews[0].bounds.midX,
                y: innerSplit.arrangedSubviews[0].bounds.midY), to: nil)
        let rightCenter = innerSplit.arrangedSubviews[1].convert(
            NSPoint(
                x: innerSplit.arrangedSubviews[1].bounds.midX,
                y: innerSplit.arrangedSubviews[1].bounds.midY), to: nil)
        let previewCenter = frame.previewPane!.view.convert(
            NSPoint(
                x: frame.previewPane!.view.bounds.midX,
                y: frame.previewPane!.view.bounds.midY), to: nil)
        #expect(frame.panelSlot(at: leftCenter) == .leftPanel)
        #expect(frame.panelSlot(at: rightCenter) == .rightPanel)
        #expect(frame.panelSlot(at: previewCenter) == nil)

        frame.togglePreviewPane(nil)
        window.layoutIfNeeded()
        let afterCloseRatio = try #require(frame.windowState.dividerFraction)
        #expect(abs(afterCloseRatio - beforeRatio) < 0.02)
    }

    @Test func dragCollapsingPreviewUpdatesVisibilityAndRestoresFocus() throws {
        let controller = makeController()
        let frame = controller.frameController
        let window = try #require(controller.window)
        var notifications: [Bool] = []
        frame.onPreviewVisibilityChange = { notifications.append($0) }
        let previewVC = focusableVC()
        frame.previewPane = previewVC
        window.layoutIfNeeded()
        frame.viewDidAppear()
        frame.togglePreviewPane(nil)
        window.layoutIfNeeded()
        window.makeFirstResponder(previewVC.view)
        #expect(frame.isPreviewPaneShown)
        #expect((window.firstResponder as? NSView)?.isDescendant(of: previewVC.view) == true)

        let splitVC = try #require(frame.children.first as? NSSplitViewController)
        splitVC.splitView.setPosition(splitVC.splitView.bounds.width, ofDividerAt: 1)
        window.layoutIfNeeded()

        #expect(!frame.isPreviewPaneShown)
        #expect(notifications == [false, true, false])
        #expect((window.firstResponder as? NSView)?.isDescendant(of: previewVC.view) != true)

        frame.togglePreviewPane(nil)
        #expect(frame.isPreviewPaneShown && notifications == [false, true, false, true])
    }

    @Test func restoreIgnoresNonFinitePreviewWidths() throws {
        let controller = makeController()
        let frame = controller.frameController
        frame.previewPane = focusableVC()
        var state = frame.windowState
        state.previewShown = true
        state.previewWidth = .nan
        frame.restore(state, using: ItemRestorer())
        #expect(frame.isPreviewPaneShown && frame.windowState.previewWidth == 260)

        state.previewWidth = .infinity
        frame.restore(state, using: ItemRestorer())
        #expect(frame.windowState.previewWidth == 260)

        state.previewWidth = 300
        frame.restore(state, using: ItemRestorer())
        #expect(frame.windowState.previewWidth == 300)

        state.previewWidth = -.infinity
        frame.restore(state, using: ItemRestorer())
        #expect(frame.windowState.previewWidth == 300)
    }

    @Test func panelSlotHitTestingExcludesSidebarAndOutsideAndUsesZoomedSlot() throws {
        let controller = makeController()
        let frame = controller.frameController
        let window = try #require(controller.window)
        let sidebarVC = focusableVC()
        let previewVC = focusableVC()
        frame.sidebar = sidebarVC
        frame.previewPane = previewVC
        window.layoutIfNeeded()
        frame.viewDidAppear()
        frame.togglePreviewPane(nil)
        window.layoutIfNeeded()

        func center(of target: NSView) -> NSPoint {
            target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        }
        #expect(frame.panelSlot(at: center(of: sidebarVC.view)) == nil)
        #expect(frame.panelSlot(at: center(of: previewVC.view)) == nil)
        #expect(frame.panelSlot(at: NSPoint(x: -10, y: -10)) == nil)
        #expect(frame.panelSlot(at: NSPoint(x: frame.view.bounds.midX, y: 2)) == nil)

        let rightItem = TestItem("zoomed", slot: .rightPanel)
        frame.layout.insert(rightItem, in: .rightPanel)
        frame.layout.activate(.leftPanel)
        frame.layout.toggleZoom(rightItem.id)
        window.layoutIfNeeded()
        let contentView = try #require(frame.children.first?.children[1].view)
        #expect(frame.layout.activePanel == .leftPanel)
        #expect(frame.panelSlot(at: center(of: contentView)) == .rightPanel)
    }

    @Test func sidePanesDoNotSqueezeContentBelowMinimumWidth() throws {
        let controller = makeController()
        let frame = controller.frameController
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 900, height: 700))
        var state = frame.windowState
        state.sidebarShown = true
        state.sidebarWidth = 400
        state.previewShown = true
        state.previewWidth = 480
        frame.restore(state, using: ItemRestorer())
        frame.sidebar = focusableVC()
        frame.previewPane = focusableVC()
        window.layoutIfNeeded()
        frame.viewDidAppear()
        let panes = try #require(frame.children.first as? NSSplitViewController).splitView
            .arrangedSubviews
        #expect(panes.count == 3 && panes[1].frame.width >= 481)
        #expect(abs(window.contentRect(forFrameRect: window.frame).width - 900) <= 1)

        let narrowController = makeController()
        let narrowFrame = narrowController.frameController
        let narrowWindow = try #require(narrowController.window)
        narrowFrame.previewPane = focusableVC()
        narrowWindow.setContentSize(NSSize(width: 650, height: 700))
        narrowWindow.layoutIfNeeded()
        narrowFrame.viewDidAppear()
        narrowFrame.togglePreviewPane(nil)
        let narrowPanes = try #require(narrowFrame.children.first as? NSSplitViewController)
            .splitView.arrangedSubviews
        #expect(narrowPanes[1].frame.width >= 481)
    }
}
