import AppKit
import Testing

@testable import EditorKit

/// Review bug 3: closing an editor tab or window must stop its search.
@MainActor
@Suite struct HexEditorCloseTests {
    @Test func closingStopsARunningSearch() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HexEditorCloseTests-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        // Sparse 4 GiB of zeros: a search for FF scans all of it.
        try FileHandle(forWritingTo: url).truncate(atOffset: 4 << 30)

        let item = try HexEditorItem(url: url)
        let controller = item.controller
        _ = controller.view
        controller.findBar.kind = .hex
        controller.findBar.field.stringValue = "FF"
        controller.findAll()
        #expect(controller.isSearching)

        item.willClose()
        #expect(!controller.isSearching)
    }
}
