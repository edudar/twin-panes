import AppKit

/// Keyboard, mouse and copy. Keys arrive as standard AppKit commands through
/// `interpretKeyEvents`, so the system key bindings apply (⌘↑ is
/// `moveToBeginningOfDocument:`, ⇧→ is `moveRightAndModifySelection:`, and so on).
extension HexView: NSMenuItemValidation {
    public override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    public override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    public override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    private var rowBytes: Int64 { Int64(layout.bytesPerRow) }
    private var pageBytes: Int64 {
        rowBytes * max(1, Int64(position.viewHeight / rowHeight) - 1)
    }

    private func moveCursor(by delta: Int64, extending: Bool) {
        selection.move(by: delta, extending: extending)
        selectionChanged(reveal: true)
    }

    private func moveCursor(to offset: UInt64, extending: Bool) {
        selection.move(to: offset, extending: extending)
        selectionChanged(reveal: true)
    }

    private var rowStartOfCursor: UInt64 { layout.rowStart(layout.row(of: selection.cursor)) }

    public override func moveLeft(_ sender: Any?) { moveCursor(by: -1, extending: false) }
    public override func moveRight(_ sender: Any?) { moveCursor(by: 1, extending: false) }
    public override func moveUp(_ sender: Any?) { moveCursor(by: -rowBytes, extending: false) }
    public override func moveDown(_ sender: Any?) { moveCursor(by: rowBytes, extending: false) }
    public override func moveLeftAndModifySelection(_ sender: Any?) {
        moveCursor(by: -1, extending: true)
    }
    public override func moveRightAndModifySelection(_ sender: Any?) {
        moveCursor(by: 1, extending: true)
    }
    public override func moveUpAndModifySelection(_ sender: Any?) {
        moveCursor(by: -rowBytes, extending: true)
    }
    public override func moveDownAndModifySelection(_ sender: Any?) {
        moveCursor(by: rowBytes, extending: true)
    }
    public override func pageUp(_ sender: Any?) { moveCursor(by: -pageBytes, extending: false) }
    public override func pageDown(_ sender: Any?) { moveCursor(by: pageBytes, extending: false) }
    public override func pageUpAndModifySelection(_ sender: Any?) {
        moveCursor(by: -pageBytes, extending: true)
    }
    public override func pageDownAndModifySelection(_ sender: Any?) {
        moveCursor(by: pageBytes, extending: true)
    }
    public override func moveToBeginningOfLine(_ sender: Any?) {
        moveCursor(to: rowStartOfCursor, extending: false)
    }
    public override func moveToEndOfLine(_ sender: Any?) {
        moveCursor(to: rowStartOfCursor + UInt64(rowBytes - 1), extending: false)
    }
    public override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
        moveCursor(to: rowStartOfCursor, extending: true)
    }
    public override func moveToEndOfLineAndModifySelection(_ sender: Any?) {
        moveCursor(to: rowStartOfCursor + UInt64(rowBytes - 1), extending: true)
    }
    public override func moveToBeginningOfDocument(_ sender: Any?) {
        moveCursor(to: 0, extending: false)
    }
    public override func moveToEndOfDocument(_ sender: Any?) {
        moveCursor(to: .max, extending: false)
    }
    public override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        moveCursor(to: 0, extending: true)
    }
    public override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
        moveCursor(to: .max, extending: true)
    }
    public override func scrollPageUp(_ sender: Any?) {
        position.scroll(by: -position.viewHeight)
        didScroll()
    }
    public override func scrollPageDown(_ sender: Any?) {
        position.scroll(by: position.viewHeight)
        didScroll()
    }
    public override func scrollToBeginningOfDocument(_ sender: Any?) {
        position.setOffset(0)
        didScroll()
    }
    public override func scrollToEndOfDocument(_ sender: Any?) {
        position.setOffset(position.maxOffset)
        didScroll()
    }
    public override func selectAll(_ sender: Any?) {
        selection.selectAll()
        selectionChanged(reveal: false)
    }
    /// Tab switches the active column between hex and text.
    public override func insertTab(_ sender: Any?) {
        activeColumn = activeColumn == .hex ? .text : .hex
        pendingNibble = nil
        needsDisplay = true
    }
    public override func insertBacktab(_ sender: Any?) { insertTab(sender) }

    // MARK: Mouse

    func offset(at point: NSPoint) -> (UInt64, HexLayout.Column)? {
        guard layout.length > 0 else { return nil }
        let cell = (Double(point.x) + horizontalOffset - inset.left) / charWidth
        guard let hit = layout.hit(cell: cell) else { return nil }
        let y = Double(point.y) - inset.top + position.offset
        let row = min(UInt64(max(0, y) / rowHeight), layout.rowCount - 1)
        return (min(layout.rowStart(row) + UInt64(hit.index), layout.length - 1), hit.column)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let (offset, column) = offset(at: point) else { return }
        activeColumn = column
        moveCursor(to: offset, extending: event.modifierFlags.contains(.shift))
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Dragging past the top or bottom edge scrolls.
        if point.y < 0 {
            position.scroll(by: Double(point.y))
        } else if point.y > bounds.height {
            position.scroll(by: Double(point.y - bounds.height))
        }
        let clamped = NSPoint(x: point.x, y: min(max(point.y, 0), bounds.height - 1))
        guard let (offset, _) = offset(at: clamped) else { return }
        moveCursor(to: offset, extending: true)
    }

    // MARK: Copy

    @objc public func copy(_ sender: Any?) {
        copySelection(as: activeColumn == .hex ? .hex : .text(options.textEncoding))
    }

    public func copySelection(as format: HexCopy.Format) {
        let range = selection.range
        guard !range.isEmpty, let dataSource else { return }
        guard range.count <= UInt64(HexCopy.maxBytes) else {
            delegate?.hexView(self, selectionTooLargeToCopy: range)
            return
        }
        dataSource.readForCopy(range) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                let text = HexCopy.string(data, as: format)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case .failure(let error):
                NSSound.beep()
                self.delegate?.hexView(self, didFailToRead: error)
            }
        }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): return !selection.range.isEmpty
        case #selector(selectAll(_:)): return layout.length > 0
        default: return true
        }
    }
}
