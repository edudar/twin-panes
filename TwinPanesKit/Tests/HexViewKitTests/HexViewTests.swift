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
}
