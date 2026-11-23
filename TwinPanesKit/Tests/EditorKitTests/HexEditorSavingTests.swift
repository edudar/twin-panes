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
        var asked: [String] = []
        var answer = false
        item.controller.confirmRevert = { _, title in
            asked.append(title)
            return answer
        }
        await item.controller.revertToSaved()
        #expect(asked == ["file.bin"] && item.isDirty)
        answer = true
        await item.controller.revertToSaved()
        #expect(try !item.isDirty && !item.canUndo && item.read(0..<1) == Data([0]))
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
