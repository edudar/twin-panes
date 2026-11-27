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

    private final class ScopeProbe { weak var scope: SecurityScope? }

    private func makeController(
        readMetadata: @escaping @Sendable (URL) throws -> FileMetadata = {
            PreviewPaneViewControllerTests.metadata(for: $0)
        }
    ) -> (PreviewPaneViewController, FakeQuickLookViewer) {
        let fakeQL = FakeQuickLookViewer()
        let controller = PreviewPaneViewController(
            debounce: .zero, makeQuickLook: { QuickLookHostView(viewer: fakeQL) },
            readMetadata: readMetadata)
        _ = controller.view
        return (controller, fakeQL)
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

    nonisolated private static func metadata(for url: URL, isDataless: Bool = false) -> FileMetadata
    {
        let type: UTType = url.pathExtension == "bin" ? .data : .text
        return FileMetadata(
            url: url, name: url.lastPathComponent, kind: type == .text ? "Text" : "Data",
            typeIdentifier: type.identifier, isDirectory: false, isPackage: false,
            isSymbolicLink: false, isDataless: isDataless, size: 16, allocatedSize: 4096,
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
            let (controller, fakeQL) = makeController { url in
                readCounter.increment()
                return Self.metadata(for: url)
            }
            await waitForLoad(controller) {
                for url in urls { controller.show(file: url, scope: nil) }
            }
            #expect(readCounter.count == 1 && fakeQL.shown.last == urls.last)
            controller.tearDown()
            #expect(fakeQL.closeCount == 1)
        }
    }

    @Test func setActiveFalseClearsResourcesAndResumesLatestTarget() async throws {
        try await withTempDir { dir in
            let (a, b) = (dir.appendingPathComponent("a.bin"), dir.appendingPathComponent("b.txt"))
            let (controller, fakeQL) = makeController()
            let probe = ScopeProbe()
            await waitForLoad(controller) {
                let scope = SecurityScope(url: a)
                probe.scope = scope
                controller.show(file: a, scope: scope)
            }
            #expect(fakeQL.shown.last == a && probe.scope != nil)

            controller.setActive(false)
            #expect(probe.scope == nil && fakeQL.shown.last == .some(nil))
            #expect(controller.metadataView.titleText == nil)
            controller.show(file: b, scope: nil)
            await Task.yield()
            #expect(fakeQL.shown.last == .some(nil))

            await waitForLoad(controller) { controller.setActive(true) }
            #expect(fakeQL.shown.last == b)
            controller.tearDown()
        }
    }

    @Test func selectionSummariesAndDatalessPlaceholderWork() async throws {
        try await withTempDir { dir in
            let (a, b) = (dir.appendingPathComponent("a.txt"), dir.appendingPathComponent("b.txt"))
            let (controller, _) = makeController()
            let entries = [makeEntry(url: a, size: 120), makeEntry(url: b, size: 380)]
            await waitForLoad(controller) { controller.show(entries: entries, scope: nil) }
            #expect(controller.metadataView.titleText == "2 items selected")
            #expect(controller.metadataView.rows.first?.label == "Total Size")

            await waitForLoad(controller) {
                controller.show(entries: [makeEntry(url: dir, name: "..")], scope: nil)
            }
            #expect(controller.metadataView.messageText == "No Selection")
            await waitForLoad(controller) { controller.show(file: nil, scope: nil) }
            #expect(controller.metadataView.messageText == "No Selection")
            controller.tearDown()

            let (datalessController, datalessQL) = makeController { url in
                Self.metadata(for: url, isDataless: true)
            }
            await waitForLoad(datalessController) { datalessController.show(file: a, scope: nil) }
            #expect(datalessQL.shown.isEmpty)
            #expect(datalessController.placeholderLabel.stringValue.contains("iCloud"))
            datalessController.tearDown()
        }
    }

    @Test func metadataReadFailureShowsInlineErrorPlaceholder() async throws {
        let (controller, _) = makeController { _ in throw POSIXError(.ENOENT) }
        await waitForLoad(controller) {
            controller.show(file: URL(fileURLWithPath: "/tmp/missing.txt"), scope: nil)
        }
        #expect(controller.placeholderLabel.stringValue.contains("missing.txt"))
        #expect(controller.metadataView.messageText != nil)
        controller.tearDown()
    }

    @Test func layoutGivesPreviewAndMetadataRealHeightsBelowSafeArea() {
        let (controller, _) = makeController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 600),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.contentView = controller.view
        window.layoutIfNeeded()

        #expect(controller.previewContainer.frame.height >= 120)
        #expect(controller.metadataView.frame.height >= 120)
        let previewTop = controller.previewContainer.convert(
            controller.previewContainer.bounds, to: nil
        ).maxY
        #expect(previewTop <= window.contentLayoutRect.maxY + 1)
        controller.tearDown()
    }

    @Test func showSelectionHandlesEmptySingleAndMultiRowWithoutMetadataReads() async throws {
        try await withTempDir { dir in
            let readCounter = ReadCounter()
            let (controller, fakeQL) = makeController { url in
                readCounter.increment()
                return Self.metadata(for: url)
            }
            let a = dir.appendingPathComponent("a.txt")
            let b = dir.appendingPathComponent("b.txt")
            let sub = dir.appendingPathComponent("sub", isDirectory: true)
            let entries = [
                makeEntry(url: a, size: 120),
                makeEntry(url: b, size: 380),
                DirectoryEntry(
                    url: sub, name: "sub", isDirectory: true, isPackage: false,
                    isSymbolicLink: false, isHidden: false, size: nil, modified: nil, type: .folder),
            ]
            let listing = FolderListing(order: ListingOrder(), showsHidden: false).merging(entries)

            await waitForLoad(controller) { controller.show(selection: .none, scope: nil) }
            #expect(controller.metadataView.messageText == "No Selection")

            await waitForLoad(controller) {
                controller.show(selection: ListingSelection(rows: [1], of: listing), scope: nil)
            }
            #expect(readCounter.count == 1 && fakeQL.shown.last == a)

            await waitForLoad(controller) {
                controller.show(
                    selection: ListingSelection(rows: [0, 1, 2], of: listing), scope: nil)
            }
            #expect(readCounter.count == 1)
            #expect(controller.metadataView.titleText == "3 items selected")
            #expect(controller.metadataView.rows.first?.label == "Total Size")
            #expect(controller.metadataView.rows.first?.value == "500 bytes")
            controller.tearDown()
        }
    }

    @Test func setActiveTrueFollowedByShowCancelsStaleUnscopedLoad() async throws {
        try await withTempDir { dir in
            let readURLs = ReadURLRecorder()
            let (a, b) = (dir.appendingPathComponent("a.txt"), dir.appendingPathComponent("b.txt"))
            let (controller, fakeQL) = makeController { url in
                readURLs.append(url)
                return Self.metadata(for: url)
            }
            let scope1 = SecurityScope(url: a)
            let scope2 = SecurityScope(url: b)
            await waitForLoad(controller) { controller.show(file: a, scope: scope1) }
            #expect(readURLs.urls == [a])

            controller.setActive(false)
            await waitForLoad(controller) {
                controller.setActive(true)
                controller.show(file: b, scope: scope2)
            }
            #expect(readURLs.urls == [a, b])
            #expect(fakeQL.shown.last == b)
            controller.tearDown()
        }
    }

    @Test func unchangedTargetWhileActiveSkipsDuplicateMetadataRead() async throws {
        try await withTempDir { dir in
            let readCounter = ReadCounter()
            let a = dir.appendingPathComponent("a.txt")
            let (controller, _) = makeController { url in
                readCounter.increment()
                return Self.metadata(for: url)
            }
            let scope = SecurityScope(url: a)
            await waitForLoad(controller) { controller.show(file: a, scope: scope) }
            #expect(readCounter.count == 1)

            await waitForLoad(controller) { controller.show(file: a, scope: scope) }
            #expect(readCounter.count == 1)
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

private final class ReadURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    var urls: [URL] { lock.withLock { recorded } }
    func append(_ url: URL) { lock.withLock { recorded.append(url) } }
}
