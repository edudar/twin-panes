import AppKit
import Testing

@testable import WorkspaceKit

/// A panel joins the split view with a frame that already meets its own minimums (240 pt
/// wide, room for the 34 pt tab bar). The split view lays its panels out by frame, so a
/// panel that started at zero size had its fixed-size autoresizing constraints break the
/// minimums each time a window opened, and AppKit logged the conflicts.
@MainActor
@Suite struct MainFramePanelSizeTests {
    @Test func panelsStartAtTheirMinimumSize() throws {
        let layout = MainFrameLayout(filler: .testBrowsers)
        layout.fillEmptyPanels()
        let frame = MainFrameViewController(
            layout: layout,
            closeCoordinator: CloseCoordinator(openItems: { [] }) { _ in .discard })
        let root = frame.view
        for slot in [SlotID.leftPanel, .rightPanel] {
            let panel = try #require(MainFrameFocusTests.view(in: root, id: slot.rawValue))
            #expect(
                panel.frame.width >= 240 && panel.frame.height >= 34,
                "\(slot.rawValue) starts at \(panel.frame.size)")
        }
        let minWidth = root.constraints.first {
            $0.firstItem === root && $0.firstAttribute == .width
                && $0.relation == .greaterThanOrEqual
        }?.constant
        #expect(minWidth == 481)
    }
}
