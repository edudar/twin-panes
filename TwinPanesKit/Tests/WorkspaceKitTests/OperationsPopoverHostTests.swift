import AppKit
import Testing

@testable import WorkspaceKit

@MainActor
@Suite struct OperationsPopoverHostTests {
    private func makeController() -> MainWindowController {
        let layout = MainFrameLayout(filler: .testBrowsers)
        layout.fillEmptyPanels()
        return MainWindowController(
            layout: layout, workspace: WorkspaceRegistry(),
            dispatcher: CommandDispatcher(registry: CommandRegistry()),
            closeCoordinator: CloseCoordinator(openItems: { [] }) { _ in .discard })
    }

    @Test func toolbarItemValidatesOnlyWhenContentIsAttached() throws {
        let controller = makeController()
        defer { controller.closeWithoutAsking() }
        let toolbar = try #require(controller.window?.toolbar)
        let item = try #require(toolbar.items.first { $0.itemIdentifier == .toggleOperations })
        let frame = controller.frameController

        #expect(!frame.validateToolbarItem(item))

        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        frame.operationsPopoverContent = content
        #expect(frame.validateToolbarItem(item))
    }

    @Test func indicatorStateUpdatesToolbarIconAndToolTip() throws {
        let controller = makeController()
        defer { controller.closeWithoutAsking() }
        let toolbar = try #require(controller.window?.toolbar)
        let item = try #require(toolbar.items.first { $0.itemIdentifier == .toggleOperations })
        let frame = controller.frameController

        frame.operationsIndicatorState = .running(progress: 0.4)
        #expect(item.toolTip == "Show Activity (Running)")
        #expect(item.image != nil)

        frame.operationsIndicatorState = .failed
        #expect(item.toolTip == "Show Activity (Errors)")
        #expect(item.image != nil)

        frame.operationsIndicatorState = .idle
        #expect(item.toolTip == "Show Activity")
        #expect(item.image != nil)
    }

    @Test func toggleOpensAndClosesPopoverAndNotifiesUserOpen() async {
        let controller = makeController()
        defer { controller.closeWithoutAsking() }
        let frame = controller.frameController
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        frame.operationsPopoverContent = content

        var userOpenCount = 0
        frame.onOperationsPopoverUserOpen = { userOpenCount += 1 }

        controller.window?.orderBack(nil)
        frame.toggleOperationsPopover(nil)
        #expect(userOpenCount == 1)
        #expect(frame.isOperationsPopoverShown)

        await withCheckedContinuation { continuation in
            frame.onOperationsPopoverClose = {
                frame.onOperationsPopoverClose = nil
                continuation.resume()
            }
            frame.toggleOperationsPopover(nil)
        }
        #expect(userOpenCount == 1)
        #expect(!frame.isOperationsPopoverShown)
    }
}
