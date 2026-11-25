import AppKit
import Testing

@testable import WorkspaceKit

/// The slot under the panels for the operations strip (docs/plans/M6.md, D-e, step 13).
@MainActor
@Suite struct MainFrameAccessoryTests {
    func frame() -> (MainFrameViewController, NSWindow) {
        let layout = MainFrameLayout(filler: .testBrowsers)
        layout.fillEmptyPanels()
        let frame = MainFrameViewController(
            layout: layout, closeCoordinator: CloseCoordinator(openItems: { [] }) { _ in .discard })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = frame
        window.setContentSize(NSSize(width: 800, height: 500))
        return (frame, window)
    }

    func panelsHeight(_ frame: MainFrameViewController) -> CGFloat {
        frame.view.layoutSubtreeIfNeeded()
        return frame.children.first { $0 is NSSplitViewController }?.view.frame.height ?? 0
    }

    @Test func anAccessoryTakesItsOwnHeightFromThePanels() {
        let (frame, window) = frame()
        defer { window.close() }
        let without = panelsHeight(frame)
        let accessory = NSViewController()
        accessory.view = NSView()
        accessory.view.heightAnchor.constraint(equalToConstant: 30).isActive = true
        frame.bottomAccessory = accessory
        #expect(abs(panelsHeight(frame) - (without - 30)) < 1)
        #expect(abs(accessory.view.frame.height - 30) < 1)
        frame.bottomAccessory = nil
        #expect(abs(panelsHeight(frame) - without) < 1)
    }
}
