import AppKit
import Testing

@testable import HexViewKit

/// A data source whose cache, prefetch results and short reads the test controls.
@MainActor
final class FakeHexSource: HexViewDataSource {
    var data: Data
    /// Returned by `modifiedRanges`, clamped to the asked range.
    var modified: [Range<UInt64>] = []
    /// Whether `cachedBytes` answers; prefetch success turns it on.
    var cached = false
    /// Returned by every prefetch; nil means success (which also fills the cache).
    var prefetchError: Error?
    /// Thrown by `read(_:)` when set.
    var readError: Error?
    /// Bytes cut off every `cachedBytes` answer, to imitate a file that got shorter.
    var shortBy = 0
    /// When true, `prefetch` records the request without completing until `flushPrefetches()`.
    var deferPrefetch = false
    private(set) var prefetches: [Range<UInt64>] = []
    private(set) var reads: [Range<UInt64>] = []
    private var pending: [@MainActor () -> Void] = []

    init(count: Int) { data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) }) }

    var length: UInt64 { UInt64(data.count) }

    func cachedBytes(_ range: Range<UInt64>) -> Data? {
        guard cached else { return nil }
        let end = max(Int(range.lowerBound), Int(range.upperBound) - shortBy)
        return data[Int(range.lowerBound)..<end]
    }

    func prefetch(_ range: Range<UInt64>, completion: @escaping @MainActor (Error?) -> Void) {
        prefetches.append(range)
        let finish: @MainActor () -> Void = {
            if self.prefetchError == nil { self.cached = true }
            completion(self.prefetchError)
        }
        if deferPrefetch { pending.append(finish) } else { finish() }
    }

    func flushPrefetches() {
        let callbacks = pending
        pending = []
        for callback in callbacks { callback() }
    }

    func read(_ range: Range<UInt64>) throws -> Data {
        reads.append(range)
        if let readError { throw readError }
        return data[Int(range.lowerBound)..<Int(range.upperBound)]
    }

    func modifiedRanges(in range: Range<UInt64>) -> [Range<UInt64>] {
        modified.map { $0.clamped(to: range) }.filter { !$0.isEmpty }
    }
}

@MainActor
final class DelegateSpy: HexViewDelegate {
    var errors = 0
    var tooLargeRanges: [Range<UInt64>] = []
    var loadedCount = 0
    func hexViewSelectionDidChange(_ view: HexView) {}
    func hexView(_ view: HexView, selectionTooLargeToCopy range: Range<UInt64>) {
        tooLargeRanges.append(range)
    }
    func hexView(_ view: HexView, didFailToRead error: Error) { errors += 1 }
    func hexViewDidLoadBytes(_ view: HexView) { loadedCount += 1 }

    /// Applies writes to `source` unless `readOnly`.
    weak var source: FakeHexSource?
    var willBeginEdit = true
    var willBeginEditCalls = 0
    var readOnly = false
    var writes: [(offset: UInt64, bytes: Data, column: HexLayout.Column, cursorAfter: UInt64)] = []
    var unencodable: [Character] = []
    func hexViewWillBeginEdit(_ view: HexView) -> Bool {
        willBeginEditCalls += 1
        return willBeginEdit
    }
    func hexView(
        _ view: HexView, overwrite bytes: Data, at offset: UInt64, column: HexLayout.Column,
        cursorAfter: UInt64
    ) -> Bool {
        guard !readOnly, let source else { return false }
        writes.append((offset, bytes, column, cursorAfter))
        source.data.replaceSubrange(Int(offset)..<(Int(offset) + bytes.count), with: bytes)
        return true
    }
    func hexView(_ view: HexView, cannotEncode character: Character) {
        unencodable.append(character)
    }
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

    @Test func asksForTheVisibleRowsOnceWhenUncached() {
        render(times: 3)
        #expect(source.prefetches.count == 1)
        let visible = view.layout.rowStart(view.position.visibleRows.lowerBound)
        #expect(source.prefetches.first?.contains(visible) == true)
    }

