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

    /// The app restores a tab before showing it, so before its view has loaded.
    @Test func aViewRestoredBeforeItLoadsKeepsItsSelectionAndScroll() throws {
        defer { cleanUp() }
        item.hexView.select(100..<120)
        item.hexView.scroll(toTopRow: 3)
        let state = try savedState()
        let tab = HexEditorItem(session: item.session)
        tab.restoreView(state)
        _ = tab.controller.view
        #expect(tab.hexView.selection.range == 100..<120)
        #expect(tab.hexView.topRow == 3)
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

    @Test func wrongKindAndUnsupportedVersionsAreRefused() throws {
        defer { cleanUp() }
        let valid = try #require(item.restorableState)
        let wrongKind = ItemState(
            kind: ItemKind(rawValue: "other"), version: valid.version, payload: valid.payload)
        let zeroVersion = ItemState(kind: .editor, version: 0, payload: valid.payload)
        let futureVersion = ItemState(
            kind: .editor, version: HexEditorItem.stateVersion + 1, payload: valid.payload)
        #expect(HexEditorItem.editorState(from: wrongKind) == nil)
        #expect(HexEditorItem.editorState(from: zeroVersion) == nil)
        #expect(HexEditorItem.editorState(from: futureVersion) == nil)
    }

    @Test func invalidGroupingReversedSelectionAndShrunkenFileScrollAreClamped() throws {
        defer { cleanUp() }
        var state = try savedState()
        state.grouping = 3
        state.selectionStart = 300
        state.selectionEnd = 100
        state.topRow = 10_000
        state.topOffset = 1_000_000
        let tab = restoredTab(state)
        #expect(tab.hexView.options.grouping == HexViewOptions().grouping)
        #expect(tab.hexView.selection.range == 300..<301)
        #expect(tab.hexView.topRow < tab.hexView.layout.rowCount)

        var maxState = try savedState()
        maxState.selectionStart = UInt64.max
        maxState.selectionEnd = UInt64.max
        let maxTab = restoredTab(maxState)
        #expect(maxTab.hexView.selection.range == 4095..<4096)
    }

    @Test func emptyFileSavesAndRestoresSafely() throws {
        defer { cleanUp() }
        let emptyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HexEditorStateTests-empty-\(UUID().uuidString).bin")
        try Data().write(to: emptyURL)
        defer { try? FileManager.default.removeItem(at: emptyURL) }

        let emptyItem = try HexEditorItem(url: emptyURL)
        _ = emptyItem.controller.view
        let saved = try #require(emptyItem.restorableState)
        let decoded = try #require(HexEditorItem.editorState(from: saved))
        #expect(decoded.selectionStart == 0 && decoded.selectionEnd == 0 && decoded.topRow == 0)

        var nonZeroState = try savedState()
        (nonZeroState.selectionStart, nonZeroState.selectionEnd, nonZeroState.topRow) = (50, 60, 10)
        nonZeroState.topOffset = 160
        let restored = HexEditorItem(session: emptyItem.session)
        restored.restoreView(nonZeroState)
        #expect(restored.hexView.selection.range == 0..<0)
        #expect(restored.hexView.topRow == 0)
    }

    @Test func autoFitPreservesByteOffsetAfterWindowLayout() throws {
        defer { cleanUp() }
        item.hexView.options = HexViewOptions(bytesPerRow: .autoFit)
        let sourceWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        sourceWindow.isReleasedWhenClosed = false
        defer { sourceWindow.close() }
        sourceWindow.contentViewController = item.controller
        sourceWindow.setContentSize(NSSize(width: 600, height: 400))
        sourceWindow.layoutIfNeeded()
        sourceWindow.contentView?.layoutSubtreeIfNeeded()

        let narrowBytesPerRow = item.hexView.layout.bytesPerRow
        item.hexView.scroll(toTopRow: 40)
        let expectedOffset = UInt64(40 * narrowBytesPerRow)
        let state = try savedState()
        #expect(state.topOffset == expectedOffset)

        let tab = HexEditorItem(session: item.session)
        tab.restoreView(state)
        let wideWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        wideWindow.isReleasedWhenClosed = false
        defer { wideWindow.close() }
        wideWindow.contentViewController = tab.controller
        wideWindow.setContentSize(NSSize(width: 1200, height: 400))
        wideWindow.layoutIfNeeded()
        wideWindow.contentView?.layoutSubtreeIfNeeded()

        let wideBytesPerRow = tab.hexView.layout.bytesPerRow
        #expect(wideBytesPerRow > narrowBytesPerRow)
        let expectedRow = expectedOffset / UInt64(wideBytesPerRow)
        #expect(tab.hexView.topRow == expectedRow)
    }

    @Test func nearEOFScrollRestoresIntoShorterWindow() throws {
        defer { cleanUp() }
        item.hexView.options = HexViewOptions(bytesPerRow: .fixed(16))
        let shortWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 150),
            styleMask: [.titled], backing: .buffered, defer: false)
        shortWindow.isReleasedWhenClosed = false
        defer { shortWindow.close() }
        shortWindow.contentViewController = item.controller
        shortWindow.setContentSize(NSSize(width: 600, height: 150))
        shortWindow.layoutIfNeeded()
        shortWindow.contentView?.layoutSubtreeIfNeeded()

        item.hexView.scroll(toTopRow: 245)
        let savedRow = item.hexView.topRow
        #expect(savedRow > 240)
        let state = try savedState()

        let tab = HexEditorItem(session: item.session)
        tab.restoreView(state)
        let restoredWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 150),
            styleMask: [.titled], backing: .buffered, defer: false)
        restoredWindow.isReleasedWhenClosed = false
        defer { restoredWindow.close() }
        restoredWindow.contentViewController = tab.controller
        restoredWindow.setContentSize(NSSize(width: 600, height: 150))
        restoredWindow.layoutIfNeeded()
        restoredWindow.contentView?.layoutSubtreeIfNeeded()

        #expect(tab.hexView.topRow == savedRow)
    }
}
