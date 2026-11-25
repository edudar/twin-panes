import AppKit
import Testing

@testable import WorkspaceKit

/// Switching panels and moving a tab to the other panel (docs/plans/M5.md, D-b).
@MainActor
@Suite struct MainFramePanelCommandTests {
    let layout = MainFrameLayout(filler: .testBrowsers)
    let left = TestItem("left")
    let right = TestItem("right", slot: .rightPanel)

    func controller() -> MainWindowController {
        layout.insert(left)
        layout.insert(right)
        layout.activate(.leftPanel)
        return MainWindowController(
            layout: layout, workspace: WorkspaceRegistry(),
            dispatcher: CommandDispatcher(registry: CommandRegistry()),
            closeCoordinator: CloseCoordinator(openItems: { [] }) { _ in .discard })
    }

    func isEnabled(_ action: Selector, in controller: MainWindowController) -> Bool {
        controller.frameController.validateMenuItem(
            NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }

    @Test func switchingFocusesTheOtherPanelsTab() {
        let controller = controller()
        controller.frameController.switchPanel(nil)
        #expect(layout.activePanel == .rightPanel)
        #expect(controller.window?.firstResponder === right.viewController.view)
    }

    @Test func switchingTwiceComesBack() {
        let controller = controller()
        controller.frameController.switchPanel(nil)
        controller.frameController.switchPanel(nil)
        #expect(layout.activePanel == .leftPanel)
        #expect(controller.window?.firstResponder === left.viewController.view)
    }

    @Test func switchingIsDisabledWhileZoomed() {
        let controller = controller()
        #expect(isEnabled(#selector(MainFrameViewController.switchPanel(_:)), in: controller))
        layout.toggleZoom()
        #expect(!isEnabled(#selector(MainFrameViewController.switchPanel(_:)), in: controller))
        controller.frameController.switchPanel(nil)
        #expect(layout.activePanel == .leftPanel)
    }

    @Test func movingATabTakesTheSameItemToTheOtherPanel() {
        let controller = controller()
        let second = TestItem("second")
        layout.insert(second)
        controller.frameController.moveTabToOtherPanel(nil)
        #expect(layout.slot(of: second.id) == .rightPanel)
        #expect(layout.item(second.id) === second)
        #expect(layout.focusedPanelItem === second)
        #expect(controller.window?.firstResponder === second.viewController.view)
    }

    @Test func aPanelsOnlyBrowserCantBeMoved() {
        let controller = controller()
        layout.remove(left.id)
        #expect(layout.focusedPanelItem?.kind == "filler")
        #expect(
            !isEnabled(#selector(MainFrameViewController.moveTabToOtherPanel(_:)), in: controller))
    }

    @Test func tabSwitchingIsDisabledWhileZoomed() {
        let controller = controller()
        layout.insert(TestItem("second"))
        #expect(isEnabled(#selector(MainFrameViewController.selectNextTab(_:)), in: controller))
        #expect(
            isEnabled(#selector(MainFrameViewController.selectPreviousTab(_:)), in: controller))
        layout.toggleZoom()
        #expect(!isEnabled(#selector(MainFrameViewController.selectNextTab(_:)), in: controller))
        #expect(
            !isEnabled(#selector(MainFrameViewController.selectPreviousTab(_:)), in: controller))
    }
}
