import Testing

@testable import WorkspaceKit

@MainActor
@Suite struct MainFrameLayoutTests {
    @Test func insertSelectsAndActivates() {
        let layout = MainFrameLayout(filler: .testBrowsers)
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
        let layout = MainFrameLayout(filler: .testBrowsers)
        let a = TestItem("a"), b = TestItem("b"), c = TestItem("c")
        layout.insert(a)
        layout.insert(b)
        layout.select(a.id)
        layout.insert(c)
        #expect(layout.items(in: .leftPanel).map(\.title) == ["a", "c", "b"])
    }

    @Test func removeSelectsNeighbourAndClearsZoom() {
        let layout = MainFrameLayout(filler: .testBrowsers)
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
        #expect(layout.items(in: .leftPanel).map(\.title) == ["leftPanel"])
    }

    @Test func moveKeepsInstanceZoomAndNotifiesOnce() {
        let layout = MainFrameLayout(filler: .testBrowsers)
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
        let layout = MainFrameLayout(filler: .testBrowsers)
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
        let layout = MainFrameLayout(filler: .testBrowsers)
        let a = TestItem("a"), b = TestItem("b")
        layout.insert(a)
        layout.insert(b)
        layout.selectAdjacentTab(1)
        #expect(layout.focusedPanelItem === a)
        layout.selectAdjacentTab(-1)
        #expect(layout.focusedPanelItem === b)
    }

    @Test func observersFire() {
        let layout = MainFrameLayout(filler: .testBrowsers)
        var count = 0
        let token = layout.observe { count += 1 }
        layout.insert(TestItem("a"))
        layout.toggleZoom()
        #expect(count == 2)
        _ = token
    }

    // MARK: Panels are never empty (docs/plans/M5.md, D-a)

    @Test func fillingGivesEachEmptyPanelOneFillerTab() {
        let layout = MainFrameLayout(filler: .testBrowsers)
        layout.fillEmptyPanels()
        #expect(layout.items(in: .leftPanel).map(\.kind) == ["filler"])
        #expect(layout.items(in: .rightPanel).map(\.kind) == ["filler"])
        #expect(layout.items(in: .preview).isEmpty)
        #expect(layout.activePanel == .leftPanel)
    }

    @Test func theRightPanelIsFilledAfterTheLeft() {
        var leftTabsSeenByRight: Int?
        let filler = PanelFiller(kind: "filler") { panel, layout in
            if panel == .rightPanel { leftTabsSeenByRight = layout.items(in: .leftPanel).count }
            return TestItem(panel.rawValue, kind: "filler", slot: panel)
        }
        let layout = MainFrameLayout(filler: filler)
        layout.fillEmptyPanels()
        #expect(leftTabsSeenByRight == 1)
    }

    @Test func fillingLeavesAPanelWithTabsAlone() {
        let layout = MainFrameLayout(filler: .testBrowsers)
        let a = TestItem("a")
        layout.insert(a)
        layout.fillEmptyPanels()
        #expect(layout.items(in: .leftPanel).map(\.title) == ["a"])
        #expect(layout.items(in: .rightPanel).map(\.kind) == ["filler"])
    }

    @Test func aPanelsOnlyFillerTabCantBeRemoved() {
        let layout = MainFrameLayout(filler: .testBrowsers)
        layout.fillEmptyPanels()
        let only = layout.items(in: .leftPanel)[0]
        #expect(!layout.canRemove(only.id))
        #expect(layout.remove(only.id) == nil)
        #expect(layout.items(in: .leftPanel).map(\.id) == [only.id])
    }

    @Test func aFillerTabWithSiblingsCanBeRemoved() {
        let layout = MainFrameLayout(filler: .testBrowsers)
        layout.fillEmptyPanels()
        let filler = layout.items(in: .leftPanel)[0]
        layout.insert(TestItem("a"))
        #expect(layout.canRemove(filler.id))
        #expect(layout.remove(filler.id) === filler)
        #expect(layout.items(in: .leftPanel).map(\.title) == ["a"])
    }

    @Test func removingAPanelsLastOtherTabLeavesAFillerSelected() {
        let layout = MainFrameLayout(filler: .testBrowsers)
        let a = TestItem("a", slot: .rightPanel)
        layout.insert(a)
        layout.activate(.leftPanel)
        var notifications = 0
        let token = layout.observe { notifications += 1 }
        #expect(layout.canRemove(a.id))
        layout.remove(a.id)
        #expect(layout.items(in: .rightPanel).map(\.kind) == ["filler"])
        #expect(layout.selectedItem(in: .rightPanel)?.kind == "filler")
        #expect(layout.activePanel == .leftPanel)
        #expect(notifications == 1)
        _ = token
    }

    @Test func aPanelsOnlyFillerTabCantMoveToTheOtherPanel() {
        let layout = MainFrameLayout(filler: .testBrowsers)
        layout.fillEmptyPanels()
        let only = layout.items(in: .leftPanel)[0]
        var notifications = 0
        let token = layout.observe { notifications += 1 }
        #expect(!layout.canMove(only.id, to: .rightPanel))
        layout.move(only.id, to: .rightPanel)
        #expect(layout.slot(of: only.id) == .leftPanel)
        #expect(layout.items(in: .rightPanel).count == 1)
        #expect(notifications == 0)
        _ = token
    }

    @Test func aPanelsOnlyTabCanMoveWithinItsPanel() {
        let layout = MainFrameLayout(filler: .testBrowsers)
        layout.fillEmptyPanels()
        let only = layout.items(in: .leftPanel)[0]
        #expect(layout.canMove(only.id, to: .leftPanel))
    }

    @Test func movingAPanelsLastOtherTabOutLeavesAFiller() {
        let layout = MainFrameLayout(filler: .testBrowsers)
        layout.fillEmptyPanels()
        let a = TestItem("a")
        layout.insert(a)
        layout.remove(layout.items(in: .leftPanel)[0].id)
        var notifications = 0
        let token = layout.observe { notifications += 1 }
        layout.move(a.id, to: .rightPanel)
        #expect(layout.items(in: .leftPanel).map(\.kind) == ["filler"])
        #expect(layout.selectedItem(in: .rightPanel) === a)
        #expect(layout.activePanel == .rightPanel)
        #expect(notifications == 1)
        _ = token
    }

    @Test func eachPanelIsAcrossFromTheOther() {
        #expect(SlotID.leftPanel.otherPanel == .rightPanel)
        #expect(SlotID.rightPanel.otherPanel == .leftPanel)
        #expect(SlotID.preview.otherPanel == nil)
        #expect(SlotID.drawer.otherPanel == nil)
    }

    @Test func unknownItemCannotBeRemovedOrMoved() {
        let layout = MainFrameLayout(filler: .testBrowsers)
        layout.fillEmptyPanels()
        let unknown = ItemID()
        #expect(!layout.canRemove(unknown))
        #expect(!layout.canMove(unknown, to: .rightPanel))
    }
}
