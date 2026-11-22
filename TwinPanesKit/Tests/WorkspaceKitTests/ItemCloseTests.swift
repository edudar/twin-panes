import AppKit
import Testing

@testable import WorkspaceKit

/// Items hear that they're closing, so they can stop background work (review bug 3:
/// a search kept running after its tab or window closed).
@MainActor
@Suite struct ItemCloseTests {
    let workspace = WorkspaceRegistry()
    let layout = MainFrameLayout()

    func coordinator() -> CloseCoordinator {
        CloseCoordinator(openItems: { [workspace] in workspace.allItems }) { _ in .discard }
    }

    @Test func closingATabTellsTheItem() async {
        let frame = MainFrameViewController(layout: layout, closeCoordinator: coordinator())
        let item = TestItem("one"), other = TestItem("two")
        layout.insert(item)
        layout.insert(other)
        frame.closeItem(item.id)
        for _ in 0..<100 where layout.item(item.id) != nil { await Task.yield() }
        #expect(layout.item(item.id) == nil)
        #expect(item.closes == 1)
        #expect(other.closes == 0)
    }

    @Test func rapidDoubleCloseCallsWillCloseOnlyOnce() async {
        let frame = MainFrameViewController(layout: layout, closeCoordinator: coordinator())
        let item = TestItem("one")
        layout.insert(item)
        frame.closeItem(item.id)
        frame.closeItem(item.id)
        for _ in 0..<100 where layout.item(item.id) != nil { await Task.yield() }
        #expect(layout.item(item.id) == nil)
        #expect(item.closes == 1)
    }

    @Test func closingAWindowTellsEveryItem() {
        let items = [TestItem("left"), TestItem("right", slot: .rightPanel)]
        for item in items { layout.insert(item) }
        let controller = MainWindowController(
            layout: layout, workspace: workspace,
            dispatcher: CommandDispatcher(registry: CommandRegistry()),
            closeCoordinator: coordinator())
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(items.map(\.closes) == [1, 1])
    }

    @Test func windowShouldClosePromptsForDirtyItems() async {
        let session = TestSession()
        session.isDirty = true
        let item = TestItem("dirty", session: session)
        layout.insert(item)
        @MainActor final class Answer { var decision: CloseDecision = .cancel }
        let answer = Answer()
        let close = CloseCoordinator(openItems: { [workspace] in workspace.allItems }) { _ in
            answer.decision
        }
        let controller = MainWindowController(
            layout: layout, workspace: workspace,
            dispatcher: CommandDispatcher(registry: CommandRegistry()),
            closeCoordinator: close)
        let window = controller.window!
        #expect(controller.windowShouldClose(window) == false)
        await Task.yield()
        #expect(session.isDirty)

        answer.decision = .discard
        #expect(controller.windowShouldClose(window) == false)
        for _ in 0..<100 where session.isDirty { await Task.yield() }
        #expect(!session.isDirty)
    }
}
