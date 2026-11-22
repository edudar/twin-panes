import AppKit
import CoreText

extension HexView {
    public override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let contentRect = NSRect(
            x: 0, y: 0, width: max(0, bounds.width - scrollerWidth),
            height: max(0, bounds.height - horizontalScrollerHeight))
        context.saveGState()
        context.clip(to: contentRect)
        defer { context.restoreGState() }

        let rows = position.visibleRows
        let first = layout.rowStart(rows.lowerBound)
        let end = min(layout.length, layout.rowStart(rows.upperBound))
        // Only cache hits here: drawing never waits on disk (§4.1). Anything shorter
        // than asked for (a file that got shorter) counts as not there.
        let visible =
            first < end
            ? dataSource?.cachedBytes(first..<end).flatMap {
                $0.count == Int(end - first) ? $0 : nil
            }
            : Data()
        if visible == nil { requestPrefetch(rows) }

        let isFocused = window?.firstResponder === self && window?.isKeyWindow == true
        // Pre-sized buffers shared across all visible rows for Core Text drawing.
        let maxDataGlyphs = layout.bytesPerRow * 3
        var offsetGlyphs: [CGGlyph] = []
        var offsetPositions: [CGPoint] = []
        offsetGlyphs.reserveCapacity(layout.offsetCells)
        offsetPositions.reserveCapacity(layout.offsetCells)
        var dataGlyphs: [CGGlyph] = []
        var dataPositions: [CGPoint] = []
        dataGlyphs.reserveCapacity(maxDataGlyphs)
        dataPositions.reserveCapacity(maxDataGlyphs)

