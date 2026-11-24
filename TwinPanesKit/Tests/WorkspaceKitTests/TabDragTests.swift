import AppKit
import Testing

@testable import WorkspaceKit

/// Dragging tabs within a tab bar and onto the other panel's (docs/plans/M5.md, D-b).
/// A synthesized drag isn't reliable, so the drag itself is checked by hand.
@MainActor
@Suite struct TabDragTests {
    let layout = MainFrameLayout(filler: .testBrowsers)
    let a = TestItem("a"), b = TestItem("b"), c = TestItem("c")

    func frame() -> MainFrameViewController {
        for item in [a, b, c] { layout.insert(item) }
        layout.fillEmptyPanels()
        return MainFrameViewController(
            layout: layout,
            closeCoordinator: CloseCoordinator(openItems: { [] }) { _ in .discard })
    }

    func titles(in slot: SlotID) -> [String] { layout.items(in: slot).map(\.title) }

    @Test func aDraggedTabReadsBackAsItsItem() {
        let id = ItemID()
        #expect(ItemID(draggedTab: id.draggedTab) == id)
    }

    @Test func otherPasteboardContentIsntATab() {
        let item = NSPasteboardItem()
        item.setString("not a tab", forType: .string)
        #expect(ItemID(draggedTab: item) == nil)
    }

    @Test(arguments: [(-5.0, 0), (10.0, 0), (60.0, 1), (130.0, 2), (500.0, 3)])
    func theDropGoesAfterTheTabsLeftOfIt(x: Double, expected: Int) {
        #expect(tabInsertionIndex(at: x, tabCentres: [50, 120, 190]) == expected)
    }

    @Test func anEmptyTabBarTakesTheDropFirst() {
        #expect(tabInsertionIndex(at: 40, tabCentres: []) == 0)
    }

    @Test func droppingATabFurtherRightReordersIt() {
        let frame = frame()
        frame.dropTab(a.id, in: .leftPanel, at: 3)
        #expect(titles(in: .leftPanel) == ["b", "c", "a"])
    }

    @Test func droppingATabFurtherLeftReordersIt() {
        let frame = frame()
        frame.dropTab(c.id, in: .leftPanel, at: 0)
        #expect(titles(in: .leftPanel) == ["c", "a", "b"])
    }

    @Test(arguments: [1, 2])
    func droppingATabNextToItselfLeavesTheOrder(insertion: Int) {
        let frame = frame()
        frame.dropTab(b.id, in: .leftPanel, at: insertion)
        #expect(titles(in: .leftPanel) == ["a", "b", "c"])
    }

    @Test func droppingOnTheOtherPanelMovesTheTabThere() {
        let frame = frame()
        frame.dropTab(b.id, in: .rightPanel, at: 0)
        #expect(titles(in: .leftPanel) == ["a", "c"])
        #expect(titles(in: .rightPanel) == ["b", "rightPanel"])
        #expect(layout.focusedPanelItem === b)
    }

    @Test func aPanelsOnlyBrowserCantBeDroppedOnTheOtherPanel() {
        let frame = frame()
        let browser = layout.items(in: .rightPanel)[0]
        #expect(frame.canDropTab(browser.id, in: .rightPanel))
        #expect(!frame.canDropTab(browser.id, in: .leftPanel))
    }

    @Test func aTabFromAnotherWindowCantBeDropped() {
        let frame = frame()
        #expect(!frame.canDropTab(ItemID(), in: .leftPanel))
        #expect(frame.canDropTab(a.id, in: .rightPanel))
    }
}
