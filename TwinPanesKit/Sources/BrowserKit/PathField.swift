import AppKit
import WorkspaceKit

/// The browser's path field, with a command scope of its own so keys such as ⌘↩ can mean
/// something only while a path is typed (§4.11).
final class PathField: NSTextField, CommandScopeProviding {
    var commandScopes: [BindingScope] { [.item(.browser, part: "pathField")] }
}
