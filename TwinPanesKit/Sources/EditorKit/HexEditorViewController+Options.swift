import AppKit
import HexViewKit

/// View options from the View menu, and menu validation (checkmarks on the current
/// choice). The menu item's `representedObject` carries the chosen value.
extension HexEditorViewController: NSMenuItemValidation {
    @objc func setBytesPerRow(_ sender: Any?) {
        guard let value = (sender as? NSMenuItem)?.representedObject as? Int else { return }
        hexView.options.bytesPerRow = value == 0 ? .autoFit : .fixed(value)
        view.window?.invalidateRestorableState()
    }

    @objc func setGrouping(_ sender: Any?) {
        guard let value = (sender as? NSMenuItem)?.representedObject as? Int else { return }
        hexView.options.grouping = value
        view.window?.invalidateRestorableState()
    }

    @objc func setOffsetBase(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
            let base = HexViewOptions.OffsetBase(rawValue: raw)
        else { return }
        hexView.options.offsetBase = base
        view.window?.invalidateRestorableState()
    }

    @objc func setTextEncoding(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
            let encoding = HexViewOptions.TextEncoding(rawValue: raw)
        else { return }
        hexView.options.textEncoding = encoding
        view.window?.invalidateRestorableState()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let options = hexView.options
        let value = menuItem.representedObject
        switch menuItem.action {
        case #selector(setBytesPerRow(_:)):
            let current: Int
            if case .fixed(let count) = options.bytesPerRow { current = count } else { current = 0 }
            menuItem.state = (value as? Int) == current ? .on : .off
        case #selector(setGrouping(_:)):
            menuItem.state = (value as? Int) == options.grouping ? .on : .off
        case #selector(setOffsetBase(_:)):
            menuItem.state = (value as? String) == options.offsetBase.rawValue ? .on : .off
        case #selector(setTextEncoding(_:)):
            menuItem.state = (value as? String) == options.textEncoding.rawValue ? .on : .off
        case #selector(copyAsHex(_:)), #selector(copyAsText(_:)), #selector(saveSelection(_:)),
            #selector(editorFindNext(_:)), #selector(editorFindPrevious(_:)),
            #selector(editorFindAll(_:)), #selector(editorUseSelectionForFind(_:)):
            return (item?.length ?? 0) > 0
        case #selector(undo(_:)):
            let can = item?.canUndo ?? false
            menuItem.title = can ? "Undo Typing" : "Undo"
            return can
        case #selector(redo(_:)):
            let can = item?.canRedo ?? false
            menuItem.title = can ? "Redo Typing" : "Redo"
            return can
        case #selector(editorSave(_:)):
            return item.map { $0.isDirty && $0.canSave } ?? false
        case #selector(editorRevertToSaved(_:)):
            return item.map { $0.isDirty && !$0.isSaving } ?? false
        case #selector(editorCloseFind(_:)):
            return !findBar.isHidden
        case #selector(toggleInspector(_:)):
            menuItem.title = inspector.isHidden ? "Show Inspector" : "Hide Inspector"
        default:
            break
        }
        return true
    }
}
