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

    @Test func escapeWhilePendingCancelsWithoutMutatingOrOpeningList() async throws {
        defer { cleanUp() }
        let release = DispatchSemaphore(value: 0)
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        item.controller.completionNames = CompletionNames { _ in
            startedContinuation.yield()
            release.wait()
            return [.init(name: "Music", isFolder: true)]
        }
        var opened = 0
        item.controller.showCompletionList = { _ in opened += 1 }
        let editor = try editor
        let initial = root.path + "/mu"
        editor.string = initial
        _ = item.controller.control(
            item.controller.pathField, textView: editor,
            doCommandBy: #selector(NSResponder.insertTab(_:)))
        for await _ in started { break }
        let inFlight = item.controller.pendingCompletion
        let cancelled = item.controller.control(
            item.controller.pathField, textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(cancelled)
        release.signal()
        await inFlight?.value
        #expect(editor.string == initial)
        #expect(opened == 0)
        #expect(item.controller.lastCompletion == nil)
        #expect(item.controller.pendingCompletion == nil)
    }

    @Test func rapidDoubleTabCancelsFirstTaskWithoutDuplicateApply() async throws {
        defer { cleanUp() }
        let release = DispatchSemaphore(value: 0)
        item.controller.completionNames = CompletionNames { _ in
            release.wait()
            return [
                .init(name: "Documents", isFolder: true),
                .init(name: "Downloads", isFolder: true),
            ]
        }
        var opened = 0
        item.controller.showCompletionList = { _ in opened += 1 }
        let editor = try editor
        editor.string = root.path + "/Do"
        _ = item.controller.control(
            item.controller.pathField, textView: editor,
            doCommandBy: #selector(NSResponder.insertTab(_:)))
        let first = item.controller.pendingCompletion
        _ = item.controller.control(
            item.controller.pathField, textView: editor,
            doCommandBy: #selector(NSResponder.insertTab(_:)))
        let second = item.controller.pendingCompletion
        #expect(first?.isCancelled == true)
        #expect(second != nil)
        release.signal()
        await first?.value
        await second?.value
        #expect(opened == 1)
        #expect(item.controller.pendingCompletion == nil)
    }

    @Test func popupCompletionsAreCappedAt500WhilePrefixStillUsesAllMatches() async throws {
        defer { cleanUp() }
        item.controller.completionNames = CompletionNames { _ in
            (0..<1000).map {
                PathCompletion.Candidate(
                    name: String(format: "Item-%04d.txt", $0), isFolder: false)
            }
        }
        var opened = 0
        item.controller.showCompletionList = { _ in opened += 1 }
        #expect(try await tab(after: root.path + "/item") == root.path + "/Item-")
        #expect(opened == 0)
        let editor = try editor
        _ = try await tab(after: editor.string)
        #expect(opened == 1)
        var selected = 0
        let range = (editor.string as NSString).range(of: "Item-", options: .backwards)
        let offered = item.controller.control(
            item.controller.pathField, textView: editor, completions: [],
            forPartialWordRange: range, indexOfSelectedItem: &selected)
        #expect(offered.count == 500)
        #expect(offered.first == "Item-0000.txt")
    }

    @Test func twoTabFlowCompletesSharedPrefixThenOpensList() async throws {
        defer { cleanUp() }
        var opened = 0
        item.controller.showCompletionList = { _ in opened += 1 }
        let afterFirst = try await tab(after: root.path + "/d")
        #expect(afterFirst == root.path + "/Do")
        #expect(opened == 0)
        let editor = try editor
        _ = item.controller.control(
            item.controller.pathField, textView: editor,
            doCommandBy: #selector(NSResponder.insertTab(_:)))
        await item.controller.pendingCompletion?.value
        #expect(editor.string == root.path + "/Do")
        #expect(opened == 1)
    }

    @Test func completionsReturnEmptyWhenNoSlashOrStale() async throws {
        defer { cleanUp() }
        let editor = try editor
        _ = try await tab(after: root.path + "/Do")
        var selected = 0

        editor.string = "noSlash"
        let noSlash = item.controller.control(
            item.controller.pathField, textView: editor, completions: [],
            forPartialWordRange: NSRange(location: 0, length: 7),
            indexOfSelectedItem: &selected)
        #expect(noSlash.isEmpty)

        editor.string = root.path + "/Mu"
        let muStart = (editor.string as NSString).length - 2
        let stale = item.controller.control(
            item.controller.pathField, textView: editor, completions: [],
            forPartialWordRange: NSRange(location: muStart, length: 2),
            indexOfSelectedItem: &selected)
        #expect(stale.isEmpty)
    }

    @Test func midStringCaretMovesToEndBeforeOpeningList() async throws {
        defer { cleanUp() }
        var caretWhenOpened: NSRange?
        item.controller.showCompletionList = { caretWhenOpened = $0.selectedRange }
        let editor = try editor
        let text = root.path + "/Do"
        editor.string = text
        editor.selectedRange = NSRange(location: 2, length: 0)
        _ = item.controller.control(
            item.controller.pathField, textView: editor,
            doCommandBy: #selector(NSResponder.insertTab(_:)))
        await item.controller.pendingCompletion?.value
        #expect(caretWhenOpened == NSRange(location: (text as NSString).length, length: 0))
    }

    @Test func tildeExpandsToHomeFolderNames() async throws {
        defer { cleanUp() }
        let home = DirectoryReader.realHomeDirectory.standardizedFileURL
        item.controller.completionNames = CompletionNames { url in
            url.standardizedFileURL == home ? [.init(name: "Projects", isFolder: true)] : []
        }
        #expect(try await tab(after: "~") == "~/Projects/")
    }

    @Test func unicodeAndSpaceFilenamesSliceSafelyPastSpace() async throws {
        defer { cleanUp() }
        item.controller.completionNames = CompletionNames { _ in
            [
                .init(name: "Café 1.txt", isFolder: false),
                .init(name: "Cafe\u{0301} 2.txt", isFolder: false),
            ]
        }
        #expect(try await tab(after: root.path + "/caf") == root.path + "/Café ")
        let editor = try editor
        var selected = 0
        let end = (editor.string as NSString).length
        let offered = item.controller.control(
            item.controller.pathField, textView: editor, completions: [],
            forPartialWordRange: NSRange(location: end, length: 0),
            indexOfSelectedItem: &selected)
        #expect(offered == ["1.txt", "2.txt"])
    }
}
