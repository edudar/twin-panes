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

    /// Waits until `check` holds after a live update, failing after 10 s.
    func until(
        in item: BrowserItem, _ check: @escaping () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        if check() { return }
        var deadlineTask: Task<Void, Never>?
        defer { deadlineTask?.cancel() }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            item.didUpdate = {
                guard !finished, check() else { return }
                finished = true
                item.didUpdate = nil
                done.resume()
            }
            deadlineTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !finished else { return }
                finished = true
                item.didUpdate = nil
                Issue.record(
                    "no such update within 10 s: \(item.entries.map(\.name))",
                    sourceLocation: sourceLocation)
                done.resume()
            }
        }
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

    @Test func viewAndEditRequireSelectionPathBarAndAccess() async {
        defer { cleanUp() }
        let item = await browser()
        defer { item.willClose() }
        let controller = item.controller
        let viewItem = menuItem(#selector(BrowserViewController.browserView(_:)))
        let editItem = menuItem(#selector(BrowserViewController.browserEdit(_:)))

        select(["a.txt"], in: item)
        #expect(controller.validateMenuItem(viewItem))
        #expect(controller.validateMenuItem(editItem))

        controller.editPath()
        #expect(controller.isEditingPath)
        #expect(!controller.validateMenuItem(viewItem))
        #expect(!controller.validateMenuItem(editItem))

        controller.showPathBar()
        #expect(!controller.isEditingPath)
        #expect(controller.validateMenuItem(viewItem))
        #expect(controller.validateMenuItem(editItem))

        item.received(.failed(.needsAccess(item.folder)))
        #expect(item.needsAccess)
        #expect(controller.selectedEntry != nil)
        #expect(!controller.validateMenuItem(viewItem))
        #expect(!controller.validateMenuItem(editItem))
    }

    @Test func aNewNameIsSelectedOnceListed() async throws {
        defer { cleanUp() }
        let item = await browser()
        defer { item.willClose() }
        item.selectWhenListed("c.txt")
        try Data().write(to: root.appendingPathComponent("folder/c.txt"))
        await until(in: item) { item.selectedName == "c.txt" }
        #expect(item.selectedName == "c.txt")
    }

    @Test func selectWhenListedAlreadyListedSelectsDirectlyAndPreservesPendingLargeSelection()
        async throws
    {
        defer { cleanUp() }
        let item = await browser()
        defer { item.willClose() }
        select(["a.txt"], in: item)
        item.selectWhenListed("b.txt")
        #expect(item.selectedName == "b.txt")
        #expect(item.controller.wantedSelection == nil)

        let big = root.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        let count = FolderListing.mainActorLimit + 10
        for index in 0..<count {
            FileManager.default.createFile(
                atPath: big.appendingPathComponent("f\(index)").path, contents: nil)
        }
        item.go(to: big)
        await item.listed()
        item.controller.tableView.selectAll(nil)
        #expect(item.selectedEntries.count == count)
        item.selectWhenListed("not-there-yet")
        #expect(item.selectedEntries.count == count)
    }

    @Test func applyRowChangesFindsWantedSelectionMissingFromAsked() async throws {
        defer { cleanUp() }
        let item = await browser()
        defer { item.willClose() }
        item.selectWhenListed("c.txt")
        let entry = DirectoryEntry(
            url: root.appendingPathComponent("folder/c.txt"), name: "c.txt", isDirectory: false,
            isPackage: false, isSymbolicLink: false, isHidden: false, size: 0, modified: nil,
            type: .data)
        let previous = item.listing
        let updated = previous.merging([entry])
        item.replaceListing(with: updated)
        let changes = try #require(
            updated.rowChanges(from: previous, touching: ["c.txt"], limit: 100))
        #expect(item.controller.applyRowChanges(changes))
        #expect(item.selectedName == "c.txt")
        #expect(item.controller.wantedSelection == nil)
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
