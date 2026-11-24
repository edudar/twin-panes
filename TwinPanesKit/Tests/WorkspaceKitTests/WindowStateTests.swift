import Foundation
import Testing

@testable import WorkspaceKit

/// Saving a window's tabs and putting them back (docs/plans/M5.md, D-c).
@MainActor
@Suite struct WindowStateTests {
    let saved = MainFrameLayout(filler: .testBrowsers)
    let restored = MainFrameLayout(filler: .testBrowsers)

    var restorer: ItemRestorer {
        var restorer = ItemRestorer()
        restorer.register("test", newestVersion: 1) { state in
            TestItem(String(decoding: state.payload, as: UTF8.self))
        }
        return restorer
    }

    func restorable(_ title: String, version: Int = 1, kind: ItemKind = "test") -> TestItem {
        let item = TestItem(title, kind: kind)
        item.restorableState = ItemState(kind: kind, version: version, payload: Data(title.utf8))
        return item
    }

    func titles(_ layout: MainFrameLayout, _ slot: SlotID) -> [String] {
        layout.items(in: slot).map(\.title)
    }

    func roundTrip() throws {
        let data = try saved.savedState.encoded()
        restored.restore(try WindowState(decoding: data), using: restorer)
    }

    @Test func tabsSelectionActivePanelAndZoomComeBack() throws {
        let a = restorable("a"), b = restorable("b"), c = restorable("c")
        saved.insert(a)
        saved.insert(b)
        saved.insert(c, in: .rightPanel)
        saved.select(b.id)
        saved.toggleZoom(b.id)
        try roundTrip()
        #expect(titles(restored, .leftPanel) == ["a", "b"])
        #expect(titles(restored, .rightPanel) == ["c"])
        #expect(restored.activePanel == .leftPanel)
        #expect(restored.selectedItem(in: .leftPanel)?.title == "b")
        #expect(restored.zoomedItem?.title == "b")
    }

    @Test func itemsWithoutStateArentSaved() throws {
        saved.insert(restorable("a"))
        saved.insert(TestItem("unsaved"))
        try roundTrip()
        #expect(titles(restored, .leftPanel) == ["a"])
        #expect(restored.selectedItem(in: .leftPanel)?.title == "a")
    }

    @Test func anUnknownKindIsSkipped() throws {
        saved.insert(restorable("a"))
        saved.insert(restorable("future", kind: "future"))
        try roundTrip()
        #expect(titles(restored, .leftPanel) == ["a"])
    }

    @Test func aNewerVersionOfAKnownKindIsSkipped() throws {
        saved.insert(restorable("a"))
        saved.insert(restorable("newer", version: 2))
        try roundTrip()
        #expect(titles(restored, .leftPanel) == ["a"])
    }

    @Test func aSkippedSelectionFallsBackToThePanelsFirstTab() throws {
        saved.insert(restorable("a"))
        saved.insert(restorable("b"))
        saved.insert(restorable("newer", version: 2))
        saved.toggleZoom()
        try roundTrip()
        #expect(restored.selectedItem(in: .leftPanel)?.title == "a")
        #expect(restored.zoomedItem == nil)
    }

    @Test func aWindowThatRestoresNothingGetsTheDefaultTabs() throws {
        saved.insert(restorable("future", kind: "future"))
        try roundTrip()
        #expect(restored.items(in: .leftPanel).map(\.kind) == ["filler"])
        #expect(restored.items(in: .rightPanel).map(\.kind) == ["filler"])
    }

    @Test func stateFromANewerBuildIsRefused() throws {
        var state = saved.savedState
        state.version = WindowState.currentVersion + 1
        let data = try state.encoded()
        #expect(throws: WindowStateError.newerVersion(WindowState.currentVersion + 1)) {
            try WindowState(decoding: data)
        }
    }

    @Test func dataThatIsntWindowStateIsRefused() {
        #expect(throws: DecodingError.self) { try WindowState(decoding: Data("{}".utf8)) }
    }
}
