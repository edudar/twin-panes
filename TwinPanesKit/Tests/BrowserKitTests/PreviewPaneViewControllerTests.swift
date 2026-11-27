import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import WorkspaceKit

@testable import BrowserKit
@testable import TwinPanesCore

@MainActor
@Suite struct PreviewPaneViewControllerTests {
    private final class FakeQuickLookViewer: QuickLookViewing {
        let view = NSView()
        var shown: [URL?] = []
        var closeCount = 0
        func show(_ url: URL?) { shown.append(url) }
        func close() { closeCount += 1 }
    }

    private final class FakeHexViewer: HexPreviewing {
        let viewController = NSViewController()
        var showsUnsavedEdits = false
        var onStateChange: (() -> Void)?
        var shown: [URL?] = []
        func show(_ url: URL?, scope: SecurityScope?) { shown.append(url) }
    }

    private final class FakeHexViewerFactory: HexViewerFactory {
        var createdStyles: [HexViewerStyle] = []
        var viewers: [FakeHexViewer] = []
        func makeHexViewer(style: HexViewerStyle) -> any HexPreviewing {
            createdStyles.append(style)
            let viewer = FakeHexViewer()
            viewers.append(viewer)
            return viewer
        }
    }

    private final class ScopeProbe { weak var scope: SecurityScope? }

    private func makeController(
        sessions: SessionRegistry? = nil,
        readMetadata: @escaping @Sendable (URL) throws -> FileMetadata = {
            PreviewPaneViewControllerTests.metadata(for: $0)
        }
    ) -> (PreviewPaneViewController, FakeQuickLookViewer, FakeHexViewerFactory) {
        let (fakeQL, factory) = (FakeQuickLookViewer(), FakeHexViewerFactory())
        let controller = PreviewPaneViewController(
            viewerFactory: factory, sessions: sessions, debounce: .zero,
            makeQuickLook: { QuickLookHostView(viewer: fakeQL) }, readMetadata: readMetadata)
        _ = controller.view
        return (controller, fakeQL, factory)
    }

    private func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PreviewPaneTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    private func waitForLoad(
        _ controller: PreviewPaneViewController, after action: () -> Void
    ) async {
        await withCheckedContinuation { continuation in
            controller.onLoadFinished = {
                controller.onLoadFinished = nil
                continuation.resume()
            }
            action()
        }
    }

    nonisolated private static func metadata(for url: URL) -> FileMetadata {
        let type: UTType = url.pathExtension == "bin" ? .data : .text
        return FileMetadata(
            url: url, name: url.lastPathComponent, kind: type == .text ? "Text" : "Data",
            typeIdentifier: type.identifier, isDirectory: false, isPackage: false,
            isSymbolicLink: false, isDataless: false, size: 16, allocatedSize: 4096,
            created: nil, modified: nil, accessed: nil, posixMode: 0o644,
            owner: "user", group: "staff", hardLinkCount: 1, flags: [], symlinkTarget: nil,
            extendedAttributes: [], hasMoreExtendedAttributes: false)
    }

    private func makeEntry(url: URL, size: UInt64? = nil, name: String? = nil) -> DirectoryEntry {
        DirectoryEntry(
            url: url, name: name ?? url.lastPathComponent, isDirectory: name == "..",
            isPackage: false, isSymbolicLink: false, isHidden: false, size: size, modified: nil,
            type: name == ".." ? .folder : .text)
    }

    @Test func debouncesRapidSelectionUpdatesToSingleLoad() async throws {
        try await withTempDir { dir in
            let readCounter = ReadCounter()
            let urls = (0..<100).map { dir.appendingPathComponent("file-\($0).txt") }
            let (controller, fakeQL, factory) = makeController { url in
                readCounter.increment()
                return Self.metadata(for: url)
            }
            await waitForLoad(controller) {
                for url in urls { controller.show(file: url, scope: nil) }
            }
            #expect(readCounter.count == 1 && fakeQL.shown.last == urls.last)
            #expect(factory.viewers.isEmpty)
            controller.tearDown()
            #expect(fakeQL.closeCount == 1)
        }
    }

    @Test func pinningFreezesDisplayAndCatchesUpOnUnpin() async throws {
        try await withTempDir { dir in
            let (a, b) = (dir.appendingPathComponent("a.txt"), dir.appendingPathComponent("b.txt"))
            let (controller, fakeQL, _) = makeController()
            await waitForLoad(controller) { controller.show(file: a, scope: nil) }
            controller.togglePin(nil)
            #expect(controller.isPinned)
            controller.show(file: b, scope: nil)
            await Task.yield()
            #expect(fakeQL.shown == [a])
            await waitForLoad(controller) { controller.togglePin(nil) }
            #expect(!controller.isPinned && fakeQL.shown.last == b)
            controller.tearDown()
        }
    }

