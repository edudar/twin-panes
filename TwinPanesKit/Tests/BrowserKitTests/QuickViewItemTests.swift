import AppKit
import Testing
import TwinPanesCore
import UniformTypeIdentifiers
import WorkspaceKit

@testable import BrowserKit

@MainActor
@Suite struct QuickViewItemTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuickViewItemTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    final class FakeQuickLookViewer: QuickLookViewing {
        let view = NSView()
        var shown: [URL?] = []
        var closeCount = 0
        var onShow: ((URL?) -> Void)?
        func show(_ url: URL?) {
            shown.append(url)
            onShow?(url)
        }
        func close() { closeCount += 1 }
    }

    @MainActor
    final class FakeHexViewer: HexPreviewing {
        let viewController = NSViewController()
        var showsUnsavedEdits = false
        var onStateChange: (() -> Void)?
        var shown: [URL?] = []
        var currentScope: SecurityScope?
        func show(_ url: URL?, scope: SecurityScope?) {
            shown.append(url)
            currentScope = url == nil ? nil : scope
        }
    }

    @MainActor
    final class FakeHexViewerFactory: HexViewerFactory {
        var requestedStyles: [HexViewerStyle] = []
        var created: [FakeHexViewer] = []
        func makeHexViewer(style: HexViewerStyle) -> any HexPreviewing {
            requestedStyles.append(style)
            let viewer = FakeHexViewer()
            created.append(viewer)
            return viewer
        }
    }

    @MainActor
    final class RecordingHost: WorkspaceHost {
        var messages: [String] = []
        func showStatus(_ message: String) { messages.append(message) }
    }

    private final class ScopeProbe { weak var scope: SecurityScope? }

    private func makeFileEntry(name: String, content: Data) throws -> DirectoryEntry {
        let url = root.appendingPathComponent(name)
        try content.write(to: url)
        return DirectoryEntry(
            url: url, name: name, isDirectory: false, isPackage: false, isSymbolicLink: false,
            isHidden: false, size: UInt64(content.count), modified: nil,
            type: name.hasSuffix(".txt") ? .text : .data)
    }

    private func makeDirEntry(name: String, isPackage: Bool = false) throws -> DirectoryEntry {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return DirectoryEntry(
            url: url, name: name, isDirectory: !isPackage, isPackage: isPackage,
            isSymbolicLink: false, isHidden: false, size: nil, modified: nil,
            type: isPackage ? .package : .folder)
    }

    private func view<T: NSView>(withID id: String, in root: NSView) -> T? {
        if root.accessibilityIdentifier() == id { return root as? T }
        for subview in root.subviews {
            if let match: T = view(withID: id, in: subview) { return match }
        }
        return nil
    }

    private func makeItem(
        factory: FakeHexViewerFactory = FakeHexViewerFactory(),
        sessions: SessionRegistry? = nil,
        isFollowing: Bool = true,
        debounce: Duration = .zero,
        onEdit: @escaping (URL, SecurityScope?) -> Void = { _, _ in }
    ) -> (item: QuickViewItem, quickLook: FakeQuickLookViewer, quickLookCount: () -> Int) {
        let quickLook = FakeQuickLookViewer()
        var creations = 0
        let item = QuickViewItem(
            viewerFactory: factory, sessions: sessions, isFollowing: isFollowing,
            debounce: debounce, onEdit: onEdit,
            makeQuickLook: {
                creations += 1
                return QuickLookHostView(viewer: quickLook)
            }
        )
        return (item, quickLook, { creations })
    }

    @Test func workspaceContractAndHeaderControls() throws {
        defer { cleanUp() }
        let (following, _, _) = makeItem(isFollowing: true)
        defer { following.willClose() }
        let rootView = following.viewController.view

        #expect(following.kind == .quickView)
        #expect(following.preferredSlot == .rightPanel)
        #expect(!following.isDirty)
        #expect(following.restorableState == nil)
        #expect(following.title == "Quick View")
        #expect(following.icon != nil)
        #expect(following.isFollowing && !following.isPinned)
        #expect(rootView.accessibilityIdentifier() == "quickView")

        let scopeProvider = try #require(following.viewController as? CommandScopeProviding)
        #expect(scopeProvider.commandScopes == [.item(.quickView)])
        let pinButton: NSButton = try #require(view(withID: "quickViewPinButton", in: rootView))
        #expect(!pinButton.isHidden)

        let (standalone, _, _) = makeItem(isFollowing: false)
        defer { standalone.willClose() }
        let standalonePin: NSButton = try #require(
            view(withID: "quickViewPinButton", in: standalone.viewController.view))
        #expect(!standalone.isFollowing && standalone.isPinned && standalonePin.isHidden)
    }

    @Test func lazyViewCreationAndZeroSessionCreation() throws {
        defer { cleanUp() }
        let sessions = SessionRegistry()
        let factory = FakeHexViewerFactory()
        let (item, quickLook, qlCount) = makeItem(factory: factory, sessions: sessions)
        let host = RecordingHost()
        item.host = host
        defer { item.willClose() }
        _ = item.viewController.view

        let txt = try makeFileEntry(name: "notes.txt", content: Data("hello".utf8))
        let bin = try makeFileEntry(name: "data.bin", content: Data([0x00, 0xFF, 0x01]))

        item.show(txt, scope: nil)
        #expect(item.activeMode == .quickLook && item.title == "notes.txt")
        #expect(qlCount() == 1 && factory.created.isEmpty && quickLook.shown == [txt.url])
        #expect(host.messages.last?.contains("notes.txt") == true)
        #expect(host.messages.last?.contains("Quick Look") == true)
        #expect(host.messages.last?.contains("Read-only") == true)

        item.retarget(to: bin, scope: nil)
        #expect(item.activeMode == .hex && item.title == "data.bin")
        #expect(factory.requestedStyles == [.regular])
        #expect(factory.created.first?.shown == [bin.url])
        #expect(quickLook.shown == [txt.url, nil])
        #expect(host.messages.last?.contains("data.bin") == true)
        #expect(host.messages.last?.contains("Hex") == true)
        #expect(host.messages.last?.contains("Read-only") == true)
        #expect(sessions.sessions.isEmpty)
    }

    @Test func debouncedRetargetCoalescesRapidCursorMoves() async throws {
        defer { cleanUp() }
        let (item, quickLook, _) = makeItem(debounce: .milliseconds(25))
        defer { item.willClose() }
        _ = item.viewController.view

        let first = try makeFileEntry(name: "first.txt", content: Data("1".utf8))
        let second = try makeFileEntry(name: "second.txt", content: Data("2".utf8))
        let third = try makeFileEntry(name: "third.txt", content: Data("3".utf8))

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            quickLook.onShow = { url in if url == third.url { done.resume() } }
            item.retarget(to: first, scope: nil)
            item.retarget(to: second, scope: nil)
            item.retarget(to: third, scope: nil)
        }
        #expect(quickLook.shown == [third.url] && item.currentURL == third.url)
    }

    @Test func pinningFreezesRetargetingButAllowsExplicitShow() throws {
        defer { cleanUp() }
        let (item, quickLook, _) = makeItem()
        defer { item.willClose() }
        let pinButton: NSButton = try #require(
            view(withID: "quickViewPinButton", in: item.viewController.view))

        let fileA = try makeFileEntry(name: "a.txt", content: Data("a".utf8))
        let fileB = try makeFileEntry(name: "b.txt", content: Data("b".utf8))
        let fileC = try makeFileEntry(name: "c.txt", content: Data("c".utf8))

        item.show(fileA, scope: nil)
        item.pin()
        #expect(item.isPinned && pinButton.state == .on)

        item.retarget(to: fileB, scope: nil)
        #expect(item.currentURL == fileA.url && quickLook.shown == [fileA.url])

        item.show(fileC, scope: nil)
        #expect(item.currentURL == fileC.url && quickLook.shown == [fileA.url, fileC.url])

        pinButton.performClick(nil)
        #expect(!item.isPinned && pinButton.state == .off)
        item.retarget(to: fileB, scope: nil)
        #expect(item.currentURL == fileB.url)
    }

    @Test func modeSwitchingOverridesCurrentFileAndResetsOnNextFile() throws {
        defer { cleanUp() }
        let factory = FakeHexViewerFactory()
        let (item, quickLook, _) = makeItem(factory: factory)
        defer { item.willClose() }
        let modeControl: NSSegmentedControl = try #require(
            view(withID: "quickViewModeControl", in: item.viewController.view))

        let txt1 = try makeFileEntry(name: "one.txt", content: Data("one".utf8))
        let txt2 = try makeFileEntry(name: "two.txt", content: Data("two".utf8))

        item.show(txt1, scope: nil)
        #expect(modeControl.isEnabled && modeControl.selectedSegment == 0)

        modeControl.selectedSegment = 1
        modeControl.sendAction(modeControl.action, to: modeControl.target)
        #expect(item.activeMode == .hex)
        #expect(factory.created.first?.shown == [txt1.url])
        #expect(quickLook.shown == [txt1.url, nil])

        item.retarget(to: txt2, scope: nil)
        #expect(item.activeMode == .quickLook && modeControl.selectedSegment == 0)
        #expect(factory.created.first?.shown == [txt1.url, nil])
        #expect(quickLook.shown == [txt1.url, nil, txt2.url])
    }

    @Test func dirtySessionDefaultsToHexUpdatesLiveAndClearsOnRevertAndClose() throws {
        defer { cleanUp() }
        let sessions = SessionRegistry()
        let factory = FakeHexViewerFactory()
        let (item, quickLook, _) = makeItem(factory: factory, sessions: sessions)
        let host = RecordingHost()
        item.host = host
        defer { item.willClose() }
        let badge: NSView = try #require(
            view(withID: "quickViewUnsavedBadge", in: item.viewController.view))

        let dirtyTxt = try makeFileEntry(name: "dirty.txt", content: Data("abc".utf8))
        let (dirtySession, _) = try sessions.open(dirtyTxt.url)
        let editFirst: (EditorSession) throws -> Void = {
            try $0.overwrite(Data([0x41]), at: 0, selectionBefore: 0..<1, selectionAfter: 1..<1)
        }
        try editFirst(dirtySession)
        item.show(dirtyTxt, scope: nil)
        #expect(item.activeMode == .hex && !badge.isHidden)
        #expect(host.messages.last?.contains("Includes unsaved edits") == true)

        let liveTxt = try makeFileEntry(name: "live.txt", content: Data("hello".utf8))
        item.show(liveTxt, scope: nil)
        #expect(item.activeMode == .quickLook && badge.isHidden)
        let (liveSession, _) = try sessions.open(liveTxt.url)
        #expect(badge.isHidden)
        try editFirst(liveSession)
        #expect(!badge.isHidden && item.activeMode == .hex)
        #expect(host.messages.last?.contains("Includes unsaved edits") == true)

        liveSession.revert()
        #expect(badge.isHidden && item.activeMode == .quickLook)
        #expect(quickLook.shown.last == liveTxt.url)

        try editFirst(liveSession)
        #expect(!badge.isHidden)
        liveSession.close()
        #expect(badge.isHidden && item.activeMode == .quickLook)
    }

    @Test func browserEditValidationAndOnEditInvocation() throws {
        defer { cleanUp() }
        var edited: [(URL, SecurityScope?)] = []
        let (item, _, _) = makeItem { url, scope in edited.append((url, scope)) }
        defer { item.willClose() }
        let rootView = item.viewController.view
        let editButton: NSButton = try #require(view(withID: "quickViewEditButton", in: rootView))
        let modeControl: NSSegmentedControl = try #require(
            view(withID: "quickViewModeControl", in: rootView))
        let validator = try #require(item.viewController as? NSMenuItemValidation)
        let menuItem = NSMenuItem(
            title: "Edit", action: #selector(BrowserActions.browserEdit(_:)), keyEquivalent: "")

        let file = try makeFileEntry(name: "edit.bin", content: Data([1, 2, 3]))
        let folder = try makeDirEntry(name: "folder", isPackage: false)
        let package = try makeDirEntry(name: "App.app", isPackage: true)
        let scope = SecurityScope(url: file.url)

        item.show(file, scope: scope)
        #expect(validator.validateMenuItem(menuItem) && editButton.isEnabled)
        editButton.performClick(nil)
        #expect(edited.count == 1 && edited.first?.0 == file.url && edited.first?.1 === scope)

        for nonFile in [folder, package] {
            item.show(nonFile, scope: nil)
            #expect(!validator.validateMenuItem(menuItem) && !editButton.isEnabled)
            #expect(!modeControl.isEnabled)
            _ = (item.viewController as AnyObject).perform(
                #selector(BrowserActions.browserEdit(_:)), with: nil)
        }
        item.show(nil, scope: nil)
        #expect(!validator.validateMenuItem(menuItem) && !editButton.isEnabled)
        #expect(!modeControl.isEnabled && edited.count == 1)
    }

    @Test func willCloseCancelsPendingDebounceClosesQuickLookClearsHexAndReleasesScope() throws {
        defer { cleanUp() }
        let factory = FakeHexViewerFactory()
        let (item, quickLook, _) = makeItem(factory: factory, debounce: .seconds(5))
        _ = item.viewController.view

        let txt = try makeFileEntry(name: "a.txt", content: Data("a".utf8))
        let bin = try makeFileEntry(name: "b.bin", content: Data([1, 2]))
        let qlProbe = ScopeProbe()
        do {
            let scope = SecurityScope(url: txt.url)
            qlProbe.scope = scope
            item.show(txt, scope: scope)
        }
        #expect(qlProbe.scope != nil)
        item.retarget(to: bin, scope: nil)
        item.willClose()
        #expect(qlProbe.scope == nil && quickLook.closeCount == 1)
        #expect(item.currentURL == nil && factory.created.isEmpty)
        let (hexItem, _, _) = makeItem(factory: factory)
        _ = hexItem.viewController.view
        let hexProbe = ScopeProbe()
        do {
            let scope = SecurityScope(url: bin.url)
            hexProbe.scope = scope
            hexItem.show(bin, scope: scope)
        }
        #expect(hexProbe.scope != nil && factory.created.first?.shown == [bin.url])
        hexItem.willClose()
        #expect(hexProbe.scope == nil && factory.created.first?.shown == [bin.url, nil])
        #expect(factory.created.first?.currentScope == nil)
    }
}
