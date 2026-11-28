import AppKit

/// Where a hex view gets its bytes. `cachedBytes` must never block (it's called while
/// drawing) and returns all of `range` or nil; `prefetch` loads in the background and
/// calls back on the main actor with the error, if any.
@MainActor
public protocol HexViewDataSource: AnyObject {
    var length: UInt64 { get }
    func cachedBytes(_ range: Range<UInt64>) -> Data?
    func prefetch(_ range: Range<UInt64>, completion: @escaping @MainActor (Error?) -> Void)
    /// Blocking read, used for small synchronous reads.
    func read(_ range: Range<UInt64>) throws -> Data
    /// Uncached read for copying a selection without evicting the view's page cache.
    func readForCopy(
        _ range: Range<UInt64>, completion: @escaping @MainActor (Result<Data, Error>) -> Void)
    /// The parts of `range` holding edited bytes, sorted, for the changed-bytes fill.
    func modifiedRanges(in range: Range<UInt64>) -> [Range<UInt64>]
}

extension HexViewDataSource {
    public func readForCopy(
        _ range: Range<UInt64>, completion: @escaping @MainActor (Result<Data, Error>) -> Void
    ) {
        completion(Result { try read(range) })
    }

    public func modifiedRanges(in range: Range<UInt64>) -> [Range<UInt64>] { [] }
}

@MainActor
public protocol HexViewDelegate: AnyObject {
    func hexViewSelectionDidChange(_ view: HexView)
    /// A copy was refused because the selection exceeds `HexCopy.maxBytes`.
    func hexView(_ view: HexView, selectionTooLargeToCopy range: Range<UInt64>)
    /// Loading the bytes to show failed. Called once per failed range; the view shows
    /// placeholders and doesn't retry that range until it scrolls or reloads.
    func hexView(_ view: HexView, didFailToRead error: Error)
    /// A background prefetch landed and the view is about to redraw with the new bytes.
    func hexViewDidLoadBytes(_ view: HexView)
    /// Called before an edit reads uncached bytes from `dataSource`, so the delegate can
    /// refuse (for example, starting an iCloud download before a synchronous read would
    /// block). Return false to refuse (the view beeps).
    func hexViewWillBeginEdit(_ view: HexView) -> Bool
    /// Typing asks to overwrite `bytes` at `offset` from `column`; the cursor then moves
    /// to `cursorAfter`. Return false to refuse (the view beeps). By default views are
    /// read-only.
    func hexView(
        _ view: HexView, overwrite bytes: Data, at offset: UInt64, column: HexLayout.Column,
        cursorAfter: UInt64
    ) -> Bool
    /// A character typed in the text column that its encoding can't represent.
    func hexView(_ view: HexView, cannotEncode character: Character)
    /// The active column switched between hex and text (e.g. via Tab).
    func hexViewDidChangeColumn(_ view: HexView)
    /// The scroll position changed.
    func hexViewDidScroll(_ view: HexView)
}

extension HexViewDelegate {
    public func hexView(_ view: HexView, didFailToRead error: Error) {}
    public func hexViewDidLoadBytes(_ view: HexView) {}
    public func hexViewWillBeginEdit(_ view: HexView) -> Bool { true }
    public func hexView(
        _ view: HexView, overwrite bytes: Data, at offset: UInt64, column: HexLayout.Column,
        cursorAfter: UInt64
    ) -> Bool { false }
    public func hexView(_ view: HexView, cannotEncode character: Character) {}
    public func hexViewDidChangeColumn(_ view: HexView) {}
    public func hexViewDidScroll(_ view: HexView) {}
}

/// Virtualized hex/text view (PLAN.md §4.4). The view is window-sized and draws only
/// the visible rows; a `HexScrollPosition` maps the scroller and wheel to a pixel
/// offset into the full content, so 4 GB files scroll without a giant document view.
/// Rows whose bytes aren't cached yet draw as placeholders and redraw when they land.
@MainActor
public final class HexView: NSView {
    public weak var dataSource: HexViewDataSource? {
        didSet { reloadData() }
    }
    public weak var delegate: HexViewDelegate?

    public var options = HexViewOptions() {
        didSet { if options != oldValue { relayout(keepingRow: true) } }
    }

    private static let defaultFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    public var font = HexView.defaultFont {
        didSet {
            guard font != oldValue else { return }
            rebuildGlyphTable()
            relayout(keepingRow: true)
        }
    }

    public internal(set) var layout = HexLayout(options: HexViewOptions(), length: 0)
    public internal(set) var selection = HexSelection(length: 0)
    /// Ranges drawn with the find highlight (all matches), sorted and non-overlapping.
    public var highlights: [Range<UInt64>] = [] {
        didSet { needsDisplay = true }
    }
    /// Typing inserts before the cursor, which may also sit after the last byte and is
    /// drawn as a bar (docs/plans/M8.md, D-g); off, typing overwrites and the cursor is a
    /// box on a byte.
    public var isInsertMode = false {
        didSet {
            guard isInsertMode != oldValue else { return }
            selection.includesEndPosition = isInsertMode
            pendingNibble = nil
            relayout(keepingRow: true)
            delegate?.hexViewSelectionDidChange(self)
        }
    }
    /// The column the cursor and copy work in; Tab switches it.
    public internal(set) var activeColumn: HexLayout.Column = .hex

