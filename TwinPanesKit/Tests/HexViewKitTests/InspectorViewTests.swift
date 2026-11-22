import AppKit
import Testing

@testable import HexViewKit

@MainActor
@Suite struct InspectorViewTests {
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
