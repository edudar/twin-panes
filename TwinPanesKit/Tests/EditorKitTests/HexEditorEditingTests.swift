import AppKit
import Foundation
import Testing
import TwinPanesCore
import WorkspaceKit

@testable import EditorKit
@testable import HexViewKit

@MainActor
private final class StatusSpy: WorkspaceHost {
    var messages: [String] = []
    func showStatus(_ message: String) { messages.append(message) }
}

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

    func waitForSearch(_ controller: HexEditorViewController) async {
        guard controller.isSearching else { return }
        let finished = AsyncSignal()
        controller.onSearchFinished = { finished.signal() }
        defer { controller.onSearchFinished = nil }
        await finished.wait()
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
        #expect(item.statusText.hasSuffix(" · Modified"))
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
        #expect(item.canSave)
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
        #expect(item.session.undoStack.undoCount == 2)

        // Switching columns and back within 2 s also breaks the typing burst.
        item.hexView.insertTab(nil)
        item.hexView.insertTab(nil)
        item.hexView.insertText("EF")  // must be step 3
        #expect(item.session.undoStack.undoCount == 3)
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
        #expect(item.session.undoStack.undoCount == 4)
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
        await waitForSearch(controller)
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
        await waitForSearch(controller)
        // Stale pre-edit results must not overwrite the cursor, highlights, or cache.
        #expect(controller.allMatches == nil)
        #expect(item.hexView.highlights.isEmpty)
        #expect(item.hexView.selection.range == 0x31..<0x32)
        #expect(controller.findBar.statusLabel.stringValue.contains("before edit"))

        // A follow-up Find Next searches the edited snapshot (where "30 31" is now gone).
        controller.searchSourceOverride = nil
        controller.find(.forward)
        await waitForSearch(controller)
        #expect(controller.findBar.statusLabel.stringValue == "Not found")
    }

    @Test func inspectorFindAndUnencodableStatusTrackEdits() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem()
        // Warm page 0 in cache so synchronous inspector checks don't race async prefetch.
        _ = try item.read(0..<256)
        let controller = item.controller
        let host = StatusSpy()
        item.host = host
        controller.toggleInspector(nil)

        func uint8Value() -> String? {
            controller.inspector.rows.first { $0.name == "UInt8" }?.value
        }

        // Typing updates the data inspector live; undo and redo update it back.
        item.hexView.go(to: 0x10)
        #expect(uint8Value() == String(0x10))
        item.hexView.insertText("A")  // high nibble: 0x10 -> 0xA0, cursor stays at 0x10
        #expect(uint8Value() == String(0xA0))
        controller.undo(nil)
        #expect(uint8Value() == String(0x10))
        controller.redo(nil)
        #expect(uint8Value() == String(0xA0))

        // Unencodable character in text column reports a status message.
        item.hexView.insertTab(nil)
        item.hexView.insertText("é")
        #expect(host.messages.last?.contains("ASCII") == true)

        // UI Find locates newly typed bytes and stops matching overwritten bytes.
        item.hexView.insertTab(nil)
        item.hexView.go(to: 0x20)
        item.hexView.insertText("DEAD")
        controller.findBar.kind = .hex
        controller.findBar.field.stringValue = "DE AD"
        controller.findAll()
        await waitForSearch(controller)
        #expect(item.hexView.highlights == [0x20..<0x22])

        controller.findBar.field.stringValue = "20 21"
        controller.find(.forward)
        await waitForSearch(controller)
        #expect(controller.findBar.statusLabel.stringValue == "Not found")
    }

    /// A read-only file opens, but typing changes nothing and says why (M3b, D-b).
    @Test func readOnlyTabsRefuseTypingAndSayWhy() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((0..<256).map { UInt8($0) }).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let item = try HexEditorItem(url: url)
        _ = item.controller.view
        let host = StatusSpy()
        item.host = host
        #expect(item.statusText.hasSuffix("Read-only: you don’t have permission to change it"))
        item.hexView.go(to: 0x10)
        item.hexView.insertText("FF")
        #expect(try byte(item, 0x10) == 0x10)
        #expect(!item.isDirty && !item.canUndo && item.hexView.pendingNibble == nil)
        #expect(host.messages.last?.contains("read-only") == true)
    }

    /// Changes that reach the tab from its session, not from its own typing (a revert
    /// today, another view later), refresh it like its own edits do.
    @Test func sessionChangesFromElsewhereRefreshTheTab() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem()
        let host = StatusSpy()
        item.host = host
        var changes = 0
        item.onChange = { changes += 1 }
        item.hexView.highlights = [0x20..<0x22]
        try item.session.overwrite(
            Data([0xEE]), at: 0x20, selectionBefore: 0x20..<0x21, selectionAfter: 0x21..<0x22)
        #expect(changes == 1 && item.hexView.highlights.isEmpty)
        #expect(host.messages.last?.hasSuffix(" · Modified") == true)

        item.hexView.go(to: 0x30)
        item.hexView.insertText("A")  // half a byte typed, then the session reverts
        item.session.revert()
        #expect(!item.isDirty && changes == 3 && item.hexView.pendingNibble == nil)
        #expect(try byte(item, 0x20) == 0x20 && byte(item, 0x30) == 0x30)
        #expect(host.messages.last?.contains("Modified") == false)
        // The next keystroke starts a new step: nothing is left to coalesce with.
        item.hexView.insertText("B")
        #expect(item.session.undoStack.undoCount == 1)
    }

    /// The session reports a keystroke before the hex view moves the cursor; the status
    /// line still updates once per keystroke, with the new cursor.
    @Test func eachKeystrokeUpdatesTheStatusOnce() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem()
        item.hexView.go(to: 0x40)
        let host = StatusSpy()
        item.host = host
        item.hexView.insertText("A")
        item.hexView.insertText("B")
        #expect(host.messages.count == 2)
        #expect(host.messages.last?.hasPrefix("Offset 0x41") == true)
        #expect(!item.controller.applyingTypingEdit)
    }

    @Test func tabsOfOneSessionShareItsKey() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem()
        let other = HexEditorItem(session: item.session)
        #expect(item.sessionKey == other.sessionKey)
        #expect(item.sessionKey == AnyHashable(item.session.id))
        #expect(try HexEditorItem(url: url).sessionKey != item.sessionKey)
    }
}