    var position = HexScrollPosition(rowCount: 1, rowHeight: 16, viewHeight: 0)
    var horizontalOffset: Double = 0
    var glyphTable = HexGlyphTable(font: HexView.defaultFont)
    private(set) var glyphTableBuilds = 1
    var charWidth: Double = 8
    var rowHeight: Double = 16
    let inset = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 4)
    // An NSScroller takes its orientation from the frame it's created with and keeps it,
    // so each starts with a frame of the right shape; `layoutScrollers` sizes them.
    let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 100))
    let horizontalScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 100, height: 15))
    var pendingPrefetch: Range<UInt64>?
    /// The last prefetch range that failed; not asked for again until the view needs a
    /// different range or reloads, so a persistent read error can't loop.
    var failedPrefetch: Range<UInt64>?
    /// The byte whose high nibble was just typed in the hex column; the next hex digit
    /// sets its low nibble. Any cursor move clears it.
    var pendingNibble: UInt64?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        // Since macOS 14 views don't clip by default; without this the background
        // fill and partly scrolled rows paint over the tab bar above the view.
        clipsToBounds = true
        for bar in [scroller, horizontalScroller] {
            bar.scrollerStyle = .legacy
            bar.knobStyle = .default
            bar.isEnabled = true
            bar.target = self
            addSubview(bar)
        }
        scroller.action = #selector(scrollerMoved(_:))
        horizontalScroller.action = #selector(horizontalScrollerMoved(_:))
        setAccessibilityRole(.textArea)
        updateFontMetrics()
        relayout(keepingRow: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public var length: UInt64 { dataSource?.length ?? 0 }

    /// Call after the data source's content changed.
    public func reloadData() {
        selection = HexSelection(length: length, includesEndPosition: isInsertMode)
        horizontalOffset = 0
        finishReload(keepingRow: false)
    }

    /// Call after the data source's length changed while keeping the scroll position.
    public func contentLengthDidChange() {
        let previous = selection
        var clamped = HexSelection(length: length, includesEndPosition: isInsertMode)
        if length > 0 || isInsertMode {
            clamped.move(to: previous.anchor)
            clamped.move(to: previous.cursor, extending: previous.anchor != previous.cursor)
        }
        selection = clamped
        finishReload(keepingRow: true)
    }

    private func finishReload(keepingRow: Bool) {
        pendingPrefetch = nil
        failedPrefetch = nil
        pendingNibble = nil
        relayout(keepingRow: keepingRow)
        delegate?.hexViewSelectionDidChange(self)
    }

    // MARK: Geometry

    var scrollerWidth: CGFloat {
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    var viewportWidth: Double { max(0, Double(bounds.width - scrollerWidth)) }

    var contentWidth: Double {
        Double(layout.totalCells) * charWidth + inset.left + inset.right
    }

    var maxHorizontalOffset: Double { max(0, contentWidth - viewportWidth) }

    var horizontalScrollerHeight: CGFloat { maxHorizontalOffset > 0 ? scrollerWidth : 0 }

    var contentHeight: Double {
        max(0, Double(bounds.height - horizontalScrollerHeight) - inset.top - inset.bottom)
    }

    private func rebuildGlyphTable() {
        glyphTable = HexGlyphTable(font: font)
        glyphTableBuilds += 1
        updateFontMetrics()
    }

    private func updateFontMetrics() {
        let ascent = Double(font.ascender), descent = Double(-font.descender)
        charWidth = glyphTable.advance
        rowHeight = (ascent + descent + Double(font.leading)).rounded(.up) + 3
    }

    func relayout(keepingRow: Bool) {
        let textWidth = viewportWidth - inset.left - inset.right
        let topOffset = keepingRow ? layout.rowStart(position.topRow) : 0
        layout = HexLayout(
            options: options, length: length,
            availableCells: max(0, Int(textWidth / max(charWidth, 1))),
            includesEndPosition: isInsertMode)
        position = HexScrollPosition(
            rowCount: layout.rowCount, rowHeight: rowHeight, viewHeight: contentHeight)
        if keepingRow { position.scrollToTop(row: layout.row(of: topOffset)) }
        horizontalOffset = min(horizontalOffset, maxHorizontalOffset)
        layoutScrollers()
        updateScroller()
        needsDisplay = true
    }

    func layoutScrollers() {
        let hHeight = horizontalScrollerHeight
        scroller.frame = NSRect(
            x: bounds.width - scrollerWidth, y: 0, width: scrollerWidth,
            height: max(0, bounds.height - hHeight))
        horizontalScroller.isHidden = hHeight == 0
        horizontalScroller.frame = NSRect(
            x: 0, y: bounds.height - scrollerWidth, width: max(0, bounds.width - scrollerWidth),
            height: scrollerWidth)
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        if case .autoFit = options.bytesPerRow, oldSize.width != bounds.width {
            relayout(keepingRow: true)
        } else {
            horizontalOffset = min(horizontalOffset, maxHorizontalOffset)
            layoutScrollers()
            position.setViewHeight(contentHeight)
            updateScroller()
        }
    }

    // MARK: Scrolling

    func updateScroller() {
        scroller.knobProportion = CGFloat(position.knobProportion)
        scroller.doubleValue = position.knobValue
        scroller.isEnabled = position.maxOffset > 0
        let maxH = maxHorizontalOffset
        horizontalScroller.knobProportion =
            contentWidth > 0 ? CGFloat(min(1, viewportWidth / contentWidth)) : 1
        horizontalScroller.doubleValue = maxH > 0 ? horizontalOffset / maxH : 0
        horizontalScroller.isEnabled = maxH > 0
    }

    func setHorizontalOffset(_ value: Double) {
        horizontalOffset = min(max(0, value), maxHorizontalOffset)
    }

    @objc func scrollerMoved(_ sender: NSScroller) {
        switch sender.hitPart {
        case .decrementPage: position.scroll(by: -contentHeight)
        case .incrementPage: position.scroll(by: contentHeight)
        default: position.setKnobValue(sender.doubleValue)
        }
        didScroll()
    }

    @objc func horizontalScrollerMoved(_ sender: NSScroller) {
        switch sender.hitPart {
        case .decrementPage: setHorizontalOffset(horizontalOffset - viewportWidth)
        case .incrementPage: setHorizontalOffset(horizontalOffset + viewportWidth)
        default:
            setHorizontalOffset(
                (min(max(0, sender.doubleValue), 1) * maxHorizontalOffset).rounded())
        }
        didScroll()
    }

    public override func scrollWheel(with event: NSEvent) {
        let dy =
            event.hasPreciseScrollingDeltas
            ? Double(event.scrollingDeltaY) : Double(event.scrollingDeltaY) * rowHeight * 3
        let dx =
            event.hasPreciseScrollingDeltas
            ? Double(event.scrollingDeltaX) : Double(event.scrollingDeltaX) * charWidth * 3
        guard dy != 0 || dx != 0 else { return super.scrollWheel(with: event) }
        if dy != 0 { position.scroll(by: -dy) }
        if dx != 0 { setHorizontalOffset(horizontalOffset - dx) }
        didScroll()
    }

    func didScroll() {
        updateScroller()
        needsDisplay = true
        window?.invalidateRestorableState()
        delegate?.hexViewDidScroll(self)
    }

    /// The first row at least partly on screen.
    public var topRow: UInt64 { position.topRow }

    /// Scrolls so `row` is the top row, as far as the content allows.
    public func scroll(toTopRow row: UInt64) {
        position.scrollToTop(row: row)
        didScroll()
    }

    /// Moves the cursor to `offset` and scrolls it into view, a third from the top.
    public func go(to offset: UInt64) {
        selection.move(to: offset)
        let row = layout.row(of: selection.cursor)
        let lead = UInt64(max(0, position.viewHeight / rowHeight / 3))
        position.scrollToTop(row: row >= lead ? row - lead : 0)
        selectionChanged(reveal: true)
    }

    /// Selects `range` and scrolls its start into view, a third from the top if it was
    /// off screen, or minimally if its row was partly clipped.
    public func select(_ range: Range<UInt64>) {
        selection.select(range)
        let row = layout.row(of: range.lowerBound)
        if !position.visibleRows.contains(row) {
            let lead = UInt64(max(0, position.viewHeight / rowHeight / 3))
            position.scrollToTop(row: row >= lead ? row - lead : 0)
        } else {
            position.reveal(row: row)
        }
        selectionChanged(reveal: false)
    }

    /// Drops any half-typed hex byte marker without moving the selection.
    public func clearPendingNibble() {
        guard pendingNibble != nil else { return }
        pendingNibble = nil
        needsDisplay = true
    }

    func selectionChanged(reveal: Bool, pendingNibble nibble: UInt64? = nil) {
        pendingNibble = nibble
        if reveal {
            position.reveal(row: layout.row(of: selection.cursor))
            revealCursorHorizontally()
        }
        didScroll()
        delegate?.hexViewSelectionDidChange(self)
    }

    private func revealCursorHorizontally() {
        guard maxHorizontalOffset > 0, layout.length > 0 else { return }
        let rowStart = layout.rowStart(layout.row(of: selection.cursor))
        let colIndex = Int(selection.cursor - rowStart)
        let leftCell = activeColumn == .hex ? layout.hexCell(colIndex) : layout.textCell(colIndex)
        let widthCells = activeColumn == .hex ? 2 : 1
        let leftX = inset.left + Double(leftCell) * charWidth
        let rightX = inset.left + Double(leftCell + widthCells) * charWidth + 4
        if leftX < horizontalOffset {
            setHorizontalOffset(leftX - inset.left)
        } else if rightX > horizontalOffset + viewportWidth {
            setHorizontalOffset(rightX - viewportWidth)
        }
    }
}