        for (index, row) in rows.enumerated() {
            let y = inset.top + Double(index) * rowHeight - position.topRowInset
            let start = layout.rowStart(row)
            let rowEnd = min(layout.length, start + UInt64(layout.bytesPerRow))
            let bytes: Data?
            if let visible {
                let from = Int(start - first), to = Int(rowEnd - first)
                bytes = from <= to ? visible.subdata(in: from..<to) : Data()
            } else {
                bytes =
                    start < rowEnd
                    ? dataSource?.cachedBytes(start..<rowEnd).flatMap {
                        $0.count == Int(rowEnd - start) ? $0 : nil
                    } : Data()
            }
            drawSelection(row: row, y: y, focused: isFocused)
            drawRow(
                row: row, bytes: bytes, count: Int(rowEnd - start), y: y, in: context,
                offsetGlyphs: &offsetGlyphs, offsetPositions: &offsetPositions,
                dataGlyphs: &dataGlyphs, dataPositions: &dataPositions)
        }
    }

    private func x(cell: Int) -> Double { inset.left + Double(cell) * charWidth - horizontalOffset }

    private func drawSelection(row: UInt64, y: Double, focused: Bool) {
        guard layout.length > 0 else { return }
        let rowRange = layout.rowStart(row)..<(layout.rowStart(row) + UInt64(layout.bytesPerRow))
        NSColor.findHighlightColor.withAlphaComponent(0.6).setFill()
        var match = highlights.partitioningIndex { $0.upperBound > rowRange.lowerBound }
        while match < highlights.count, highlights[match].lowerBound < rowRange.upperBound {
            fill(highlights[match].clamped(to: rowRange), in: rowRange, y: y)
            match += 1
        }
        let fill =
            focused
            ? NSColor.selectedTextBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor
        fill.setFill()
        self.fill(selection.range.clamped(to: rowRange), in: rowRange, y: y)
        // Cursor: an outline in the active column, a lighter one in the other.
        guard rowRange.contains(selection.cursor) else { return }
        let index = Int(selection.cursor - rowRange.lowerBound)
        let hexBox = NSRect(
            x: x(cell: layout.hexCell(index)) - 2, y: y, width: 2 * charWidth + 4,
            height: rowHeight)
        let textBox = NSRect(
            x: x(cell: layout.textCell(index)), y: y, width: charWidth, height: rowHeight)
        for (box, active) in [(hexBox, activeColumn == .hex), (textBox, activeColumn == .text)] {
            (active ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
            let path = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = active ? 1.5 : 1
            path.stroke()
        }
    }

    /// Fills the hex and text cells of `range`, which lies within the row `rowRange`.
    private func fill(_ range: Range<UInt64>, in rowRange: Range<UInt64>, y: Double) {
        guard !range.isEmpty else { return }
        let a = Int(range.lowerBound - rowRange.lowerBound)
        let b = Int(range.upperBound - rowRange.lowerBound) - 1
        NSRect(
            x: x(cell: layout.hexCell(a)) - 2, y: y,
            width: Double(layout.hexCell(b) + 2 - layout.hexCell(a)) * charWidth + 4,
            height: rowHeight
        ).fill()
        NSRect(
            x: x(cell: layout.textCell(a)), y: y,
            width: Double(b - a + 1) * charWidth, height: rowHeight
        ).fill()
    }

    private func drawRow(
        row: UInt64, bytes: Data?, count: Int, y: Double, in context: CGContext,
        offsetGlyphs: inout [CGGlyph], offsetPositions: inout [CGPoint],
        dataGlyphs: inout [CGGlyph], dataPositions: inout [CGPoint]
    ) {
        let baselineY = y + glyphTable.baselineOffset
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        // Offset gutter.
        offsetGlyphs.removeAll(keepingCapacity: true)
        offsetPositions.removeAll(keepingCapacity: true)
        let label = layout.offsetLabel(layout.rowStart(row))
        for (cell, byte) in label.utf8.enumerated() {
            offsetGlyphs.append(glyphTable.glyph(for: byte))
            offsetPositions.append(CGPoint(x: x(cell: cell), y: baselineY))
        }
        context.setFillColor(NSColor.secondaryLabelColor.cgColor)
        CTFontDrawGlyphs(
            glyphTable.ctFont, offsetGlyphs, offsetPositions, offsetGlyphs.count, context)

        guard count > 0 else { return }

        // Hex and text columns in one Core Text draw call.
        dataGlyphs.removeAll(keepingCapacity: true)
        dataPositions.removeAll(keepingCapacity: true)
        let encoding = options.textEncoding
        for index in 0..<count {
            let hexCell = layout.hexCell(index)
            let textCell = layout.textCell(index)
            if let bytes {
                let byte = bytes[bytes.startIndex + index]
                dataGlyphs.append(glyphTable.hexDigits[Int(byte >> 4)])
                dataPositions.append(CGPoint(x: x(cell: hexCell), y: baselineY))
                dataGlyphs.append(glyphTable.hexDigits[Int(byte & 0x0F)])
                dataPositions.append(CGPoint(x: x(cell: hexCell + 1), y: baselineY))
                dataGlyphs.append(glyphTable.textGlyph(for: byte, encoding: encoding))
                dataPositions.append(CGPoint(x: x(cell: textCell), y: baselineY))
            } else {
                let dot = glyphTable.placeholder
                dataGlyphs.append(dot)
                dataPositions.append(CGPoint(x: x(cell: hexCell), y: baselineY))
                dataGlyphs.append(dot)
                dataPositions.append(CGPoint(x: x(cell: hexCell + 1), y: baselineY))
                dataGlyphs.append(dot)
                dataPositions.append(CGPoint(x: x(cell: textCell), y: baselineY))
            }
        }
        let color = bytes == nil ? NSColor.tertiaryLabelColor : NSColor.labelColor
        context.setFillColor(color.cgColor)
        CTFontDrawGlyphs(glyphTable.ctFont, dataGlyphs, dataPositions, dataGlyphs.count, context)
    }

    /// Asks the data source for the visible rows plus one screen above and below.
    func requestPrefetch(_ rows: Range<UInt64>) {
        guard let dataSource else { return }
        let visible =
            layout.rowStart(rows.lowerBound)..<min(layout.length, layout.rowStart(rows.upperBound))
        let margin = UInt64(rows.count)
        let from = rows.lowerBound >= margin ? rows.lowerBound - margin : 0
        let to = min(layout.rowCount, rows.upperBound + margin)
        let range = layout.rowStart(from)..<min(layout.length, layout.rowStart(to))
        let covered =
            pendingPrefetch.map {
                $0.lowerBound <= visible.lowerBound && visible.upperBound <= $0.upperBound
            } ?? false
        guard !range.isEmpty, range != failedPrefetch, !covered else { return }
        pendingPrefetch = range
        dataSource.prefetch(range) { [weak self] error in
            guard let self else { return }
            if self.pendingPrefetch == range { self.pendingPrefetch = nil }
            if let error {
                // Placeholders stay; no redraw, which would only ask again.
                self.failedPrefetch = range
                self.delegate?.hexView(self, didFailToRead: error)
            } else {
                self.failedPrefetch = nil
                self.needsDisplay = true
                self.delegate?.hexViewDidLoadBytes(self)
            }
        }
    }
}

extension Array where Element == Range<UInt64> {
    /// The first index whose element satisfies `predicate`, for a predicate that is false
    /// for a prefix of the array and true for the rest (binary search over sorted ranges,
    /// such as `HexView.highlights`).
    public func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
