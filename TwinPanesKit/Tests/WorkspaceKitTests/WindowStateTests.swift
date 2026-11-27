import AppKit
import Foundation
import Testing

@testable import WorkspaceKit

@MainActor
private final class CountingItem: WorkspaceItem {
    let id = ItemID()
    let kind: ItemKind = "test"
    let title = "counting"
    let preferredSlot: SlotID = .leftPanel
    weak var host: WorkspaceHost?
    var onChange: (() -> Void)?
    lazy var viewController: NSViewController = {
        let vc = NSViewController()
        vc.view = NSView()
        return vc
    }()
    private(set) var reads = 0
    var restorableState: ItemState? {
        reads += 1
        return ItemState(kind: kind, version: 1, payload: Data("counting".utf8))
    }
}

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

    @Test func restorableStateIsReadOncePerItem() {
        let item = CountingItem()
        saved.insert(item)
        saved.select(item.id)
        saved.toggleZoom(item.id)
        _ = saved.savedState
        #expect(item.reads == 1)
    }

    @Test(arguments: [0, -1])
    func nonPositiveVersionsAreRefused(version: Int) throws {
        var state = saved.savedState
        state.version = version
        let data = try state.encoded()
        #expect(throws: DecodingError.self) { try WindowState(decoding: data) }
        #expect(
            restorer.item(from: ItemState(kind: "test", version: version, payload: Data())) == nil)
    }

    @Test func previewFieldsRoundTripAndOlderStateDecodesWithoutThem() throws {
        var state = saved.savedState
        let legacyData = try state.encoded()
        let legacyJSON = String(decoding: legacyData, as: UTF8.self)
        #expect(!legacyJSON.contains("previewShown") && !legacyJSON.contains("previewWidth"))
        let decodedLegacy = try WindowState(decoding: legacyData)
        #expect(decodedLegacy.version == 1)
        #expect(decodedLegacy.previewShown == nil && decodedLegacy.previewWidth == nil)

        state.previewShown = true
        state.previewWidth = 310
        let decoded = try WindowState(decoding: try state.encoded())
        #expect(decoded.previewShown == true && decoded.previewWidth == 310)
    }
}
