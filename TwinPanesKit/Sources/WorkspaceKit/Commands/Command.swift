import AppKit

/// Stable identifier of a user action (`editor.find.next`, `workspace.zoom`…). Key
/// bindings, the F-key bar and the item switcher refer to commands by ID (D21).
public struct CommandID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
}

/// Where a binding applies. Resolution walks the focus chain from the most specific
/// scope to `.app` (PLAN.md §4.11): focused view → item → slot → main frame → app.
public struct BindingScope: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let app = BindingScope(rawValue: "app")
    public static let mainFrame = BindingScope(rawValue: "mainFrame")
    public static func slot(_ slot: SlotID) -> BindingScope {
        BindingScope(rawValue: "slot.\(slot.rawValue)")
    }
    /// An item kind (`item.browser`) or a part of one (`item.browser.fileList`).
    public static func item(_ kind: ItemKind, part: String? = nil) -> BindingScope {
        BindingScope(rawValue: "item.\(kind.rawValue)" + (part.map { ".\($0)" } ?? ""))
    }
}

/// A catalog entry: what the command is called and which AppKit action it sends.
/// Routing is AppKit's: the action goes through the responder chain, enablement comes
/// from `NSUserInterfaceValidations` / `NSMenuItemValidation`.
public struct Command {
    public let id: CommandID
    public let title: String
    public let action: Selector

    public init(_ id: CommandID, title: String, action: Selector) {
        self.id = id
        self.title = title
        self.action = action
    }
}