    /// Scrolling down past the pending prefetch's end must request the newly visible rows
    /// even when the new margin still overlaps the pending range's start.
    @Test func incrementalDownwardScrollRequestsUncoveredVisibleRows() {
        source.deferPrefetch = true
        render()
        #expect(source.prefetches.count == 1)
        let firstEnd = source.prefetches[0].upperBound
        // Scroll so the visible rows extend past `firstEnd` while one screen of margin
        // above still reaches inside `source.prefetches[0]`.
        let rowsPerScreen = UInt64(view.position.visibleRows.count)
        view.position.scrollToTop(row: view.layout.row(of: firstEnd) - rowsPerScreen / 2)
        render()
        #expect(source.prefetches.count == 2)
        source.flushPrefetches()
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
    /// the end of the data and trapped. It must treat short reads as missing and ask the
    /// data source to prefetch rather than trapping.
    @Test func drawsShortDataAsPlaceholders() {
        source.cached = true
        source.shortBy = 40
        source.prefetchError = ReadFailed()
        render()
        #expect(source.prefetches.count == 1)
        #expect(spy.errors == 1)
        view.go(to: 50_000)
        render()
        #expect(source.prefetches.count == 2)
        #expect(spy.errors == 2)
    }

    @Test func rendersHighlightsAndEmptyFiles() {
        source.cached = true
        view.highlights = [0..<4, 14..<20]
        render()
        #expect(view.clipsToBounds)

        let empty = FakeHexSource(count: 0)
        view.dataSource = empty
        render()
        #expect(view.selection.range.isEmpty)
        let copyItem = NSMenuItem(
            title: "Copy", action: #selector(HexView.copy(_:)), keyEquivalent: "")
        let selectAll = NSMenuItem(
            title: "Select All", action: #selector(HexView.selectAll(_:)), keyEquivalent: "")
        #expect(!view.validateMenuItem(copyItem))
        #expect(!view.validateMenuItem(selectAll))
    }

    @Test func copyFormatsActiveColumnAndEnforcesCap() {
        source.cached = true
        view.select(0x41..<0x44)  // "ABC"
        NSPasteboard.general.clearContents()
        view.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "41 42 43")

        view.insertTab(nil)
        #expect(view.activeColumn == .text)
        view.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "ABC")

        final class HugeSource: HexViewDataSource {
            var length: UInt64 { UInt64(HexCopy.maxBytes) + 10 }
            func cachedBytes(_ range: Range<UInt64>) -> Data? { nil }
            func prefetch(_ range: Range<UInt64>, completion: @escaping @MainActor (Error?) -> Void)
            {
                completion(nil)
            }
            func read(_ range: Range<UInt64>) throws -> Data { Data() }
        }
        let huge = HugeSource()
        view.dataSource = huge
        view.selectAll(nil)
        view.copy(nil)
        #expect(spy.tooLargeRanges == [0..<huge.length])
    }

    @Test func selectionModifiersAndHorizontalScrolling() throws {
        let fixture = PartialLastRow(), view = fixture.view
        view.go(to: 16)
        view.moveRightAndModifySelection(nil)
        view.moveRightAndModifySelection(nil)
        #expect(view.selection.range == 16..<19)
        view.moveToBeginningOfLine(nil)
        #expect(view.selection.range == 16..<17)
        view.moveToBeginningOfDocument(nil)
        #expect(view.selection.cursor == 0)

        // Wide layout in a 600 pt view needs horizontal scrolling; 8 bytes/row fits.
        view.options.bytesPerRow = .fixed(8)
        #expect(view.horizontalScroller.isHidden)
        view.options.bytesPerRow = .fixed(32)
        #expect(!view.horizontalScroller.isHidden)
        #expect(view.maxHorizontalOffset > 0)

        // Horizontal offset shifts hit-testing to match the scrolled columns.
        let shift = 5.0 * view.charWidth
        view.setHorizontalOffset(shift)
        let x = view.inset.left + Double(view.layout.hexCell(10)) * view.charWidth - shift + 1
        let y = view.inset.top + view.rowHeight * 0.5
        let hit = try #require(view.offset(at: NSPoint(x: x, y: y)))
        #expect(hit == (10, .hex))

        // Selecting a match on a partially clipped bottom row reveals it fully.
        view.options.bytesPerRow = .fixed(16)
        view.position.setOffset(view.rowHeight / 2)
        let lastVisible = view.position.visibleRows.upperBound - 1
        view.select(view.layout.rowStart(lastVisible)..<(view.layout.rowStart(lastVisible) + 2))
        let rowBottom = Double(lastVisible + 1) * view.rowHeight
        #expect(rowBottom <= view.position.offset + view.position.viewHeight + 0.01)
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
