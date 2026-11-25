import AppKit
import TwinPanesCore

/// A file command a browser sends on (docs/plans/M6.md, D-f, D-g): the browser knows its
/// selection; the app knows the other panel, the queue and the history.
public enum FileCommand: Sendable, Equatable {
    case copyToOtherPanel, moveToOtherPanel, rename, newFolder, trash, deletePermanently
    case undo, redo
}

/// Runs a browser's file commands; the app supplies it.
@MainActor
public protocol FileCommandHandling: AnyObject {
    func perform(_ command: FileCommand, in browser: BrowserItem)
    /// Whether `command` can run now, beyond the browser's own selection check; may set
    /// `menuItem`'s title (Undo Copy of 3 Items).
    func validate(_ command: FileCommand, in browser: BrowserItem, menuItem: NSMenuItem) -> Bool
}

extension BrowserItem {
    /// Selects `name` once the folder's listing has it: a renamed item, a new folder.
    public func selectWhenListed(_ name: String) {
        controller.selectWhenListed(name)
    }
}

/// Actions for the file commands, found through the responder chain.
@objc public protocol FileCommandActions {
    @objc optional func browserRename(_ sender: Any?)
    @objc optional func browserCopyToOtherPanel(_ sender: Any?)
    @objc optional func browserMoveToOtherPanel(_ sender: Any?)
    @objc optional func browserNewFolder(_ sender: Any?)
    @objc optional func browserTrash(_ sender: Any?)
    @objc optional func browserDeletePermanently(_ sender: Any?)
}

extension BrowserViewController {
    @objc func browserRename(_ sender: Any?) { send(.rename) }
    @objc func browserCopyToOtherPanel(_ sender: Any?) { send(.copyToOtherPanel) }
    @objc func browserMoveToOtherPanel(_ sender: Any?) { send(.moveToOtherPanel) }
    @objc func browserNewFolder(_ sender: Any?) { send(.newFolder) }
    @objc func browserTrash(_ sender: Any?) { send(.trash) }
    @objc func browserDeletePermanently(_ sender: Any?) { send(.deletePermanently) }
    /// Edit › Undo and Redo reach the file history while a browser has focus (D-g).
    @objc func undo(_ sender: Any?) { send(.undo) }
    @objc func redo(_ sender: Any?) { send(.redo) }

    private func send(_ command: FileCommand) {
        guard let item, let handler = item.fileCommands, canSend(command) else {
            return NSSound.beep()
        }
        handler.perform(command, in: item)
    }

    /// The file command a menu item sends, if it's one.
    func fileCommand(for action: Selector?) -> FileCommand? {
        switch action {
        case #selector(browserRename(_:)): .rename
        case #selector(browserCopyToOtherPanel(_:)): .copyToOtherPanel
        case #selector(browserMoveToOtherPanel(_:)): .moveToOtherPanel
        case #selector(browserNewFolder(_:)): .newFolder
        case #selector(browserTrash(_:)): .trash
        case #selector(browserDeletePermanently(_:)): .deletePermanently
        case #selector(undo(_:)): .undo
        case #selector(redo(_:)): .redo
        default: nil
        }
    }

    func validateFileCommand(_ command: FileCommand, menuItem: NSMenuItem) -> Bool {
        guard let item, let handler = item.fileCommands, canSend(command) else { return false }
        return handler.validate(command, in: item, menuItem: menuItem)
    }

    /// What the browser itself requires: a selection for what acts on one (rename takes
    /// exactly one), access to the folder for anything that changes it.
    private func canSend(_ command: FileCommand) -> Bool {
        guard let item, !isEditingPath else { return false }
        switch command {
        case .undo, .redo: return true
        case .newFolder: return !item.needsAccess
        case .rename: return !item.needsAccess && selection.count == 1
        case .copyToOtherPanel, .moveToOtherPanel, .trash, .deletePermanently:
            return !item.needsAccess && !selection.isEmpty
        }
    }
}
