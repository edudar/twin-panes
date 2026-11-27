import AppKit
import Foundation
import Testing
import TwinPanesCore
import WorkspaceKit

@testable import EditorKit

@MainActor
private final class StatusLog: WorkspaceHost {
    var messages: [String] = []
    func showStatus(_ message: String) { messages.append(message) }
}

/// File › Save, Revert to Saved and the close sheet's Save in the editor tab (M3b step 8).
@MainActor
@Suite(.serialized) struct HexEditorSavingTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("HexEditorSavingTests-\(UUID().uuidString)")
    let url: URL

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("file.bin")
        try Data((0..<256).map { UInt8($0) }).write(to: url)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    fileprivate func makeItem() throws -> (HexEditorItem, StatusLog) {
        let item = try HexEditorItem(url: url)
        _ = item.controller.view
        let log = StatusLog()
        item.host = log
        return (item, log)
    }

    func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    func enabled(_ item: HexEditorItem, _ action: Selector) -> Bool {
        item.controller.validateMenuItem(menuItem(action))
    }

    func disk(_ offset: Int) throws -> UInt8 { try Data(contentsOf: url)[offset] }

    @Test func saveWritesTheFileAndCleansTheTab() async throws {
        defer { cleanUp() }
        let (item, log) = try makeItem()
        var changes = 0
        item.onChange = { changes += 1 }
        let save = #selector(HexEditorViewController.editorSave(_:))
        let revert = #selector(HexEditorViewController.editorRevertToSaved(_:))
        #expect(item.canSave && !enabled(item, save) && !enabled(item, revert))
        item.hexView.go(to: 0x10)
        item.hexView.insertText("AB")
        #expect(item.statusText.hasSuffix(" · Modified"))
        #expect(enabled(item, save) && enabled(item, revert))
        let before = changes

        await item.controller.saveShowingErrors()
        #expect(try disk(0x10) == 0xAB && !item.isDirty)
        #expect(log.messages.contains { $0.hasSuffix(" · Saving…") })
        #expect(!item.statusText.contains("Modified") && !item.statusText.contains("Saving"))
        #expect(changes > before && !enabled(item, save))
        // Undo after a save is an unsaved change again, and saving it restores the file.
        item.controller.undo(nil)
        #expect(item.isDirty)
        try await item.save()  // what the close sheet's Save calls
        #expect(try disk(0x10) == 0x10 && !item.isDirty)
    }

    @Test func aFailedSaveKeepsTheEditsAndSaysWhy() async throws {
        defer { cleanUp() }
        try FileManager.default.linkItem(at: url, to: folder.appendingPathComponent("link"))
        let (item, log) = try makeItem()
        item.hexView.insertText("FF")
        await item.controller.saveShowingErrors()
        #expect(try item.isDirty && disk(0) == 0)
        #expect(log.messages.last?.contains("hard links") == true)
        #expect(item.statusText.hasSuffix(" · Modified"))
    }

    @Test func revertAsksFirst() async throws {
        defer { cleanUp() }
        let (item, _) = try makeItem()
        item.hexView.insertText("FF")
        @MainActor final class RevertPrompt {
            var asked: [String] = []
            var allow = false
        }
        let prompt = RevertPrompt()
        item.controller.confirmRevert = { _, title in
            prompt.asked.append(title)
            return prompt.allow
        }
        await item.controller.revertToSaved()
        #expect(prompt.asked == ["file.bin"] && item.isDirty)
        prompt.allow = true
        await item.controller.revertToSaved()
        #expect(try !item.isDirty && !item.canUndo && item.read(0..<1) == Data([0]))
    }

    @Test func saveSelectionWritesRangeOffMainThreadAndReportsErrors() async throws {
        defer { cleanUp() }
        let (item, log) = try makeItem()
        item.hexView.insertText("AB")
        let out = folder.appendingPathComponent("selection.bin")
        await withCheckedContinuation { continuation in
            item.controller.writeSelection(0..<4, of: item, to: out) {
                continuation.resume()
            }
        }
        #expect(try Data(contentsOf: out) == Data([0xAB, 1, 2, 3]))
        #expect(log.messages.last == "Saved 4 bytes to selection.bin")

        let badOut = folder.appendingPathComponent("missing-dir/selection.bin")
        await withCheckedContinuation { continuation in
            item.controller.writeSelection(0..<4, of: item, to: badOut) {
                continuation.resume()
            }
        }
        #expect(log.messages.last?.hasPrefix("Saving failed: ") == true)
        #expect(!FileManager.default.fileExists(atPath: badOut.path))
    }

    /// Save As: the tab takes the new file's name, tells the app (recents), and a failure
    /// leaves it where it was and says why.
    @Test func saveAsMovesTheTabToTheNewFile() async throws {
        defer { cleanUp() }
        let (item, log) = try makeItem()
        var noted: [URL] = []
        var changes = 0
        item.didSaveAs = { noted.append($0) }
        item.onChange = { changes += 1 }
        item.hexView.insertText("FF")
        let copy = folder.appendingPathComponent("copy.bin")
        await item.controller.saveAsShowingErrors(to: copy)
        #expect(item.title == "copy.bin" && item.url == copy && !item.isDirty)
        #expect(noted == [copy] && changes > 1)
        #expect(try Data(contentsOf: copy)[0] == 0xFF && disk(0) == 0)

        let nowhere = folder.appendingPathComponent("missing/x.bin")
        await item.controller.saveAsShowingErrors(to: nowhere)
        #expect(item.url == copy && noted == [copy])
        #expect(log.messages.last?.hasPrefix("Couldn't save “x.bin”") == true)
    }

    /// Closing the tab ends its session: the folder with the clone goes (M3c).
    @Test func closingTheTabDeletesTheSessionFolder() throws {
        defer { cleanUp() }
        let root = folder.appendingPathComponent("Sessions")
        let item = HexEditorItem(session: try EditorSession(url: url, sessionsRoot: root))
        _ = item.controller.view
        item.hexView.insertText("FF")
        let made = try #require(item.session.folder)
        item.willClose()
        #expect(!FileManager.default.fileExists(atPath: made.url.path))
        #expect(SessionFolder.sweep(root).isEmpty)
    }

    /// The file changes on disk under unsaved edits: the tab asks; Keep Mine keeps the
    /// edits and says so, Reload drops them for the file on disk (M3c).
    @Test(arguments: [true, false])
    func anOutsideChangeAsks(keepMine: Bool) async throws {
        defer { cleanUp() }
        let session = try EditorSession(
            url: url, sessionsRoot: folder.appendingPathComponent("Sessions"))
        session.startWatching()
        let item = HexEditorItem(session: session)
        defer { item.willClose() }
        _ = item.controller.view
        let asked = AsyncSignal(), reloaded = AsyncSignal()
        final class Owner {}
        let owner = Owner()
        defer { withExtendedLifetime(owner) {} }
        item.controller.askAboutOutsideChange = { _, title in
            #expect(title == "file.bin")
            asked.signal()
            return keepMine ? .keepMine : .reload
        }
        item.hexView.insertText("FF")
        session.observe(owner) { if $0 == .edited { reloaded.signal() } }
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(repeating: 0x22, count: 256))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
        await asked.wait()
        if keepMine {
            #expect(try item.isDirty && item.read(0..<2) == Data([0xFF, 1]))
            #expect(item.statusText.hasSuffix("Modified · Changed on disk"))
        } else {
            await reloaded.wait()
            #expect(try !item.isDirty && item.read(0..<2) == Data([0x22, 0x22]))
            #expect(!item.statusText.contains("Changed on disk"))
        }
    }

    @Test func readOnlyTabsCantSave() throws {
        defer { cleanUp() }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let (item, _) = try makeItem()
        #expect(!item.canSave)
        #expect(!enabled(item, #selector(HexEditorViewController.editorSave(_:))))
    }

    @Test func undoAndRedoNameWhatTheyDo() throws {
        defer { cleanUp() }
        let (item, _) = try makeItem()
        let undo = menuItem(#selector(HexEditorViewController.undo(_:)))
        let redo = menuItem(#selector(HexEditorViewController.redo(_:)))
        #expect(!item.controller.validateMenuItem(undo) && undo.title == "Undo")
        item.hexView.insertText("FF")
        #expect(item.controller.validateMenuItem(undo) && undo.title == "Undo Typing")
        item.controller.undo(nil)
        #expect(item.controller.validateMenuItem(redo) && redo.title == "Redo Typing")
        #expect(!item.controller.validateMenuItem(undo) && undo.title == "Undo")
    }
}
