import AppKit

/// View menu actions and checkmark validation for `ReadOnlyHexViewController`, matching
/// `HexEditorViewController`.
extension ReadOnlyHexViewController: NSMenuItemValidation {
    @objc public func setBytesPerRow(_ sender: Any?) {
        guard let value = (sender as? NSMenuItem)?.representedObject as? Int else { return }
        hexView.options.bytesPerRow = value == 0 ? .autoFit : .fixed(value)
        preferences?.options = hexView.options
    }

    @objc public func setGrouping(_ sender: Any?) {
        guard let value = (sender as? NSMenuItem)?.representedObject as? Int else { return }
        hexView.options.grouping = value
        preferences?.options = hexView.options
    }

    @objc public func setOffsetBase(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
            let base = HexViewOptions.OffsetBase(rawValue: raw)
        else { return }
        hexView.options.offsetBase = base
        preferences?.options = hexView.options
    }

    @objc public func setTextEncoding(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
            let encoding = HexViewOptions.TextEncoding(rawValue: raw)
        else { return }
        hexView.options.textEncoding = encoding
        preferences?.options = hexView.options
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let options = hexView.options
        let value = menuItem.representedObject
        switch menuItem.action {
        case #selector(setBytesPerRow(_:)):
            let current = if case .fixed(let count) = options.bytesPerRow { count } else { 0 }
            menuItem.state = (value as? Int) == current ? .on : .off
            return !hexView.isHidden
        case #selector(setGrouping(_:)):
            menuItem.state = (value as? Int) == options.grouping ? .on : .off
            return !hexView.isHidden
        case #selector(setOffsetBase(_:)):
            menuItem.state = (value as? String) == options.offsetBase.rawValue ? .on : .off
            return !hexView.isHidden
        case #selector(setTextEncoding(_:)):
            menuItem.state = (value as? String) == options.textEncoding.rawValue ? .on : .off
            return !hexView.isHidden
        default:
            return true
        }
    }
}
