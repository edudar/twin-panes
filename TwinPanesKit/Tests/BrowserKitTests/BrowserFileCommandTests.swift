import AppKit
import Testing
import TwinPanesCore

@testable import BrowserKit

/// F2 to ⇧F8 and undo reach the app's handler (docs/plans/M6.md, step 16).
@MainActor
@Suite struct BrowserFileCommandTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrowserFileCommandTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let grants: FolderGrants
    let handler = RecordingHandler()

    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt"] {
            try Data().write(to: root.appendingPathComponent("folder/\(name)"))
        }
        grants = FolderGrants(
            defaults: UserDefaults(suiteName: root.appendingPathComponent("defaults").path)!)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func browser() async -> BrowserItem {
        let item = BrowserItem(folder: root.appendingPathComponent("folder"), grants: grants) {
            _, _ in
        }
        item.fileCommands = handler
        _ = item.viewController.view
        await item.listed()
        return item
    }

    func select(_ names: [String], in item: BrowserItem) {
        let rows = names.compactMap { item.controller.row(named: $0) }
        item.controller.tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    @Test func commandsOnTheSelectionReachTheHandler() async {
        defer { cleanUp() }
        let item = await browser()
        defer { item.willClose() }
        select(["a.txt", "b.txt"], in: item)
        item.controller.browserCopyToOtherPanel(nil)
        item.controller.browserTrash(nil)
        #expect(handler.performed == [.copyToOtherPanel, .trash])
    }

    @Test func nothingSelectedSendsNothingButNewFolderAndUndo() async {
        defer { cleanUp() }
        let item = await browser()
        defer { item.willClose() }
        item.controller.tableView.selectRowIndexes([0], byExtendingSelection: false)
        #expect(
            !item.controller.validateMenuItem(
                menuItem(#selector(BrowserViewController.browserTrash(_:)))))
        item.controller.browserTrash(nil)
        item.controller.browserNewFolder(nil)
        item.controller.undo(nil)
        #expect(handler.performed == [.newFolder, .undo])
    }

    @Test func renameTakesExactlyOneItem() async {
        defer { cleanUp() }
        let item = await browser()
        defer { item.willClose() }
        let rename = menuItem(#selector(BrowserViewController.browserRename(_:)))
        select(["a.txt", "b.txt"], in: item)
        #expect(!item.controller.validateMenuItem(rename))
        select(["a.txt"], in: item)
        #expect(item.controller.validateMenuItem(rename))
    }

    @Test func theHandlerHasTheLastWordAndTheTitle() async {
        defer { cleanUp() }
        let item = await browser()
        defer { item.willClose() }
        handler.allows = false
        let undo = menuItem(#selector(BrowserViewController.undo(_:)))
        #expect(!item.controller.validateMenuItem(undo))
        #expect(undo.title == "Undo Copy")
    }

    @Test func aNewNameIsSelectedOnceListed() async throws {
        defer { cleanUp() }
        let item = await browser()
        defer { item.willClose() }
        item.selectWhenListed("c.txt")
        try Data().write(to: root.appendingPathComponent("folder/c.txt"))
        for _ in 0..<200 where item.selectedName != "c.txt" {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(item.selectedName == "c.txt")
    }
}

@MainActor
final class RecordingHandler: FileCommandHandling {
    var performed: [FileCommand] = []
    var allows = true

    func perform(_ command: FileCommand, in browser: BrowserItem) { performed.append(command) }

    func validate(_ command: FileCommand, in browser: BrowserItem, menuItem: NSMenuItem) -> Bool {
        if command == .undo { menuItem.title = "Undo Copy" }
        return allows
    }
}
