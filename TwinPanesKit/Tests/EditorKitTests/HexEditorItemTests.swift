import AppKit
import Foundation
import Testing

@testable import EditorKit
@testable import TwinPanesCore

@MainActor
@Suite struct HexEditorItemTests {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("HexEditorItemTests-\(UUID().uuidString).bin")

    func item(bytes: Int) throws -> HexEditorItem {
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0) }).write(to: url)
        return try HexEditorItem(url: url)
    }

    @Test func goToOffsetAcceptsOffsetsInsideTheFile() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try item(bytes: 4096)
        #expect(item.offset(for: "0x10", cursor: 0) == 16)
        #expect(item.offset(for: "4095", cursor: 0) == 4095)
        #expect(item.offset(for: "+16", cursor: 100) == 116)
        #expect(item.offset(for: "4096", cursor: 0) == nil)
        #expect(item.offset(for: "-200", cursor: 100) == 0)  // clamps at the start
        #expect(item.offset(for: "zz", cursor: 0) == nil)
    }

    @Test func anEmptyFileOnlyHasOffsetZero() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try item(bytes: 0)
        #expect(item.offset(for: "0", cursor: 0) == 0)
        #expect(item.offset(for: "1", cursor: 0) == nil)
        #expect(item.statusText.hasSuffix("empty file"))
    }

    @Test func statusShowsCursorSelectionAndSize() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try item(bytes: 4096)
        _ = item.viewController.view
        item.hexView.go(to: 0x10)
        #expect(item.statusText.hasPrefix("Offset 0x10 (16) · Size "))
        #expect(item.statusText.hasSuffix("(4,096 bytes)"))
        item.hexView.select(0x10..<0x14)
        #expect(item.statusText.contains("Selected 4 bytes (0x10…0x13)"))
    }

    @Test func byteCountOmitsRoundedPrefixBelowOneKilobyte() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(HexEditorItem.byteCount(256) == "256 bytes")
        #expect(HexEditorItem.byteCount(999) == "999 bytes")
        let kb = ByteCountFormatter.string(fromByteCount: 1_000, countStyle: .file)
        #expect(HexEditorItem.byteCount(1_000) == "\(kb) (\(UInt64(1_000).formatted()) bytes)")

        let item = try item(bytes: 256)
        _ = item.viewController.view
        #expect(item.statusText == "Offset 0x0 (0) · Size 256 bytes")
    }

    @Test func copyDoesNotFillPageCacheAndFailedSaveCleansPartialFile() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try item(bytes: 4096)
        var copied: Data?
        item.readForCopy(0..<1024) { result in
            copied = try? result.get()
        }
        #expect(copied?.count == 1024)
        #expect(item.source.cachedPageCount == 0)

        let out = url.deletingLastPathComponent()
            .appendingPathComponent("partial-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: out) }
        try FileHandle(forWritingTo: url).truncate(atOffset: 100)
        let error = HexEditorViewController.write(item.snapshot, range: 0..<2000, to: out)
        #expect(error != nil)
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func largeCopyReadsAsynchronouslyWithoutFillingPageCache() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let size = 300 * 1024
        let item = try item(bytes: size)
        try item.buffer.overwrite(at: 100, with: Data([0xDE, 0xAD]))

        @MainActor final class CopyState {
            var insideCall = true
            var completedSynchronously = false
        }
        let state = CopyState()
        let copied: Result<Data, Error> = await withCheckedContinuation { continuation in
            item.readForCopy(0..<UInt64(size)) { result in
                if state.insideCall { state.completedSynchronously = true }
                continuation.resume(returning: result)
            }
            state.insideCall = false
        }

        #expect(!state.completedSynchronously)
        let data = try copied.get()
        #expect(data.count == size)
        #expect(data[100..<102] == Data([0xDE, 0xAD]))
        #expect(item.source.cachedPageCount == 0)

        try FileHandle(forWritingTo: url).truncate(atOffset: 100)
        let truncated: Result<Data, Error> = await withCheckedContinuation { continuation in
            item.readForCopy(0..<UInt64(size)) { result in
                continuation.resume(returning: result)
            }
        }
        #expect(throws: ByteSourceError.self) { _ = try truncated.get() }
    }

    /// Everything the tab reads (view, copy, Save Selection, search) sees the edits.
    @Test func readsGoThroughTheCurrentSnapshot() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try item(bytes: 4096)
        try item.buffer.overwrite(at: 100, with: Data([0xDE, 0xAD]))
        #expect(try item.read(99..<103) == Data([99, 0xDE, 0xAD, 102]))
        #expect(item.modifiedRanges(in: 0..<4096) == [100..<102])
        var copied: Data?
        item.readForCopy(100..<102) { copied = try? $0.get() }
        #expect(copied == Data([0xDE, 0xAD]))
        let match = try Searcher(source: item.controller.searchSource!).next(
            SearchPattern.hex("DE AD"), from: 0, direction: .forward)
        #expect(match?.range == 100..<102)

        let out = url.deletingLastPathComponent()
            .appendingPathComponent("selection-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: out) }
        #expect(HexEditorViewController.write(item.snapshot, range: 98..<104, to: out) == nil)
        #expect(try Data(contentsOf: out) == Data([98, 99, 0xDE, 0xAD, 102, 103]))
    }

    @Test func viewControllerSurvivesAfterItemDeallocates() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        var editor: HexEditorItem? = try item(bytes: 4096)
        let controller = editor!.controller
        _ = controller.view
        controller.toggleInspector(nil)

        // Closing a tab releases HexEditorItem while AppKit may still invoke callbacks
        // on the view controller before draining the autorelease pool.
        editor = nil
        controller.viewDidAppear()
        controller.hexViewSelectionDidChange(controller.hexView)
        controller.updateInspector()
        let copyItem = NSMenuItem(
            title: "Copy as Hex", action: #selector(HexEditorViewController.copyAsHex(_:)),
            keyEquivalent: "")
        #expect(!controller.validateMenuItem(copyItem))
    }
}
