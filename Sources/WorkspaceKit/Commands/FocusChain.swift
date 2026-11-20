import AppKit

/// Implemented by responders (views, view controllers) that add scopes to the focus
/// chain: a file list adds `item.browser.fileList`, a browser item adds `item.browser`,
/// a slot container adds `slot.leftPanel`, the main frame adds `mainFrame`.
@MainActor
public protocol CommandScopeProviding: AnyObject {
    var commandScopes: [BindingScope] { get }
}

/// Builds the focus chain by walking the responder chain from the window's first
/// responder outwards.
@MainActor
public enum FocusChain {
    public static func scopes(in window: NSWindow?) -> [BindingScope] {
        var scopes: [BindingScope] = []
        var responder: NSResponder? = window?.firstResponder
        // With no view focused, the window itself is first responder; start from its
        // content so main-frame scopes still apply.
        if responder == nil || responder === window {
            responder = window?.contentView
        }
        // A field editor stands in for the text field being edited.
        if let text = responder as? NSText, text.isFieldEditor,
            let field = text.delegate as? NSResponder
        {
            responder = field
        }
        while let current = responder {
            if let provider = current as? CommandScopeProviding {
                for scope in provider.commandScopes where !scopes.contains(scope) {
                    scopes.append(scope)
                }
            }
            responder = current.nextResponder
        }
        if !scopes.contains(.app) { scopes.append(.app) }
        return scopes
    }
}