    @Test func setActiveFalseClearsResourcesAndResumesLatestTarget() async throws {
        try await withTempDir { dir in
            let (a, b) = (dir.appendingPathComponent("a.bin"), dir.appendingPathComponent("b.txt"))
            let (controller, fakeQL, factory) = makeController()
            let probe = ScopeProbe()
            await waitForLoad(controller) {
                let scope = SecurityScope(url: a)
                probe.scope = scope
                controller.show(file: a, scope: scope)
            }
            #expect(controller.activeMode == .hex && factory.createdStyles == [.compact])
            #expect(probe.scope != nil)

            controller.setActive(false)
            #expect(probe.scope == nil && factory.viewers.first?.shown.last == .some(nil))
            #expect(controller.metadataView.titleText == nil)
            controller.show(file: b, scope: nil)
            await Task.yield()
            #expect(fakeQL.shown.isEmpty)

            await waitForLoad(controller) { controller.setActive(true) }
            #expect(controller.activeMode == .quickLook && fakeQL.shown.last == b)
            controller.tearDown()
        }
    }

    @Test func modeOverrideResetsOnNextItemAndSelectionSummariesWork() async throws {
        try await withTempDir { dir in
            let (a, b) = (dir.appendingPathComponent("a.txt"), dir.appendingPathComponent("b.txt"))
            let (controller, _, factory) = makeController()
            await waitForLoad(controller) { controller.show(file: a, scope: nil) }
            #expect(controller.activeMode == .quickLook && controller.modeControl.isEnabled)

            controller.modeControl.selectedSegment = 1
            controller.modeChanged(controller.modeControl)
            #expect(controller.activeMode == .hex && factory.viewers.first?.shown.last == a)

            await waitForLoad(controller) { controller.show(file: b, scope: nil) }
            #expect(controller.activeMode == .quickLook)

            let entries = [makeEntry(url: a, size: 120), makeEntry(url: b, size: 380)]
            await waitForLoad(controller) { controller.show(entries: entries, scope: nil) }
            #expect(controller.metadataView.titleText == "2 items selected")
            #expect(controller.metadataView.rows.first?.label == "Total Size")
            #expect(!controller.modeControl.isEnabled)

            await waitForLoad(controller) {
                controller.show(entries: [makeEntry(url: dir, name: "..")], scope: nil)
            }
            #expect(controller.metadataView.messageText == "No Selection")
            await waitForLoad(controller) { controller.show(file: nil, scope: nil) }
            #expect(controller.metadataView.messageText == "No Selection")
            controller.tearDown()
        }
    }

    @Test func metadataReadFailureShowsInlineErrorPlaceholder() async throws {
        let (controller, _, _) = makeController { _ in throw POSIXError(.ENOENT) }
        await waitForLoad(controller) {
            controller.show(file: URL(fileURLWithPath: "/tmp/missing.txt"), scope: nil)
        }
        #expect(!controller.modeControl.isEnabled)
        #expect(controller.placeholderLabel.stringValue.contains("missing.txt"))
        #expect(controller.metadataView.messageText != nil)
        controller.tearDown()
    }

    @Test func liveDirtySessionUpdatesBannerAndModeBeforeAndAfterHexCreation() async throws {
        try await withTempDir { dir in
            let registry = SessionRegistry()
            let file = dir.appendingPathComponent("notes.txt")
            try Data("hello".utf8).write(to: file)
            let (controller, _, factory) = makeController(sessions: registry)

            await waitForLoad(controller) { controller.show(file: file, scope: nil) }
            #expect(controller.activeMode == .quickLook && controller.unsavedBanner.isHidden)
            #expect(factory.viewers.isEmpty)

            let (session, _) = try registry.open(file)
            #expect(controller.activeMode == .quickLook && controller.unsavedBanner.isHidden)

            try session.overwrite(
                Data("H".utf8), at: 0, selectionBefore: 0..<0, selectionAfter: 1..<1)
            #expect(controller.activeMode == .hex && !controller.unsavedBanner.isHidden)
            #expect(controller.unsavedLabel.stringValue == "Includes unsaved edits")
            #expect(controller.showHexButton.isHidden && factory.viewers.count == 1)

            controller.modeControl.selectedSegment = 0
            controller.modeChanged(controller.modeControl)
            #expect(controller.activeMode == .quickLook && !controller.showHexButton.isHidden)
            #expect(
                controller.unsavedLabel.stringValue
                    == "Unsaved edits in editor (showing saved file)")

            controller.showHexFromBanner(nil)
            #expect(controller.activeMode == .hex && controller.showHexButton.isHidden)

            session.revert()
            session.close()
            #expect(controller.unsavedBanner.isHidden)
            controller.tearDown()
        }
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
