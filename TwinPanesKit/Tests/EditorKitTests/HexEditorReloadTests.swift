import AppKit
import Foundation
import Testing
import WorkspaceKit

@testable import EditorKit
@testable import HexViewKit
@testable import TwinPanesCore

@MainActor
private final class ReloadStatusSpy: WorkspaceHost {
    var messages: [String] = []
    func showStatus(_ message: String) { messages.append(message) }
}

@MainActor
private final class ResizableSource: HexViewDataSource {
    var length: UInt64
    init(length: UInt64) { self.length = length }
    func cachedBytes(_ range: Range<UInt64>) -> Data? { nil }
    func prefetch(_ range: Range<UInt64>, completion: @escaping @MainActor (Error?) -> Void) {
        completion(nil)
    }
    func read(_ range: Range<UInt64>) throws -> Data { Data() }
}

@MainActor
@Suite(.serialized) struct HexEditorReloadTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("HexEditorReloadTests-\(UUID().uuidString)")
    let url: URL
    var root: URL { folder.appendingPathComponent("Sessions") }

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("file.bin")
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    func makeItem(_ bytes: Data, host: WorkspaceHost) throws -> HexEditorItem {
        try bytes.write(to: url)
        let session = try EditorSession(url: url, sessionsRoot: root)
        let item = HexEditorItem(session: session)
        item.host = host
        item.controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        item.controller.view.layoutSubtreeIfNeeded()
        return item
    }

    func truncate(to length: UInt64) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: length)
        try handle.close()
    }

    func awaitReload(_ item: HexEditorItem, _ work: () throws -> Void) async throws {
        let owner = NSObject()
        let reloaded = AsyncSignal()
        item.session.observe(owner) { if $0 == .edited { reloaded.signal() } }
        try work()
        await reloaded.wait()
    }

    func render(_ view: HexView) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
    }

    func renderAndPrefetch(_ item: HexEditorItem, range: Range<UInt64>) async throws {
        render(item.hexView)
        for _ in 0..<200 where item.cachedBytes(range) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(item.cachedBytes(range) != nil)
        render(item.hexView)
    }

    @Test func cleanExternalShrinkAndGrowClampSelectionAndRelayout() async throws {
        defer { cleanUp() }
        let host = ReloadStatusSpy()
        let initial = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
        let item = try makeItem(initial, host: host)
        item.session.startWatching()
        defer { item.willClose() }
        try await renderAndPrefetch(item, range: 0..<64)

        item.hexView.go(to: 3500)
        for _ in 0..<5 { item.hexView.moveLeftAndModifySelection(nil) }
        item.hexView.highlights = [3400..<3404]
        try await awaitReload(item) { try truncate(to: 100) }

        #expect(item.hexView.layout.length == 100)
        #expect(item.hexView.selection.length == 100)
        #expect(item.hexView.selection.cursor == 99 && item.hexView.selection.range == 99..<100)
        #expect(item.hexView.highlights.isEmpty)
        try await renderAndPrefetch(item, range: 0..<100)
        #expect(!host.messages.contains { $0.contains("shorter than expected") })

        item.hexView.go(to: 50)
        item.hexView.moveLeftAndModifySelection(nil)
        try await awaitReload(item) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: Data(repeating: 0x5A, count: 8192))
            try handle.close()
        }

        #expect(item.hexView.layout.length == 8192 && item.hexView.selection.length == 8192)
        #expect(item.hexView.selection.anchor == 50 && item.hexView.selection.cursor == 49)
        item.hexView.go(to: 8100)
        #expect(item.hexView.selection.cursor == 8100)
        try await renderAndPrefetch(item, range: 8100..<8192)
        #expect(try item.read(8100..<8102) == Data([0x5A, 0x5A]))
        #expect(!host.messages.contains { $0.contains("shorter than expected") })
    }

    @Test func reloadDiscardingEditsClampsInspectorCursorAndHandlesEmptyFile() throws {
        defer { cleanUp() }
        let host = ReloadStatusSpy()
        let initial = Data((0..<1024).map { UInt8(truncatingIfNeeded: $0) })
        let item = try makeItem(initial, host: host)
        defer { item.willClose() }
        item.controller.toggleInspector(nil)
        item.hexView.go(to: 900)
        item.hexView.insertText("FF")
        #expect(item.isDirty)

        try truncate(to: 64)
        try item.session.reloadDiscardingEdits()
        #expect(item.hexView.layout.length == 64 && item.hexView.selection.cursor == 63)
        #expect(!item.isDirty)

        try truncate(to: 0)
        try item.session.reloadDiscardingEdits()
        #expect(item.hexView.layout.length == 0)
        #expect(item.hexView.selection == HexSelection(length: 0))
        #expect(item.statusText.hasSuffix("empty file"))
        render(item.hexView)
        #expect(!host.messages.contains { $0.contains("shorter than expected") })
    }

    @Test func externalChangeBeforeFirstHexKeystrokeReloadsCleanly() async throws {
        defer { cleanUp() }
        let host = ReloadStatusSpy()
        let initial = Data((0..<64).map { UInt8($0 + 5) })
        let item = try makeItem(initial, host: host)
        defer { item.willClose() }
        try await renderAndPrefetch(item, range: 0..<64)

        try Data(repeating: 0x77, count: 128).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: url.path)

        item.hexView.insertText("A")
        #expect(try item.read(0..<1) == Data([0x77]))
        #expect(!item.isDirty && !item.canUndo && item.session.folder == nil)
        #expect(item.hexView.layout.length == 128 && item.hexView.selection.length == 128)
        #expect(item.hexView.pendingNibble == nil)
        #expect(host.messages.last == "“file.bin” changed on disk and was reloaded")

        item.hexView.insertText("AB")
        #expect(try item.read(0..<1) == Data([0xAB]))
        #expect(item.isDirty && item.session.folder != nil)
    }

    @Test func contentLengthDidChangePreservesReversedSelectionAndClearsNibble() {
        let source = ResizableSource(length: 100)
        let view = HexView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.dataSource = source
        view.go(to: 80)
        for _ in 0..<60 { view.moveLeftAndModifySelection(nil) }
        view.pendingNibble = 20

        source.length = 50
        view.contentLengthDidChange()
        #expect(view.selection.length == 50 && view.layout.length == 50)
        #expect(view.selection.anchor == 49 && view.selection.cursor == 20)
        #expect(view.selection.range == 20..<50 && view.pendingNibble == nil)
    }
}
