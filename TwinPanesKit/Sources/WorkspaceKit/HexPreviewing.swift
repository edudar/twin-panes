import AppKit
import TwinPanesCore

/// Visual density for a read-only hex viewer: `.regular` for full-panel Quick View,
/// `.compact` for compact or narrow layouts (`docs/plans/M7.md`, D-b).
public enum HexViewerStyle: Sendable, Equatable {
    case regular
    case compact
}

/// Read-only hex viewer contract shared across module boundaries so `BrowserKit` stays
/// decoupled from `HexViewKit` (`docs/plans/M7.md`, D-a).
@MainActor
public protocol HexPreviewing: AnyObject {
    /// The viewer's root view controller.
    var viewController: NSViewController { get }
    /// Whether the displayed bytes reflect unsaved edits from an open editor session.
    var showsUnsavedEdits: Bool { get }
    /// Called when `showsUnsavedEdits` or viewer state changes.
    var onStateChange: (() -> Void)? { get set }
    /// Retargets the viewer to `url` with `scope`, or clears the view when `url` is nil.
    func show(_ url: URL?, scope: SecurityScope?)
}

/// Creates read-only hex viewers (`docs/plans/M7.md`, D-a).
@MainActor
public protocol HexViewerFactory: AnyObject {
    /// Returns a new viewer configured for `style`.
    func makeHexViewer(style: HexViewerStyle) -> any HexPreviewing
}
