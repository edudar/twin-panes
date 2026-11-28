import AppKit
import Testing

@testable import WorkspaceKit

/// The status line shows what the item in front says, not what a tab behind it or the
/// other panel's tab says (docs/plans/M5.md, D-a: both panels are always there).
@MainActor
@Suite struct MainFrameStatusTests {
    let layout = MainFrameLayout(filler: .testBrowsers)
    let left = TestItem("left")
    let right = TestItem("right", slot: .rightPanel)

    func frame() -> MainFrameViewController {
        let frame = MainFrameViewController(
            layout: layout,
            closeCoordinator: CloseCoordinator(openItems: { [] }) { _ in .discard })
        layout.insert(left)
        layout.insert(right)
        layout.activate(.leftPanel)
        frame.loadView()
        return frame
    }

    func statusLine(of frame: MainFrameViewController) -> String? {
        frame.view.subviews.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "statusLine" }?.stringValue
    }

    func trailingStatus(of frame: MainFrameViewController) -> String? {
        frame.view.subviews.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "statusTrailing" }?.stringValue
    }

    @Test func theActivePanelsTabWritesTheStatusLine() {
        let frame = frame()
        left.host?.showStatus("from the left")
        #expect(statusLine(of: frame) == "from the left")
    }

    @Test func theActivePanelsTabWritesLeadingAndTrailingStatus() {
        let frame = frame()
        left.host?.showStatus("2 selected · 1 KB", trailing: "15 items (7 folders)")
        #expect(statusLine(of: frame) == "2 selected · 1 KB")
        #expect(trailingStatus(of: frame) == "15 items (7 folders)")
        left.host?.showStatus("only leading")
        #expect(statusLine(of: frame) == "only leading")
        #expect(trailingStatus(of: frame) == "")
    }

    @Test func theOtherPanelsTabDoesntWriteTheStatusLine() {
        let frame = frame()
        left.host?.showStatus("from the left", trailing: "left stats")
        right.host?.showStatus("from the right", trailing: "right stats")
        #expect(statusLine(of: frame) == "from the left")
        #expect(trailingStatus(of: frame) == "left stats")
    }

    @Test func aTabBehindTheSelectedOneDoesntWriteTheStatusLine() {
        let frame = frame()
        let front = TestItem("front")
        layout.insert(front)
        left.host?.showStatus("from behind")
        #expect(statusLine(of: frame) == "")
        front.host?.showStatus("from the front")
        #expect(statusLine(of: frame) == "from the front")
    }

    @Test func theZoomedItemWritesTheStatusLine() {
        let frame = frame()
        layout.toggleZoom(right.id)
        right.host?.showStatus("zoomed")
        #expect(statusLine(of: frame) == "zoomed")
    }
}
