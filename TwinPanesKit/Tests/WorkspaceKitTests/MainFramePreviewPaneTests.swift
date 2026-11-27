import AppKit
import Testing
import TwinPanesCore

@testable import WorkspaceKit

@MainActor
private final class StubHexViewer: HexPreviewing {
    let viewController = NSViewController()
    var showsUnsavedEdits = false
    var onStateChange: (() -> Void)?
    init() { viewController.view = NSView() }
    func show(_ url: URL?, scope: SecurityScope?) {}
}

@MainActor
private final class StubHexViewerFactory: HexViewerFactory {
    private(set) var styles: [HexViewerStyle] = []
    func makeHexViewer(style: HexViewerStyle) -> any HexPreviewing {
        styles.append(style)
        return StubHexViewer()
    }
}

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

    @Test func sidebarAndPreviewPaneFitAndHexFactoryContract() throws {
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

        let factory = StubHexViewerFactory()
        let regular = factory.makeHexViewer(style: .regular)
        let compact = factory.makeHexViewer(style: .compact)
        var changes = 0
        compact.onStateChange = { changes += 1 }
        regular.show(URL(fileURLWithPath: "/tmp/sample.bin"), scope: nil)
        compact.show(nil, scope: nil)
        compact.onStateChange?()
        #expect(
            factory.styles == [.regular, .compact] && !regular.showsUnsavedEdits && changes == 1)
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
}
