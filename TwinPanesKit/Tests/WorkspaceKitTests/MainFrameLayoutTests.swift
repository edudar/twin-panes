import Testing

@testable import WorkspaceKit

@MainActor
@Suite struct MainFrameLayoutTests {
    @Test func insertSelectsAndActivates() {
        let layout = MainFrameLayout()
        let a = TestItem("a")
        let b = TestItem("b", slot: .rightPanel)
        layout.insert(a)
        layout.insert(b)
        #expect(layout.items(in: .leftPanel).map(\.title) == ["a"])
        #expect(layout.items(in: .rightPanel).map(\.title) == ["b"])
        #expect(layout.activePanel == .rightPanel)
        #expect(layout.focusedPanelItem?.id == b.id)
    }

    @Test func insertGoesAfterSelectedTab() {
        let layout = MainFrameLayout()
        let a = TestItem("a"), b = TestItem("b"), c = TestItem("c")
        layout.insert(a)
        layout.insert(b)
        layout.select(a.id)
        layout.insert(c)
        #expect(layout.items(in: .leftPanel).map(\.title) == ["a", "c", "b"])
    }

    @Test func removeSelectsNeighbourAndClearsZoom() {
        let layout = MainFrameLayout()
        let a = TestItem("a"), b = TestItem("b"), c = TestItem("c")
        for item in [a, b, c] { layout.insert(item) }
        layout.select(b.id)
        layout.toggleZoom()
        #expect(layout.zoomedItemID == b.id)
        layout.remove(b.id)
        #expect(layout.zoomedItemID == nil)
        #expect(layout.selection[.leftPanel] == c.id)
        layout.remove(c.id)
        #expect(layout.selection[.leftPanel] == a.id)
        layout.remove(a.id)
        #expect(layout.selection[.leftPanel] == nil)
    }

    @Test func moveKeepsInstanceZoomAndNotifiesOnce() {
        let layout = MainFrameLayout()
        let a = TestItem("a"), b = TestItem("b"), c = TestItem("c")
        for item in [a, b, c] { layout.insert(item) }
        layout.toggleZoom(a.id)
        var notifications = 0
        let token = layout.observe { notifications += 1 }
        layout.move(a.id, to: .rightPanel)
        #expect(notifications == 1)
        #expect(layout.slot(of: a.id) == .rightPanel)
        #expect(layout.item(a.id) === a)
        #expect(layout.zoomedItemID == a.id)
        // Reordering within the same slot also notifies once.
        layout.move(b.id, to: .leftPanel, at: 1)
        #expect(notifications == 2)
        #expect(layout.items(in: .leftPanel).map(\.title) == ["c", "b"])
        _ = token
    }

    @Test func zoomToggles() {
        let layout = MainFrameLayout()
        layout.toggleZoom()
        #expect(layout.zoomedItemID == nil, "nothing to zoom")
        let a = TestItem("a")
        layout.insert(a)
        layout.toggleZoom()
        #expect(layout.zoomedItem === a)
        layout.toggleZoom()
        #expect(layout.zoomedItemID == nil)
    }

    @Test func adjacentTabWraps() {
        let layout = MainFrameLayout()
        let a = TestItem("a"), b = TestItem("b")
        layout.insert(a)
        layout.insert(b)
        layout.selectAdjacentTab(1)
        #expect(layout.focusedPanelItem === a)
        layout.selectAdjacentTab(-1)
        #expect(layout.focusedPanelItem === b)
    }

    @Test func observersFire() {
        let layout = MainFrameLayout()
        var count = 0
        let token = layout.observe { count += 1 }
        layout.insert(TestItem("a"))
        layout.toggleZoom()
        #expect(count == 2)
        _ = token
    }
}
