import AppKit
import Testing

@testable import EditorKit
@testable import HexViewKit
@testable import TwinPanesCore

@MainActor
@Suite struct HexEditorInspectorTests {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("HexEditorInspectorTests-\(UUID().uuidString).bin")

    func makeItem(bytes: Int) throws -> HexEditorItem {
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
        try data.write(to: url)
        return try HexEditorItem(url: url)
    }

    @Test func inspectorLoadsUncachedBytesEvenWhenViewportPrefetchesConcurrently() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem(bytes: 200_000)
        let controller = item.controller
        _ = controller.view
        controller.toggleInspector(nil)
        #expect(!controller.inspector.isHidden)

        // Hold IO so both the inspector's prefetch and HexView's viewport prefetch queue
        // together — the viewport prefetch must not cancel the inspector's load.
        item.source.holdIOForTesting()
        item.hexView.go(to: 150_000)
        if let rep = item.hexView.bitmapImageRepForCachingDisplay(in: item.hexView.bounds) {
            item.hexView.cacheDisplay(in: item.hexView.bounds, to: rep)
        }
        item.source.releaseIOForTesting()

        let expected = String(UInt8(truncatingIfNeeded: 150_000 &* 13 &+ 5))
        func uint8Value() -> String? {
            controller.inspector.rows.first { $0.name == "UInt8" }?.value
        }
        for _ in 0..<100 where uint8Value() != expected {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(uint8Value() == expected)
    }
}
