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
        item.controller.showCompletionList = { _, _ in opened += 1 }
        _ = try await tab(after: root.path + "/Do")
        #expect(try await tab(after: root.path + "/Do") == root.path + "/Do")
        #expect(opened == 2)
    }

    @Test func theListOffersEachMatchAsTheWholePath() async throws {
        defer { cleanUp() }
        var listed: [String] = []
        item.controller.showCompletionList = { texts, _ in listed = texts }
        let completed = try await tab(after: root.path + "/rep")
        _ = try await tab(after: completed)
        #expect(listed == [root.path + "/Report 1.txt", root.path + "/Report 2.txt"])
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
        item.controller.showCompletionList = { _, _ in opened += 1 }
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
        item.controller.showCompletionList = { _, _ in opened += 1 }
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

    @Test func theListIsCappedAt500WhileThePrefixStillUsesAllMatches() async throws {
        defer { cleanUp() }
        item.controller.completionNames = CompletionNames { _ in
            (0..<1000).map {
                PathCompletion.Candidate(
                    name: String(format: "Item-%04d.txt", $0), isFolder: false)
            }
        }
        var listed: [String]?
        item.controller.showCompletionList = { texts, _ in listed = texts }
        #expect(try await tab(after: root.path + "/item") == root.path + "/Item-0")
        #expect(listed == nil)
        _ = try await tab(after: root.path + "/Item-0")
        #expect(listed?.count == 500)
        #expect(listed?.first == root.path + "/Item-0000.txt")
    }

    @Test func twoTabFlowCompletesSharedPrefixThenOpensList() async throws {
        defer { cleanUp() }
        var opened = 0
        item.controller.showCompletionList = { _, _ in opened += 1 }
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
        var listed: [String] = []
        item.controller.showCompletionList = { texts, _ in listed = texts }
        #expect(try await tab(after: root.path + "/caf") == root.path + "/Café ")
        _ = try await tab(after: root.path + "/Café ")
        #expect(listed == [root.path + "/Café 1.txt", root.path + "/Cafe\u{0301} 2.txt"])
    }
}
