import AppKit
import Foundation
import HexViewKit
import Testing
import TwinPanesCore

@testable import EditorKit

@MainActor
@Suite(.serialized) struct HexEditorEditingTests {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("HexEditorEditingTests-\(UUID().uuidString).bin")

    func makeItem() throws -> HexEditorItem {
        try Data((0..<256).map { UInt8($0) }).write(to: url)
        let item = try HexEditorItem(url: url)
        _ = item.controller.view
        return item
    }

    func byte(_ item: HexEditorItem, _ offset: UInt64) throws -> UInt8 {
        try #require(try item.read(offset..<(offset + 1)).first)
    }

    func waitForSearch(_ controller: HexEditorViewController) async throws {
        for _ in 0..<400 where controller.isSearching {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func typingEditsMarksDirtyAndUndoes() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem()
        var changes = 0
        item.onChange = { changes += 1 }
        #expect(!item.isDirty && !item.canUndo)
        item.hexView.go(to: 0x10)
        item.hexView.insertText("ABCD")
        #expect(try byte(item, 0x10) == 0xAB && byte(item, 0x11) == 0xCD)
        #expect(item.isDirty && changes > 0)
        #expect(item.statusText.hasSuffix("Modified (saving comes in M3b)"))
        #expect(item.modifiedRanges(in: 0..<256) == [0x10..<0x12])
        // One burst of typing is one undo step, which restores bytes and cursor.
        item.controller.undo(nil)
        #expect(try byte(item, 0x10) == 0x10 && byte(item, 0x11) == 0x11)
        #expect(item.hexView.selection.cursor == 0x10)
        #expect(!item.isDirty && !item.statusText.contains("Modified"))
        item.controller.redo(nil)
        #expect(try byte(item, 0x11) == 0xCD)
        #expect(item.hexView.selection.cursor == 0x12)
    }

    @Test func discardingDropsEditsAndHistory() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem()
        #expect(!item.canSave)
        item.hexView.insertText("F")  // leaves pending high nibble at offset 0
        item.hexView.highlights = [0..<2]
        item.discardChanges()
        #expect(!item.isDirty && !item.canUndo)
        #expect(try byte(item, 0) == 0)
        #expect(item.hexView.highlights.isEmpty)
        // Pending nibble must be cleared, so typing "1" sets the high nibble (0x10), not low (0x01).
        item.hexView.insertText("1")
        #expect(try byte(item, 0) == 0x10)
        #expect(item.hexView.selection.cursor == 0)
    }

    @Test func navigatingAwayAndBackOrDoubleTabBreaksUndoCoalescing() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem()
        item.hexView.go(to: 0x10)
        item.hexView.insertText("AB")  // step 1, cursor now at 0x11
        item.hexView.moveRight(nil)  // 0x12
        item.hexView.moveLeft(nil)  // back to 0x11 within 2 s
        item.hexView.insertText("CD")  // must be step 2
        #expect(item.undoStack.undoCount == 2)

        // Switching columns and back within 2 s also breaks the typing burst.
        item.hexView.insertTab(nil)
        item.hexView.insertTab(nil)
        item.hexView.insertText("EF")  // must be step 3
        #expect(item.undoStack.undoCount == 3)
    }

    @Test func pausesMovesAndColumnSwitchesStartNewUndoSteps() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem()
        let start = ContinuousClock.now
        func type(_ offset: UInt64, _ column: HexLayout.Column, after seconds: Int) {
            _ = item.overwrite(
                Data([0xEE]), at: offset, column: column, selectionBefore: offset..<(offset + 1),
                cursorAfter: offset + 1, now: start + .seconds(seconds))
        }
        type(0, .hex, after: 0)
        type(1, .hex, after: 1)  // continues: same step
        type(2, .hex, after: 4)  // after a pause: new step
        type(3, .text, after: 4)  // other column: new step
        type(9, .text, after: 4)  // somewhere else: new step
        #expect(item.undoStack.undoCount == 4)
    }

    @Test func undoAndRedoMenuItemsFollowTheHistory() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem()
        let undo = NSMenuItem(
            title: "Undo", action: #selector(HexEditorViewController.undo(_:)), keyEquivalent: "")
        let redo = NSMenuItem(
            title: "Redo", action: #selector(HexEditorViewController.redo(_:)), keyEquivalent: "")
        #expect(!item.controller.validateMenuItem(undo) && !item.controller.validateMenuItem(redo))
        item.hexView.insertText("1")
        #expect(item.controller.validateMenuItem(undo))
        item.controller.undo(nil)
        #expect(item.controller.validateMenuItem(redo))
    }

    @Test func editingClearsFindResults() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem()
        let controller = item.controller
        controller.findBar.kind = .hex
        controller.findBar.field.stringValue = "20"
        controller.findAll()
        try await waitForSearch(controller)
        #expect(item.hexView.highlights == [0x20..<0x21])
        item.hexView.go(to: 0x40)
        item.hexView.insertText("0")
        #expect(item.hexView.highlights.isEmpty)
        #expect(controller.allMatches == nil && controller.lastMatch == nil)
    }

    /// Done-when for M3a: an edit doesn't wait for a running search; the search reports
    /// the pre-edit snapshot without hijacking the cursor or poisoning later Find Next.
    @Test func editsDoNotWaitForARunningSearch() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem()
        let controller = item.controller
        let gated = GatedBytes(wrapping: item.snapshot)
        controller.searchSourceOverride = gated
        controller.findBar.kind = .hex
        controller.findBar.field.stringValue = "30 31"
        controller.findAll()
        await gated.waitUntilStarted()

        item.hexView.go(to: 0x30)
        item.hexView.insertText("FF")
        #expect(try byte(item, 0x30) == 0xFF)
        #expect(item.hexView.selection.cursor == 0x31)
        #expect(controller.isSearching)

        gated.release()
        await gated.waitUntilFinished()
        try await waitForSearch(controller)
        // Stale pre-edit results must not overwrite the cursor, highlights, or cache.
        #expect(controller.allMatches == nil)
        #expect(item.hexView.highlights.isEmpty)
        #expect(item.hexView.selection.range == 0x31..<0x32)
        #expect(controller.findBar.statusLabel.stringValue.contains("before edit"))

        // A follow-up Find Next searches the edited snapshot (where "30 31" is now gone).
        controller.searchSourceOverride = nil
        controller.find(.forward)
        try await waitForSearch(controller)
        #expect(controller.findBar.statusLabel.stringValue == "Not found")
    }
}
