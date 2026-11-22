import AppKit
import Testing

@testable import EditorKit

/// Searches in the hex editor: closing stops them (review bug 3), and a search that was
/// replaced can't overwrite the newer one's result (the generation counter).
@MainActor
@Suite struct HexEditorSearchTests {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("HexEditorSearchTests-\(UUID().uuidString).bin")

    /// Sparse 4 GiB of zeros: a search for FF has to scan all of it.
    func sparseItem() throws -> HexEditorItem {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try FileHandle(forWritingTo: url).truncate(atOffset: 4 << 30)
        return try HexEditorItem(url: url)
    }

    @Test func closingStopsARunningSearch() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try sparseItem()
        let controller = item.controller
        _ = controller.view
        controller.findBar.kind = .hex
        controller.findBar.field.stringValue = "FF"
        controller.findAll()
        #expect(controller.isSearching)

        item.willClose()
        #expect(!controller.isSearching)
    }

    @Test func aReplacedSearchCannotOverwriteTheNewerResult() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try sparseItem()
        let controller = item.controller
        _ = controller.view
        controller.editorFind(nil)
        controller.findBar.kind = .hex
        controller.findBar.field.stringValue = "FF"
        controller.find(.forward)  // slow: scans 4 GiB and finds nothing
        controller.findBar.field.stringValue = "00"
        controller.find(.forward)  // replaces it and finds offset 0 at once
        for _ in 0..<500 where controller.isSearching {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(item.hexView.selection.range == 0..<1)
        #expect(controller.findBar.statusLabel.stringValue.hasPrefix("Found at 0x0"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.findBar.statusLabel.stringValue.hasPrefix("Found at 0x0"))
    }
}
