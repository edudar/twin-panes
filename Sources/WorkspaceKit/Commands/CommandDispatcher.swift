import AppKit

/// Resolves key events against the focus chain *before* the main menu sees them, then
/// sends the command's action through the responder chain (PLAN.md §4.11).
///
/// `MainWindow` calls `handle(_:in:)` from `performKeyEquivalent(with:)` (keys with
/// modifiers, which AppKit offers the key window before the menu) and from
/// `sendEvent(_:)` (plain keys such as F3 or Tab). Keys with no enabled candidate fall
/// through to normal AppKit handling.
@MainActor
public final class CommandDispatcher {
    public let registry: CommandRegistry

    public init(registry: CommandRegistry) {
        self.registry = registry
    }

    /// Returns `true` if a command handled the event.
    public func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        // While a sheet is up the registry intercepts nothing.
        guard window.attachedSheet == nil, let chord = KeyChord(event: event) else {
            return false
        }
        let chain = FocusChain.scopes(in: window)
        for command in registry.candidates(for: chord, chain: chain)
        where perform(command, in: window) {
            return true
        }
        return false
    }

    /// Sends `command` through the responder chain of `window` if some responder handles
    /// it and validates it as enabled.
    @discardableResult
    public func perform(_ command: Command, in window: NSWindow? = nil) -> Bool {
        guard let target = Self.target(for: command.action, in: window ?? NSApp.keyWindow)
        else { return false }
        guard Self.isEnabled(command.action, target: target) else { return false }
        return NSApp.sendAction(command.action, to: target, from: nil)
    }

    /// The object that would handle `action` from `window`'s first responder: the
    /// responder chain, then the window's delegate, the application and its delegate.
    /// Same order as AppKit's nil-targeted actions, but for a given window rather than
    /// whichever window happens to be key.
    public static func target(for action: Selector, in window: NSWindow?) -> AnyObject? {
        var responder: NSResponder? = window?.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        let fallbacks: [AnyObject?] = [window?.delegate, NSApp, NSApp.delegate]
        return fallbacks.compactMap { $0 }.first { $0.responds(to: action) }
    }

    /// Asks the target the same way a menu would.
    static func isEnabled(_ action: Selector, target: Any) -> Bool {
        let probe = NSMenuItem(title: "", action: action, keyEquivalent: "")
        if let validator = target as? NSMenuItemValidation {
            return validator.validateMenuItem(probe)
        }
        if let validator = target as? NSUserInterfaceValidations {
            return validator.validateUserInterfaceItem(probe)
        }
        return true
    }
}
