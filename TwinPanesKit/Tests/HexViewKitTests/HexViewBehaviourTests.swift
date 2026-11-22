import AppKit
import Testing

@testable import HexViewKit

/// A data source whose cache, prefetch results and short reads the test controls.
@MainActor
final class FakeHexSource: HexViewDataSource {
    let data: Data
    /// Whether `cachedBytes` answers; prefetch success turns it on.
    var cached = false
    /// Returned by every prefetch; nil means success (which also fills the cache).
    var prefetchError: Error?
    /// Bytes cut off every `cachedBytes` answer, to imitate a file that got shorter.
    var shortBy = 0
    private(set) var prefetches: [Range<UInt64>] = []

    init(count: Int) { data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) }) }

    var length: UInt64 { UInt64(data.count) }

    func cachedBytes(_ range: Range<UInt64>) -> Data? {
        guard cached else { return nil }
        let end = max(Int(range.lowerBound), Int(range.upperBound) - shortBy)
        return data[Int(range.lowerBound)..<end]
    }

    func prefetch(_ range: Range<UInt64>, completion: @escaping @MainActor (Error?) -> Void) {
        prefetches.append(range)
        if prefetchError == nil { cached = true }
        completion(prefetchError)
    }

    func read(_ range: Range<UInt64>) throws -> Data {
        data[Int(range.lowerBound)..<Int(range.upperBound)]
    }
}

@MainActor
final class DelegateSpy: HexViewDelegate {
    var errors = 0
    func hexViewSelectionDidChange(_ view: HexView) {}
    func hexView(_ view: HexView, selectionTooLargeToCopy range: Range<UInt64>) {}
    func hexView(_ view: HexView, didFailToRead error: Error) { errors += 1 }
}

struct ReadFailed: Error {}

/// HexView behaviour against a fake source, drawn offscreen (no window needed).
@MainActor
@Suite struct HexViewBehaviourTests {
    let source: FakeHexSource
    let spy = DelegateSpy()
    let view = HexView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))

    init() {
        source = FakeHexSource(count: 100_000)
        view.options.bytesPerRow = .fixed(16)
        view.delegate = spy
        view.dataSource = source
    }

    func render(times: Int = 1) {
        for _ in 0..<times {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
        }
    }

    /// Since macOS 14 views don't clip by default; an unclipped hex view painted over
    /// the tab bar above it (bug, 2026-11-21).
    @Test func clipsToItsBounds() {
        #expect(view.clipsToBounds)
    }

    @Test func asksForTheVisibleRowsOnceWhenUncached() {
        render(times: 3)
        #expect(source.prefetches.count == 1)
        let visible = view.layout.rowStart(view.position.visibleRows.lowerBound)
        #expect(source.prefetches.first?.contains(visible) == true)
    }

    /// Review bug 2: a read that keeps failing was requested again on every redraw.
    @Test func doesNotRetryAFailedRangeUntilItScrolls() {
        source.prefetchError = ReadFailed()
        render(times: 10)
        #expect(source.prefetches.count == 1)
        #expect(spy.errors == 1)
        view.go(to: 90_000)
        render(times: 10)
        #expect(source.prefetches.count == 2)
        #expect(spy.errors == 2)
    }

    /// Review bug 1: bytes shorter than asked for (a file truncated after open) drew past
    /// the end of the data and trapped.
    @Test func drawsShortDataAsPlaceholders() {
        source.cached = true
        source.shortBy = 40
        render()
        view.go(to: 50_000)
        render()
    }

    // MARK: Keyboard and mouse

    /// A view over a file whose last row is partial: 100,003 bytes at 16 per row. Holds
    /// the source, which the view only references weakly.
    @MainActor final class PartialLastRow {
        let source = FakeHexSource(count: 100_003)
        let view = HexView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        init() {
            view.options.bytesPerRow = .fixed(16)
            view.dataSource = source
        }
    }

    @Test func keyboardStopsAtTheEnds() {
        let fixture = PartialLastRow(), view = fixture.view
        view.moveLeft(nil)
        view.moveUp(nil)
        #expect(view.selection.cursor == 0)
        view.moveToEndOfDocument(nil)
        #expect(view.selection.cursor == 100_002)
        view.moveRight(nil)
        view.moveDown(nil)
        #expect(view.selection.cursor == 100_002)
        #expect(view.position.visibleRows.contains(view.layout.row(of: 100_002)))
    }

    @Test func endOfLineOnAPartialLastRowStopsAtTheLastByte() {
        let fixture = PartialLastRow(), view = fixture.view
        view.go(to: 100_000)
        view.moveToEndOfLine(nil)
        #expect(view.selection.cursor == 100_002)
        view.go(to: 99_990)
        view.moveDown(nil)
        #expect(view.selection.cursor == 100_002)
    }

    @Test func pageDownMovesAScreenAndKeepsTheCursorVisible() {
        let fixture = PartialLastRow(), view = fixture.view
        let rowsPerPage = UInt64(view.position.viewHeight / view.rowHeight) - 1
        view.pageDown(nil)
        #expect(view.selection.cursor == rowsPerPage * 16)
        #expect(view.position.visibleRows.contains(view.layout.row(of: view.selection.cursor)))
        view.go(to: 99_000)
        for _ in 0..<100 { view.pageDown(nil) }
        #expect(view.selection.cursor == 100_002)
    }

    @Test func clickingWhenScrolledHitsTheRowUnderThePointer() throws {
        let fixture = PartialLastRow(), view = fixture.view
        view.go(to: 50_000)
        let top = view.position.topRow
        // The first hex cell of the second visible row.
        let x = view.inset.left + Double(view.layout.hexCell(0)) * view.charWidth + 1
        let y = view.inset.top - view.position.topRowInset + view.rowHeight * 1.5
        let hit = try #require(view.offset(at: NSPoint(x: x, y: y)))
        #expect(hit.0 == view.layout.rowStart(top + 1))
        #expect(hit.1 == .hex)
    }

    @Test func changingBytesPerRowKeepsTheTopRow() {
        let fixture = PartialLastRow(), view = fixture.view
        view.go(to: 64_000)
        let topOffset = view.layout.rowStart(view.position.topRow)
        view.options.bytesPerRow = .fixed(32)
        let newTop = view.layout.rowStart(view.position.topRow)
        #expect(newTop <= topOffset && topOffset < newTop + 32, "\(topOffset) → \(newTop)")
    }
}
