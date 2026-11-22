import AppKit

/// Stable identity of one open item (a tab, a drawer pane, a preview).
public struct ItemID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init() { rawValue = UUID() }
    public var description: String { rawValue.uuidString }
}

/// What kind of item this is. Used for command scopes ("item.<kind>") and icons.
public struct ItemKind: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

/// Where in the main frame an item lives (PLAN.md §4.8).
public enum SlotID: String, Hashable, Sendable, CaseIterable {
    case leftPanel
    case rightPanel
    case preview
    case drawer

    public var isPanel: Bool { self == .leftPanel || self == .rightPanel }
}

/// Services the main frame offers to the items it hosts.
@MainActor
public protocol WorkspaceHost: AnyObject {
    /// Shows a short message in the main frame's status line.
    func showStatus(_ message: String)
}

/// Everything that isn't a dialog: browsers, editors, viewers, terminals (PLAN.md §4.8).
///
/// Items must survive being re-parented between slots and windows: the main frame
/// detaches and re-attaches `viewController.view`, it never recreates the item.
@MainActor
public protocol WorkspaceItem: AnyObject {
    var id: ItemID { get }
    var kind: ItemKind { get }
    var title: String { get }
    /// Small image for the tab (16 pt); nil shows no icon.
    var icon: NSImage? { get }
    var isDirty: Bool { get }

    /// Views of the same session (e.g. two tabs on one file) share a key, so the close
    /// workflow prompts once per session, when its last view closes. `nil` means the
    /// item is its own session.
    var sessionKey: AnyHashable? { get }

    var viewController: NSViewController { get }
    var preferredSlot: SlotID { get }

    /// The view that gets keyboard focus when this item becomes current. `nil` means the
    /// root view of `viewController`.
    var preferredFirstResponder: NSView? { get }

    /// Set by the main frame while the item is hosted.
    var host: WorkspaceHost? { get set }

    /// Called by the item when its title or dirty state changes.
    var onChange: (() -> Void)? { get set }

    /// Saves the session this item views. Only called while `isDirty`.
    func save() async throws

    /// Throws away unsaved changes of the session this item views.
    func discardChanges()

    /// The item is about to go away: its tab closed (after the close workflow agreed) or
    /// its window closed. Stop background work such as a running search here.
    func willClose()
}

extension WorkspaceItem {
    public var sessionKey: AnyHashable? { nil }
    public var isDirty: Bool { false }
    public var icon: NSImage? { nil }
    public var preferredFirstResponder: NSView? { nil }
    public func save() async throws {}
    public func discardChanges() {}
    public func willClose() {}

    /// The key the close workflow groups by.
    var closeGroupKey: AnyHashable { sessionKey ?? AnyHashable(id) }
}
