import AppKit

/// Where a hex view gets its bytes. `cachedBytes` must never block (it's called while
/// drawing); `prefetch` loads in the background and calls back on the main actor.
@MainActor
public protocol HexViewDataSource: AnyObject {
    var length: UInt64 { get }
    func cachedBytes(_ range: Range<UInt64>) -> Data?
    func prefetch(_ range: Range<UInt64>, completion: @escaping @MainActor () -> Void)
    /// Blocking read, used for copying a selection.
    func read(_ range: Range<UInt64>) throws -> Data
}

@MainActor
public protocol HexViewDelegate: AnyObject {
    func hexViewSelectionDidChange(_ view: HexView)
    /// A copy was refused because the selection exceeds `HexCopy.maxBytes`.
    func hexView(_ view: HexView, selectionTooLargeToCopy range: Range<UInt64>)
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

    public var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { relayout(keepingRow: true) }
    }

    public internal(set) var layout = HexLayout(options: HexViewOptions(), length: 0)
    public internal(set) var selection = HexSelection(length: 0)
    /// Ranges drawn with the find highlight (all matches), sorted and non-overlapping.
    public var highlights: [Range<UInt64>] = [] {
        didSet { needsDisplay = true }
    }
    /// The column the cursor and copy work in; Tab switches it.
    public internal(set) var activeColumn: HexLayout.Column = .hex

    var position = HexScrollPosition(rowCount: 1, rowHeight: 16, viewHeight: 0)
    var charWidth: Double = 8
    var rowHeight: Double = 16
    let inset = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 4)
    let scroller = NSScroller()
    var pendingPrefetch: Range<UInt64>?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        // Since macOS 14 views don't clip by default; without this the background
        // fill and partly scrolled rows paint over the tab bar above the view.
        clipsToBounds = true
        scroller.scrollerStyle = .legacy
        scroller.knobStyle = .default
        scroller.isEnabled = true
        scroller.target = self
        scroller.action = #selector(scrollerMoved(_:))
        addSubview(scroller)
        setAccessibilityRole(.textArea)
        relayout(keepingRow: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public var length: UInt64 { dataSource?.length ?? 0 }

    /// Call after the data source's content changed.
    public func reloadData() {
        selection = HexSelection(length: length)
        pendingPrefetch = nil
        relayout(keepingRow: false)
        delegate?.hexViewSelectionDidChange(self)
    }

    // MARK: Geometry

    var contentHeight: Double { max(0, Double(bounds.height) - inset.top - inset.bottom) }

    var scrollerWidth: CGFloat {
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    func relayout(keepingRow: Bool) {
        let ascent = Double(font.ascender), descent = Double(-font.descender)
        charWidth = Double(
            ("0" as NSString).size(withAttributes: [.font: font]).width)
        rowHeight = (ascent + descent + Double(font.leading)).rounded(.up) + 3
        let textWidth = Double(bounds.width - scrollerWidth) - inset.left - inset.right
        let topOffset = keepingRow ? layout.rowStart(position.topRow) : 0
        layout = HexLayout(
            options: options, length: length,
            availableCells: max(0, Int(textWidth / max(charWidth, 1))))
        position = HexScrollPosition(
            rowCount: layout.rowCount, rowHeight: rowHeight, viewHeight: contentHeight)
        if keepingRow { position.scrollToTop(row: layout.row(of: topOffset)) }
        updateScroller()
        needsDisplay = true
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        scroller.frame = NSRect(
            x: bounds.width - scrollerWidth, y: 0, width: scrollerWidth, height: bounds.height)
        if case .autoFit = options.bytesPerRow, oldSize.width != bounds.width {
            relayout(keepingRow: true)
        } else {
            position.setViewHeight(contentHeight)
            updateScroller()
        }
    }

    // MARK: Scrolling

    func updateScroller() {
        scroller.knobProportion = CGFloat(position.knobProportion)
        scroller.doubleValue = position.knobValue
        scroller.isEnabled = position.maxOffset > 0
    }

    @objc func scrollerMoved(_ sender: NSScroller) {
        switch sender.hitPart {
        case .decrementPage: position.scroll(by: -contentHeight)
        case .incrementPage: position.scroll(by: contentHeight)
        default: position.setKnobValue(sender.doubleValue)
        }
        didScroll()
    }

    public override func scrollWheel(with event: NSEvent) {
        let delta =
            event.hasPreciseScrollingDeltas
            ? Double(event.scrollingDeltaY) : Double(event.scrollingDeltaY) * rowHeight * 3
        guard delta != 0 else { return super.scrollWheel(with: event) }
        position.scroll(by: -delta)
        didScroll()
    }

    func didScroll() {
        updateScroller()
        needsDisplay = true
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
    /// off screen.
    public func select(_ range: Range<UInt64>) {
        selection.select(range)
        let row = layout.row(of: range.lowerBound)
        if !position.visibleRows.contains(row) {
            let lead = UInt64(max(0, position.viewHeight / rowHeight / 3))
            position.scrollToTop(row: row >= lead ? row - lead : 0)
        }
        selectionChanged(reveal: false)
    }

    func selectionChanged(reveal: Bool) {
        if reveal { position.reveal(row: layout.row(of: selection.cursor)) }
        didScroll()
        delegate?.hexViewSelectionDidChange(self)
    }
}
