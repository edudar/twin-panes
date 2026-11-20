import AppKit

extension NSUserInterfaceItemIdentifier {
    /// Menu items built from the catalog carry their command ID in `identifier`.
    static let commandPrefix = "command:"
}

/// Keeps menu items' key equivalents in sync with the bindings that apply to the
/// current focus (PLAN.md §4.11). Menu items still send their action through the
/// responder chain and validate as usual; this only changes what they display.
@MainActor
public final class MenuBindingUpdater: NSObject, NSMenuDelegate {
    private let registry: CommandRegistry

    public init(registry: CommandRegistry) {
        self.registry = registry
    }

    /// Builds a menu item for a catalog command.
    public func menuItem(for id: CommandID) -> NSMenuItem {
        guard let command = registry.command(id) else {
            preconditionFailure("menu item for unknown command \(id)")
        }
        let item = NSMenuItem(title: command.title, action: command.action, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(
            NSUserInterfaceItemIdentifier.commandPrefix + id.rawValue)
        apply(registry.binding(for: id, chain: [.app]), to: item)
        return item
    }

    /// Makes this updater the delegate of `menu` and all its submenus.
    public func attach(to menu: NSMenu) {
        menu.delegate = self
        for item in menu.items {
            if let submenu = item.submenu { attach(to: submenu) }
        }
    }

    /// Refreshes every catalog item in `menu` for the focus chain of `window` (default:
    /// the key window, else the main window).
    public func refresh(_ menu: NSMenu, for window: NSWindow? = nil) {
        let chain = FocusChain.scopes(in: window ?? NSApp.keyWindow ?? NSApp.mainWindow)
        for item in menu.items {
            if let id = Self.commandID(of: item) {
                apply(registry.binding(for: id, chain: chain), to: item)
            }
            if let submenu = item.submenu { refresh(submenu, for: window) }
        }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        refresh(menu)
    }

    static func commandID(of item: NSMenuItem) -> CommandID? {
        guard let raw = item.identifier?.rawValue,
            raw.hasPrefix(NSUserInterfaceItemIdentifier.commandPrefix)
        else { return nil }
        return CommandID(
            rawValue: String(raw.dropFirst(NSUserInterfaceItemIdentifier.commandPrefix.count)))
    }

    private func apply(_ chord: KeyChord?, to item: NSMenuItem) {
        let (key, mask) = chord?.menuKeyEquivalent ?? ("", [])
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = mask
    }
}
