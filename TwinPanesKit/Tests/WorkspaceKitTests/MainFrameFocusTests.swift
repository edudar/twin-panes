import AppKit
import Testing

@testable import WorkspaceKit

/// The active panel follows keyboard focus (docs/plans/M5.md, D-b).
@MainActor
@Suite struct MainFrameFocusTests {
    let layout = MainFrameLayout(filler: .testBrowsers)
    let left = TestItem("left")
    let right = TestItem("right", slot: .rightPanel)

    func window() -> NSWindow {
        layout.insert(left)
        layout.insert(right)
        layout.activate(.leftPanel)
        let controller = MainWindowController(
            layout: layout, workspace: WorkspaceRegistry(),
            dispatcher: CommandDispatcher(registry: CommandRegistry()),
            closeCoordinator: CloseCoordinator(openItems: { [] }) { _ in .discard })
        return controller.window!
    }

    func tabs(of panel: SlotID, in window: NSWindow) -> [TabItemView] {
        func find(_ view: NSView) -> [TabItemView] {
            if let tab = view as? TabItemView { return [tab] }
            return view.subviews.flatMap(find)
        }
        return window.contentView.flatMap { Self.view(in: $0, id: panel.rawValue) }.map(find) ?? []
    }

    static func view(in root: NSView, id: String) -> NSView? {
        if root.accessibilityIdentifier() == id { return root }
        return root.subviews.lazy.compactMap { view(in: $0, id: id) }.first
    }

    @Test func focusInTheOtherPanelActivatesIt() {
        let window = window()
        window.makeFirstResponder(right.viewController.view)
        #expect(layout.activePanel == .rightPanel)
    }

    @Test func focusBackInTheFirstPanelActivatesIt() {
        let window = window()
        window.makeFirstResponder(right.viewController.view)
        window.makeFirstResponder(left.viewController.view)
        #expect(layout.activePanel == .leftPanel)
    }

    @Test func focusOnTheWindowLeavesTheActivePanel() {
        let window = window()
        window.makeFirstResponder(right.viewController.view)
        window.makeFirstResponder(nil)
        #expect(layout.activePanel == .rightPanel)
    }

    @Test func theFocusedPanelsTabBarIsDrawnActive() {
        let window = window()
        window.makeFirstResponder(right.viewController.view)
        #expect(tabs(of: .rightPanel, in: window).map(\.isActivePanel) == [true])
        #expect(tabs(of: .leftPanel, in: window).map(\.isActivePanel) == [false])
    }

    @Test func focusInInactivePanelSubviewActivatesWithoutStealingFocus() {
        let window = window()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        right.viewController.view.addSubview(field)
        window.makeFirstResponder(field)
        #expect(layout.activePanel == .rightPanel)
        #expect((window.firstResponder as? NSView)?.isDescendant(of: field) == true)
    }
}
