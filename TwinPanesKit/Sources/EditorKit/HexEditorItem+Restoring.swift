import Foundation
import HexViewKit
import WorkspaceKit

/// What an editor tab saves to come back after a relaunch (docs/plans/M5.md, D-c). The
/// file is a security-scoped bookmark, so the sandbox lets the app open it again.
/// Restored editors are clean: unsaved edits come back through crash recovery.
public struct EditorState: Codable, Equatable, Sendable {
    public var fileBookmark: Data
    var selectionStart: UInt64
    var selectionEnd: UInt64
    var topRow: UInt64
    /// 8, 16 or 32; 0 fits the view's width.
    var bytesPerRow: Int
    var grouping: Int
    var offsetBase: String
    var textEncoding: String
}

extension HexEditorItem {
    /// The `EditorState` format this build writes and reads.
    public static let stateVersion = 1

    /// Nil when no bookmark can be made for the file: the tab is then left out.
    public var restorableState: ItemState? {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope) else {
            return nil
        }
        let options = hexView.options
        let selection = hexView.selection.range
        let bytesPerRow: Int
        if case .fixed(let count) = options.bytesPerRow {
            bytesPerRow = count
        } else {
            bytesPerRow = 0
        }
        let state = EditorState(
            fileBookmark: bookmark, selectionStart: selection.lowerBound,
            selectionEnd: selection.upperBound, topRow: hexView.topRow, bytesPerRow: bytesPerRow,
            grouping: options.grouping, offsetBase: options.offsetBase.rawValue,
            textEncoding: options.textEncoding.rawValue)
        // Encoding numbers, strings and data doesn't fail; if it did, the tab would only
        // be left out of the saved window.
        guard let payload = try? JSONEncoder().encode(state) else { return nil }
        return ItemState(kind: .editor, version: Self.stateVersion, payload: payload)
    }

    /// The editor state saved in `state`, or nil when it isn't an editor's.
    public static func editorState(from state: ItemState) -> EditorState? {
        // Nil is the restorer's "can't use this state": the tab is skipped.
        try? JSONDecoder().decode(EditorState.self, from: state.payload)
    }

    /// Puts back the saved view options, selection and scroll position, clamped to the
    /// file as it is now; values this build doesn't know keep their defaults.
    public func restoreView(_ state: EditorState) {
        // The app restores a tab before showing it. Until the view loads, the hex view
        // has no data source and takes the file as empty, clamping the selection to 0.
        _ = controller.view
        hexView.options = Self.options(from: state)
        guard length > 0 else { return }
        let start = min(state.selectionStart, length - 1)
        let end = min(max(state.selectionEnd, start + 1), length)
        hexView.select(start..<end)
        hexView.scroll(toTopRow: state.topRow)
    }

    private static func options(from state: EditorState) -> HexViewOptions {
        var options = HexViewOptions()
        if state.bytesPerRow == 0 {
            options.bytesPerRow = .autoFit
        } else if HexViewOptions.allowedBytesPerRow.contains(state.bytesPerRow) {
            options.bytesPerRow = .fixed(state.bytesPerRow)
        }
        if HexViewOptions.allowedGrouping.contains(state.grouping) {
            options.grouping = state.grouping
        }
        options.offsetBase =
            HexViewOptions.OffsetBase(rawValue: state.offsetBase) ?? options.offsetBase
        options.textEncoding =
            HexViewOptions.TextEncoding(rawValue: state.textEncoding) ?? options.textEncoding
        return options
    }
}
