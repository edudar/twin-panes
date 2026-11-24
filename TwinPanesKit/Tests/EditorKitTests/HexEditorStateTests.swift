import AppKit
import Foundation
import Testing
import TwinPanesCore
import WorkspaceKit

@testable import EditorKit
@testable import HexViewKit

/// An editor tab's view comes back after a relaunch (docs/plans/M5.md, D-c, step 9).
@MainActor
@Suite struct HexEditorStateTests {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("HexEditorStateTests-\(UUID().uuidString).bin")
    let item: HexEditorItem

    init() throws {
        try Data((0..<4096).map { UInt8($0 % 256) }).write(to: url)
        item = try HexEditorItem(url: url)
        _ = item.controller.view
    }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }

    func savedState() throws -> EditorState {
        let state = try #require(item.restorableState)
        return try #require(HexEditorItem.editorState(from: state))
    }

    /// Another tab on the same file, as the app opens it when restoring.
    func restoredTab(_ state: EditorState) -> HexEditorItem {
        let tab = HexEditorItem(session: item.session)
        _ = tab.controller.view
        tab.restoreView(state)
        return tab
    }

    @Test func theStateIsAnEditorsCurrentVersion() throws {
        defer { cleanUp() }
        let state = try #require(item.restorableState)
        #expect(state.kind == .editor && state.version == HexEditorItem.stateVersion)
    }

    @Test func theBookmarkResolvesToTheFile() throws {
        defer { cleanUp() }
        let resolved = try #require(BookmarkStore.resolve(try savedState().fileBookmark))
        #expect(
            resolved.url.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path)
    }

    @Test func optionsSelectionAndScrollComeBack() throws {
        defer { cleanUp() }
        let options = HexViewOptions(
            bytesPerRow: .fixed(8), grouping: 2, offsetBase: .decimal, textEncoding: .latin1)
        item.hexView.options = options
        item.hexView.select(100..<120)
        item.hexView.scroll(toTopRow: 40)
        let tab = restoredTab(try savedState())
        #expect(tab.hexView.options == options)
        #expect(tab.hexView.selection.range == 100..<120)
        #expect(tab.hexView.topRow == 40)
    }

    @Test func aSelectionPastTheEndIsClampedToTheFile() throws {
        defer { cleanUp() }
        var state = try savedState()
        (state.selectionStart, state.selectionEnd) = (5000, 6000)
        let tab = restoredTab(state)
        #expect(tab.hexView.selection.range == 4095..<4096)
    }

    @Test func optionsThisBuildDoesntKnowKeepTheirDefaults() throws {
        defer { cleanUp() }
        var state = try savedState()
        (state.offsetBase, state.textEncoding, state.bytesPerRow) = ("octal", "ebcdic", 12)
        let tab = restoredTab(state)
        #expect(tab.hexView.options == HexViewOptions())
    }

    @Test func aPayloadThatIsntAnEditorsIsRefused() {
        defer { cleanUp() }
        let state = ItemState(kind: .editor, version: 1, payload: Data("not json".utf8))
        #expect(HexEditorItem.editorState(from: state) == nil)
    }
}
