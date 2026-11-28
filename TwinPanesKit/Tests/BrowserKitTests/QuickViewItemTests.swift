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
    final class ResponderViewController: NSViewController {
        final class ResponderView: NSView { override var acceptsFirstResponder: Bool { true } }
        override func loadView() { view = ResponderView() }
    }

    @MainActor
    final class FakeHexViewer: HexPreviewing {
        let viewController: NSViewController = ResponderViewController()
        var showsUnsavedEdits = false
        var onStateChange: (() -> Void)?
        var shown: [URL?] = []
        var currentScope: SecurityScope?
        func show(_ url: URL?, scope: SecurityScope?) {
            shown.append(url)
            currentScope = url == nil ? nil : scope
        }
    }

    struct FakeCloudDownloads: CloudDownloads {
        let datalessURLs: Set<URL>
        func isDataless(_ url: URL) -> Bool { datalessURLs.contains(url.standardizedFileURL) }
        func startDownload(_ url: URL) throws {}
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

    private final class ControllerProbe { weak var controller: StructuredTextViewController? }
    private final class ScopeProbe { weak var scope: SecurityScope? }

    private func makeFileEntry(name: String, content: Data) throws -> DirectoryEntry {
        let url = root.appendingPathComponent(name)
        try content.write(to: url)
        return DirectoryEntry(
            url: url, name: name, isDirectory: false, isPackage: false, isSymbolicLink: false,
            isHidden: false, size: UInt64(content.count), modified: nil,
            type: name.hasSuffix(".txt") ? .text : name.hasSuffix(".png") ? .png : .data)
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
        cloudDownloads: any CloudDownloads = RealCloudDownloads(),
        formatOverrides: PreviewFormatOverrides? = nil,
        onEdit: @escaping (URL, SecurityScope?) -> Void = { _, _ in }
    ) -> (item: QuickViewItem, quickLook: FakeQuickLookViewer, quickLookCount: () -> Int) {
        let quickLook = FakeQuickLookViewer()
        var creations = 0
        let item = QuickViewItem(
            viewerFactory: factory, sessions: sessions, isFollowing: isFollowing,
            debounce: debounce, cloudDownloads: cloudDownloads,
            formatOverrides: formatOverrides ?? makeOverrides(), onEdit: onEdit,
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

        let txt = try makeFileEntry(name: "notes.png", content: Data("hello".utf8))
        let bin = try makeFileEntry(name: "data.bin", content: Data([0x00, 0xFF, 0x01]))

        item.show(txt, scope: nil)
        #expect(item.activeMode == .preview && item.title == "notes.png")
        #expect(qlCount() == 1 && factory.created.isEmpty && quickLook.shown == [txt.url])
        #expect(host.messages.last?.contains("notes.png") == true)
        #expect(host.messages.last?.contains("Preview") == true)
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

        let first = try makeFileEntry(name: "first.png", content: Data("1".utf8))
        let second = try makeFileEntry(name: "second.png", content: Data("2".utf8))
        let third = try makeFileEntry(name: "third.png", content: Data("3".utf8))

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

        let fileA = try makeFileEntry(name: "a.png", content: Data("a".utf8))
        let fileB = try makeFileEntry(name: "b.png", content: Data("b".utf8))
        let fileC = try makeFileEntry(name: "c.png", content: Data("c".utf8))

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

        let txt1 = try makeFileEntry(name: "one.png", content: Data("one".utf8))
        let txt2 = try makeFileEntry(name: "two.png", content: Data("two".utf8))

        item.show(txt1, scope: nil)
        #expect(modeControl.isEnabled && modeControl.selectedSegment == 0)

        modeControl.selectedSegment = 1
        modeControl.sendAction(modeControl.action, to: modeControl.target)
        #expect(item.activeMode == .hex)
        #expect(factory.created.first?.shown == [txt1.url])
        #expect(quickLook.shown == [txt1.url, nil])

        item.retarget(to: txt2, scope: nil)
        #expect(item.activeMode == .preview && modeControl.selectedSegment == 0)
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

        let dirtyTxt = try makeFileEntry(name: "dirty.png", content: Data("abc".utf8))
        let (dirtySession, _) = try sessions.open(dirtyTxt.url)
        let editFirst: (EditorSession) throws -> Void = {
            try $0.overwrite(Data([0x41]), at: 0, selectionBefore: 0..<1, selectionAfter: 1..<1)
        }
        try editFirst(dirtySession)
        item.show(dirtyTxt, scope: nil)
        #expect(item.activeMode == .hex && !badge.isHidden)
        #expect(host.messages.last?.contains("Includes unsaved edits") == true)

        let liveTxt = try makeFileEntry(name: "live.png", content: Data("hello".utf8))
        item.show(liveTxt, scope: nil)
        #expect(item.activeMode == .preview && badge.isHidden)
        let (liveSession, _) = try sessions.open(liveTxt.url)
        #expect(badge.isHidden && item.activeMode == .preview)
        try editFirst(liveSession)
        #expect(!badge.isHidden && item.activeMode == .hex)
        #expect(host.messages.last?.contains("Includes unsaved edits") == true)

        liveSession.revert()
        #expect(badge.isHidden && item.activeMode == .preview)
        #expect(quickLook.shown.last == liveTxt.url)

        try editFirst(liveSession)
        #expect(!badge.isHidden)
        liveSession.close()
        #expect(badge.isHidden && item.activeMode == .preview)
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

        let txt = try makeFileEntry(name: "a.png", content: Data("a".utf8))
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
        #expect(factory.created.first?.onStateChange == nil)
    }

    @Test func datalessFileShowsPlaceholderWithoutCallingQuickLook() throws {
        defer { cleanUp() }
        let file = try makeFileEntry(name: "cloud.png", content: Data("x".utf8))
        let factory = FakeHexViewerFactory()
        let (item, quickLook, _) = makeItem(
            factory: factory,
            cloudDownloads: FakeCloudDownloads(datalessURLs: [file.url.standardizedFileURL]))
        defer { item.willClose() }
        let rootView = item.viewController.view
        let modeControl: NSSegmentedControl = try #require(
            view(withID: "quickViewModeControl", in: rootView))

        item.show(file, scope: nil)
        #expect(item.activeMode == .preview && item.isDataless)
        #expect(quickLook.shown.isEmpty)
        let labels = rootView.subviews.flatMap { allTextFields(in: $0) }.map(\.stringValue)
        #expect(labels.contains("In iCloud — not downloaded"))

        #expect(modeControl.isHidden && factory.created.isEmpty)
    }

    @Test func detachFromSourceHidesKeepButtonAndIgnoresRetarget() throws {
        defer { cleanUp() }
        let (item, quickLook, _) = makeItem(isFollowing: true)
        defer { item.willClose() }
        let pinButton: NSButton = try #require(
            view(withID: "quickViewPinButton", in: item.viewController.view))
        let fileA = try makeFileEntry(name: "a.png", content: Data("a".utf8))
        let fileB = try makeFileEntry(name: "b.png", content: Data("b".utf8))

        item.show(fileA, scope: nil)
        item.detachFromSource()
        #expect(!item.isFollowing && item.isPinned && pinButton.isHidden)

        item.retarget(to: fileB, scope: nil)
        #expect(item.currentURL == fileA.url && quickLook.shown == [fileA.url])
    }

    @Test func brokenSymlinkShowsPlaceholderDisablesEditAndSkipsHiddenHexResponder() throws {
        defer { cleanUp() }
        let factory = FakeHexViewerFactory()
        let (item, quickLook, _) = makeItem(factory: factory)
        defer { item.willClose() }
        let rootView = item.viewController.view
        let editButton: NSButton = try #require(view(withID: "quickViewEditButton", in: rootView))
        let modeControl: NSSegmentedControl = try #require(
            view(withID: "quickViewModeControl", in: rootView))

        let bin = try makeFileEntry(name: "data.bin", content: Data([1, 2]))
        item.show(bin, scope: nil)
        #expect(item.preferredFirstResponder === factory.created.first?.viewController.view)

        let linkURL = root.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path, withDestinationPath: "/nonexistent/target")
        let broken = DirectoryEntry(
            url: linkURL, name: "broken", isDirectory: false, isPackage: false,
            isSymbolicLink: true, isHidden: false, size: nil, modified: nil, type: .symbolicLink)
        item.show(broken, scope: nil)

        #expect(!editButton.isEnabled && !modeControl.isEnabled)
        #expect(quickLook.shown.isEmpty)
        #expect(item.preferredFirstResponder === rootView)
        let labels = rootView.subviews.flatMap { allTextFields(in: $0) }.map(\.stringValue)
        #expect(labels.contains("Broken symbolic link — target not found"))
    }

    @Test func layoutKeepsHeaderDividerHorizontalAndGivesBodyRealHeight() throws {
        defer { cleanUp() }
        let (item, quickLook, _) = makeItem()
        defer { item.willClose() }
        let txt = try makeFileEntry(name: "LICENSE.png", content: Data("Apache License".utf8))
        item.show(txt, scope: nil)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = item.viewController
        window.setContentSize(NSSize(width: 320, height: 500))
        window.layoutIfNeeded()

        let rootView = item.viewController.view
        let divider = try #require(
            rootView.subviews.compactMap { $0 as? NSBox }.first { $0.boxType == .separator })
        #expect(divider.alignmentRect(forFrame: divider.frame).height == 1)
        #expect(divider.frame.width == 320)
        #expect(quickLook.view.frame.width == 320)
        #expect(quickLook.view.frame.height > 400)
    }

    private func makeOverrides() -> PreviewFormatOverrides {
        let suite = root.appendingPathComponent("defaults.plist").path
        return PreviewFormatOverrides(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    /// Runs `action` and suspends until the structured viewer finishes its next load.
    private func awaitStructuredLoad(_ item: QuickViewItem, _ action: () -> Void) async throws {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            action()
            item.controller.structuredController?.onLoadFinished = { done.resume() }
        }
    }

    private func segmentLabels(_ control: NSSegmentedControl) -> [String] {
        (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
    }

    @Test func contextualSegmentsFollowClassification() throws {
        defer { cleanUp() }
        let (item, _, _) = makeItem()
        defer { item.willClose() }
        let modeControl: NSSegmentedControl = try #require(
            view(withID: "quickViewModeControl", in: item.viewController.view))
        let expected: [(String, [String], Bool)] = [
            ("a.json", ["Pretty", "Text", "Hex"], false), ("a.txt", ["Text", "Hex"], false),
            ("a.png", ["Preview", "Hex"], false), ("a.bin", ["Hex"], true),
        ]
        for (name, labels, isHidden) in expected {
            item.show(try makeFileEntry(name: name, content: Data("{}".utf8)), scope: nil)
            #expect(segmentLabels(modeControl) == labels && modeControl.isHidden == isHidden)
        }
    }

    @Test func prettyShowsIndentedColoredJSONAndTextShowsRawUncolored() async throws {
        defer { cleanUp() }
        let (item, _, _) = makeItem()
        defer { item.willClose() }
        let modeControl: NSSegmentedControl = try #require(
            view(withID: "quickViewModeControl", in: item.viewController.view))
        let raw = #"{"a":1,"b":[1,2]}"#
        let entry = try makeFileEntry(name: "d.json", content: Data(raw.utf8))

        try await awaitStructuredLoad(item) { item.show(entry, scope: nil) }
        let structured = try #require(item.controller.structuredController)
        let keyAt = (structured.displayedText as NSString).range(of: "\"a\"").location
        let color =
            structured.textView.textStorage?.attribute(
                .foregroundColor, at: keyAt, effectiveRange: nil) as? NSColor
        #expect(item.activeMode == .pretty && structured.displayedText.contains("\n  \"a\""))
        #expect(color != nil && color != .labelColor)
        #expect(item.preferredFirstResponder === structured.textView)

        try await awaitStructuredLoad(item) {
            modeControl.selectedSegment = 1
            modeControl.sendAction(modeControl.action, to: modeControl.target)
        }
        let rawColor =
            structured.textView.textStorage?.attribute(
                .foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        #expect(structured.displayedText == raw && rawColor == .labelColor)
    }

    @Test func transientOverrideClearsOnNextFileAndRememberPersistsPerExtension() throws {
        defer { cleanUp() }
        let overrides = makeOverrides()
        let (item, _, _) = makeItem(formatOverrides: overrides)
        defer { item.willClose() }
        let button: NSPopUpButton = try #require(
            view(withID: "quickViewFormatButton", in: item.viewController.view))
        let cfg = try makeFileEntry(name: "a.cfg", content: Data("k: v".utf8))

        item.show(cfg, scope: nil)
        #expect(item.activeMode == .hex && item.effectiveOverride == nil)
        item.setTransientOverride(.structured(.yaml))
        #expect(item.activeMode == .pretty && item.classification.structuredFormat == .yaml)
        #expect(button.title == "YAML")
        item.show(try makeFileEntry(name: "b.cfg", content: Data("k".utf8)), scope: nil)
        #expect(item.effectiveOverride == nil && item.activeMode == .hex)

        item.setTransientOverride(.plainText)
        item.rememberOverrideForCurrentExtension(.plainText)
        #expect(overrides.override(forExtension: "cfg") == .plainText)
        item.show(cfg, scope: nil)
        #expect(item.effectiveOverride == .plainText && item.activeMode == .text)
        item.rememberOverrideForCurrentExtension(nil)
        #expect(overrides.override(forExtension: "cfg") == nil && item.activeMode == .hex)
    }

    @Test func willCloseReleasesStructuredController() async throws {
        defer { cleanUp() }
        let (item, _, _) = makeItem()
        _ = item.viewController.view
        let entry = try makeFileEntry(name: "r.json", content: Data("{}".utf8))
        try await awaitStructuredLoad(item) { item.show(entry, scope: nil) }
        let probe = ControllerProbe()
        probe.controller = item.controller.structuredController
        #expect(probe.controller != nil)
        item.willClose()
        await Task.yield()
        #expect(probe.controller == nil)
    }

    private func allTextFields(in view: NSView) -> [NSTextField] {
        var result = (view as? NSTextField).map { [$0] } ?? []
        for subview in view.subviews { result += allTextFields(in: subview) }
        return result
    }
}
