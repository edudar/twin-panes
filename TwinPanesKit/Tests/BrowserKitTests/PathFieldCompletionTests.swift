import AppKit
import Testing

@testable import BrowserKit
@testable import TwinPanesCore

/// Tab in the path field (docs/plans/M5.md, D-e, step 22), driven through its field editor.
@MainActor
@Suite struct PathFieldCompletionTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PathFieldCompletionTests-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
    let item: BrowserItem
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)

    init() async throws {
        let fm = FileManager.default
        for folder in ["Documents", "Downloads", "Music", "prefs"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["Report 1.txt", "Report 2.txt"] {
            try Data([1]).write(to: root.appendingPathComponent(file))
        }
        let grants = FolderGrants(
            defaults: UserDefaults(suiteName: root.appendingPathComponent("prefs/defaults").path)!)
        item = BrowserItem(folder: root, grants: grants) { _, _ in }
        window.isReleasedWhenClosed = false
        window.contentView = item.viewController.view
        await item.listed()
        item.controller.editPath()
    }

    func cleanUp() {
        window.close()
        try? FileManager.default.removeItem(at: root)
    }

    var editor: NSTextView {
        get throws { try #require(item.controller.pathField.currentEditor() as? NSTextView) }
    }

    /// Types `text` into the field and presses Tab, as the field editor reports it.
    func tab(after text: String) async throws -> String {
        let editor = try editor
        editor.string = text
        let handled = item.controller.control(
            item.controller.pathField, textView: editor,
            doCommandBy: #selector(NSResponder.insertTab(_:)))
        #expect(handled, "Tab stays in the field")
        await item.controller.pendingCompletion?.value
        return editor.string
    }

    @Test func aFolderThatsTheOnlyMatchCompletesWithASlash() async throws {
        defer { cleanUp() }
        #expect(try await tab(after: root.path + "/mu") == root.path + "/Music/")
    }

    @Test func severalMatchesCompleteAsFarAsTheyAgree() async throws {
        defer { cleanUp() }
        #expect(try await tab(after: root.path + "/rep") == root.path + "/Report ")
    }

    @Test func aTabThatCompletesNothingMoreOpensTheList() async throws {
        defer { cleanUp() }
        var opened = 0
        item.controller.showCompletionList = { _ in opened += 1 }
        _ = try await tab(after: root.path + "/Do")
        #expect(try await tab(after: root.path + "/Do") == root.path + "/Do")
        #expect(opened == 2)
    }

    @Test func theListOffersTheMatchesForAppKitsLastWord() async throws {
        defer { cleanUp() }
        let editor = try editor
        _ = try await tab(after: root.path + "/Report")
        let text = root.path + "/Report "
        editor.string = text
        var selected = 0
        let whole = (text as NSString).range(of: "Report ", options: .backwards)
        let afterSpace = NSRange(location: NSMaxRange(whole), length: 0)
        for (range, expected) in [
            (whole, ["Report 1.txt", "Report 2.txt"]), (afterSpace, ["1.txt", "2.txt"]),
        ] {
            let offered = item.controller.control(
                item.controller.pathField, textView: editor, completions: [],
                forPartialWordRange: range, indexOfSelectedItem: &selected)
            #expect(offered == expected)
        }
    }

    @Test func textChangedBeforeTheNamesArriveIsLeftAlone() async throws {
        defer { cleanUp() }
        let editor = try editor
        editor.string = root.path + "/mu"
        _ = item.controller.control(
            item.controller.pathField, textView: editor,
            doCommandBy: #selector(NSResponder.insertTab(_:)))
        editor.string = root.path + "/zz"
        await item.controller.pendingCompletion?.value
        #expect(editor.string == root.path + "/zz")
    }

    @Test func textThatIsntAPathKeepsTabInTheField() async throws {
        defer { cleanUp() }
        #expect(try await tab(after: "Music") == "Music")
    }
}
