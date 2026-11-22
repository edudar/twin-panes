import AppKit

/// Overwrite typing (PLAN.md §4.4, docs/plans/M3a.md). The view works out which byte a
/// key means and asks its delegate to write it; the delegate owns the edit model.
extension HexView {
    /// Typed characters arrive here through `interpretKeyEvents`.
    public override func insertText(_ insertString: Any) {
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        for character in text where !type(character) {
            NSSound.beep()
            return
        }
    }

    /// Insert and delete come in M8; in overwrite mode these just beep.
    public override func deleteBackward(_ sender: Any?) { NSSound.beep() }
    public override func deleteForward(_ sender: Any?) { NSSound.beep() }

    /// Types one character at the start of the selection. Returns false if the key
    /// means nothing in the active column or the delegate refused the write.
    @discardableResult
    func type(_ character: Character) -> Bool {
        guard let dataSource, layout.length > 0 else { return false }
        let offset = selection.range.lowerBound
        let next = min(offset + 1, layout.length - 1)
        let byte: UInt8
        let cursorAfter: UInt64
        var nibble: UInt64?
        switch activeColumn {
        case .hex:
            guard character.isASCII, let digit = character.hexDigitValue.map(UInt8.init),
                let current = dataSource.cachedBytes(offset..<(offset + 1))?.first
            else { return false }
            if pendingNibble == offset, selection.range.count == 1 {
                byte = current & 0xF0 | digit
                cursorAfter = next
            } else {
                byte = digit << 4 | current & 0x0F
                cursorAfter = offset
                nibble = offset
            }
        case .text:
            guard let encoded = options.textEncoding.byte(for: character) else {
                delegate?.hexView(self, cannotEncode: character)
                return false
            }
            byte = encoded
            cursorAfter = next
        }
        let column = activeColumn
        guard
            delegate?.hexView(
                self, overwrite: Data([byte]), at: offset, column: column, cursorAfter: cursorAfter)
                == true
        else { return false }
        selection.move(to: cursorAfter)
        selectionChanged(reveal: true)
        pendingNibble = nibble
        return true
    }
}
