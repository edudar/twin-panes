/// Virtual scrolling for very tall content (PLAN.md §4.4): the view is window-sized and
/// the scroll position is a pixel offset into the full content height, kept as a
/// `Double`. A 4 GB file at 16 bytes and 16 px per row is ~4.3e9 px, far below the
/// 2^53 where a `Double` stops counting whole pixels exactly, so there is no drift.
public struct HexScrollPosition: Equatable, Sendable {
    public let rowCount: UInt64
    public let rowHeight: Double
    public private(set) var viewHeight: Double
    /// Pixels scrolled from the top, in `0...maxOffset`.
    public private(set) var offset: Double = 0

    public init(rowCount: UInt64, rowHeight: Double, viewHeight: Double) {
        self.rowCount = max(1, rowCount)
        self.rowHeight = max(1, rowHeight)
        self.viewHeight = max(0, viewHeight)
    }

    public var contentHeight: Double { Double(rowCount) * rowHeight }

    public var maxOffset: Double { max(0, contentHeight - viewHeight) }

    /// The first row that is at least partly visible.
    public var topRow: UInt64 { min(UInt64(offset / rowHeight), rowCount - 1) }

    /// How far the top row is scrolled up out of view, in `0..<rowHeight`.
    public var topRowInset: Double { offset - Double(topRow) * rowHeight }

    /// Rows that are at least partly visible, starting at `topRow`.
    public var visibleRows: Range<UInt64> {
        let count = UInt64(((topRowInset + viewHeight) / rowHeight).rounded(.up))
        return topRow..<min(rowCount, topRow + max(1, count))
    }

    /// Scroller knob position, 0...1.
    public var knobValue: Double { maxOffset > 0 ? offset / maxOffset : 0 }

    /// Scroller knob size as a fraction of the track.
    public var knobProportion: Double {
        contentHeight > 0 ? min(1, viewHeight / contentHeight) : 1
    }

    public mutating func setViewHeight(_ height: Double) {
        viewHeight = max(0, height)
        offset = min(offset, maxOffset)
    }

    public mutating func scroll(by pixels: Double) { setOffset(offset + pixels) }

    public mutating func setOffset(_ value: Double) { offset = min(max(0, value), maxOffset) }

    public mutating func setKnobValue(_ value: Double) {
        setOffset((min(max(0, value), 1) * maxOffset).rounded())
    }

    /// Scrolls the least amount that makes `row` fully visible.
    public mutating func reveal(row: UInt64) {
        let top = Double(row) * rowHeight
        if top < offset {
            setOffset(top)
        } else if top + rowHeight > offset + viewHeight {
            setOffset(top + rowHeight - viewHeight)
        }
    }

    /// Puts `row` at the top (or as close as the end of the content allows).
    public mutating func scrollToTop(row: UInt64) { setOffset(Double(row) * rowHeight) }
}
