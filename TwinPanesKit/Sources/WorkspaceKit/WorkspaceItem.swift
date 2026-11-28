import AppKit

/// Stable identity of one open item (a tab, a drawer pane, a preview).
public struct ItemID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init() { rawValue = UUID() }
    init(rawValue: UUID) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// What kind of item this is. Used for command scopes ("item.<kind>") and icons.
public struct ItemKind: RawRepresentable, Hashable, Sendable, Codable,
    ExpressibleByStringLiteral
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

/// Where in the main frame an item lives (PLAN.md §4.8).
public enum SlotID: String, Hashable, Sendable, CaseIterable, Codable {
    case leftPanel
    case rightPanel
    case preview
    case drawer

    public var isPanel: Bool { self == .leftPanel || self == .rightPanel }

    /// The panel across from this one; nil for slots that aren't panels.
    public var otherPanel: SlotID? {
        switch self {
        case .leftPanel: .rightPanel
        case .rightPanel: .leftPanel
        case .preview, .drawer: nil
        }
    }
}

/// Services the main frame offers to the items it hosts.
@MainActor
public protocol WorkspaceHost: AnyObject {
    /// Shows a short message in the main frame's status line.
    func showStatus(_ message: String)
    /// Shows a message on the leading side and a summary pinned to the trailing edge.
    func showStatus(_ message: String, trailing: String)
}

extension WorkspaceHost {
    public func showStatus(_ message: String, trailing: String) {
        if trailing.isEmpty {
            showStatus(message)
        } else if message.isEmpty {
            showStatus(trailing)
        } else {
            showStatus("\(message) · \(trailing)")
        }
    }
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

    /// What to save so the item comes back after a relaunch (docs/plans/M5.md, D-c);
    /// nil leaves it out.
    var restorableState: ItemState? { get }

    /// Called by the item when its title or dirty state changes.
    var onChange: (() -> Void)? { get set }

    /// Whether `save()` can write the session now. When false the close prompt offers
    /// only Discard and Cancel (the hex editor until saving lands in M3b).
    var canSave: Bool { get }

    /// Whether a save of the session this item views is running or queued.
    var isSaving: Bool { get }

    /// Waits until any running or queued save finishes.
    func finishSaving() async

    /// Saves the session this item views. Only called while `isDirty` and `canSave`.
    func save() async throws

    /// Throws away unsaved changes of the session this item views.
    func discardChanges()

    /// The item is about to go away: its tab closed (after the close workflow agreed) or
    /// its window closed. Stop background work such as a running search here.
    func willClose()
}

extension WorkspaceItem {
    public var sessionKey: AnyHashable? { nil }
    public var restorableState: ItemState? { nil }
    public var isDirty: Bool { false }
    public var canSave: Bool { true }
    public var isSaving: Bool { false }
    public func finishSaving() async {}
    public var icon: NSImage? { nil }
    public var preferredFirstResponder: NSView? { nil }
    public func save() async throws {}
    public func discardChanges() {}
    public func willClose() {}

    /// The key the close workflow groups by.
    var closeGroupKey: AnyHashable { sessionKey ?? AnyHashable(id) }
}
