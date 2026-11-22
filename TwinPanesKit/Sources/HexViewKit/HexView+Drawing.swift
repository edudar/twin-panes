import AppKit

extension HexView {
    public override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()

        let rows = position.visibleRows
        let first = layout.rowStart(rows.lowerBound)
        let end = min(layout.length, layout.rowStart(rows.upperBound))
        // Only cache hits here: drawing never waits on disk (§4.1).
        let visible = first < end ? dataSource?.cachedBytes(first..<end) : Data()
        if visible == nil { requestPrefetch(rows) }

        let isFocused = window?.firstResponder === self && window?.isKeyWindow == true
        for (index, row) in rows.enumerated() {
            let y = inset.top + Double(index) * rowHeight - position.topRowInset
            let start = layout.rowStart(row)
            let rowEnd = min(layout.length, start + UInt64(layout.bytesPerRow))
            let bytes: Data?
            if let visible {
                let from = Int(start - first), to = Int(rowEnd - first)
                bytes = from <= to ? visible.subdata(in: from..<to) : Data()
            } else {
                bytes = start < rowEnd ? dataSource?.cachedBytes(start..<rowEnd) : Data()
            }
            drawSelection(row: row, y: y, focused: isFocused)
            drawRow(row: row, bytes: bytes, count: Int(rowEnd - start), y: y)
        }
    }

    private func x(cell: Int) -> Double { inset.left + Double(cell) * charWidth }

    private func drawSelection(row: UInt64, y: Double, focused: Bool) {
        guard layout.length > 0 else { return }
        let rowRange = layout.rowStart(row)..<(layout.rowStart(row) + UInt64(layout.bytesPerRow))
        let selected = selection.range.clamped(to: rowRange)
        let fill =
            focused
            ? NSColor.selectedTextBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor
        if !selected.isEmpty {
            fill.setFill()
            let a = Int(selected.lowerBound - rowRange.lowerBound)
            let b = Int(selected.upperBound - rowRange.lowerBound) - 1
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

    private func drawRow(row: UInt64, bytes: Data?, count: Int, y: Double) {
        let baseline = NSPoint(x: 0, y: y + 1.5)
        let primary: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor,
        ]
        let secondary: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let faint: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        (layout.offsetLabel(layout.rowStart(row)) as NSString)
            .draw(at: NSPoint(x: x(cell: 0), y: baseline.y), withAttributes: secondary)
        guard count > 0 else { return }

        // Build each column as one string with spaces where the layout puts gaps.
        let hexWidth = layout.hexCell(count - 1) + 2 - layout.hexStart
        var hex = [Character](repeating: " ", count: hexWidth)
        var text = [Character](repeating: " ", count: count)
        let digits = Array("0123456789ABCDEF")
        let dot: Character = "·"
        for index in 0..<count {
            let at = layout.hexCell(index) - layout.hexStart
            if let bytes {
                let byte = bytes[bytes.startIndex + index]
                hex[at] = digits[Int(byte >> 4)]
                hex[at + 1] = digits[Int(byte & 0x0F)]
                text[index] = options.textEncoding.character(for: byte) ?? "."
            } else {
                hex[at] = dot
                hex[at + 1] = dot
                text[index] = dot
            }
        }
        let style = bytes == nil ? faint : primary
        (String(hex) as NSString)
            .draw(at: NSPoint(x: x(cell: layout.hexStart), y: baseline.y), withAttributes: style)
        (String(text) as NSString)
            .draw(at: NSPoint(x: x(cell: layout.textStart), y: baseline.y), withAttributes: style)
    }

    /// Asks the data source for the visible rows plus one screen above and below.
    func requestPrefetch(_ rows: Range<UInt64>) {
        guard let dataSource else { return }
        let margin = UInt64(rows.count)
        let from = rows.lowerBound >= margin ? rows.lowerBound - margin : 0
        let to = min(layout.rowCount, rows.upperBound + margin)
        let range = layout.rowStart(from)..<min(layout.length, layout.rowStart(to))
        guard !range.isEmpty, pendingPrefetch.map({ !$0.contains(range.lowerBound) }) ?? true
        else { return }
        pendingPrefetch = range
        dataSource.prefetch(range) { [weak self] in
            guard let self else { return }
            if self.pendingPrefetch == range { self.pendingPrefetch = nil }
            self.needsDisplay = true
        }
    }
}
