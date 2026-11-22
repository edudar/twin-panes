import Foundation
import Testing

@testable import EditorKit

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
        #expect(item.statusText.hasSuffix("empty file · Read-only"))
    }

    @Test func statusShowsCursorSelectionAndSize() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try item(bytes: 4096)
        _ = item.viewController.view
        item.hexView.go(to: 0x10)
        #expect(item.statusText.hasPrefix("Offset 0x10 (16) · Size "))
        #expect(item.statusText.hasSuffix("(4,096 bytes) · Read-only"))
        item.hexView.select(0x10..<0x14)
        #expect(item.statusText.contains("Selected 4 bytes (0x10…0x13)"))
    }
}
