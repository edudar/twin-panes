import AppKit
import Testing

@testable import HexViewKit

@MainActor
@Suite struct HexViewTests {
    /// Since macOS 14 views don't clip by default; an unclipped hex view painted over
    /// the tab bar above it (bug, 2026-11-21).
    @Test func clipsToItsBounds() {
        #expect(HexView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)).clipsToBounds)
    }

    @Test func findsTheFirstHighlightReachingARow() {
        let ranges: [Range<UInt64>] = [0..<2, 10..<20, 40..<41]
        #expect(ranges.partitioningIndex { $0.upperBound > 0 } == 0)
        #expect(ranges.partitioningIndex { $0.upperBound > 2 } == 1)
        #expect(ranges.partitioningIndex { $0.upperBound > 19 } == 1)
        #expect(ranges.partitioningIndex { $0.upperBound > 20 } == 2)
        #expect(ranges.partitioningIndex { $0.upperBound > 41 } == 3)
        #expect([Range<UInt64>]().partitioningIndex { _ in true } == 0)
    }

    @Test func inspectorFollowsTheByteOrder() {
        let inspector = InspectorView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        inspector.show(Data([0x01, 0x00]))
        func value(_ name: String) -> String? { inspector.rows.first { $0.name == name }?.value }
        #expect(value("UInt16") == "1")
        inspector.order.selectedSegment = 1
        inspector.orderChanged(inspector.order)
        #expect(inspector.endianness == .big)
        #expect(value("UInt16") == "256")
        #expect(value("UInt32") == nil)
    }
}
