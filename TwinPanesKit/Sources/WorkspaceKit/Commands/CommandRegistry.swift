import AppKit

/// The command catalog plus key bindings per scope (D21, PLAN.md §4.11).
///
/// The registry answers two questions: "which commands could this key mean, given the
/// focus chain?" (for `CommandDispatcher`) and "which key should this menu item show,
/// given the focus chain?" (for `MenuBindingUpdater`). It never performs anything.
@MainActor
public final class CommandRegistry {
    private var commands: [CommandID: Command] = [:]
    private var bindings: [BindingScope: [KeyChord: CommandID]] = [:]
    /// Insertion order of bindings per scope, so the first chord bound to a command is
    /// its primary shortcut in menus.
    private var bindingOrder: [BindingScope: [KeyChord]] = [:]

    public init() {}

    // MARK: Catalog

    public func register(_ command: Command) {
        precondition(commands[command.id] == nil, "command \(command.id) registered twice")
        commands[command.id] = command
    }

    public func command(_ id: CommandID) -> Command? { commands[id] }

    public var allCommands: [Command] { commands.values.sorted { $0.id.rawValue < $1.id.rawValue } }

    // MARK: Bindings

    /// Binds `chord` to `id` in `scope`, replacing any earlier binding of that chord there.
    public func bind(_ chord: KeyChord, to id: CommandID, in scope: BindingScope = .app) {
        precondition(commands[id] != nil, "binding unknown command \(id)")
        bindings[scope, default: [:]][chord] = id
        var order = bindingOrder[scope, default: []]
        if !order.contains(chord) {
            order.append(chord)
            bindingOrder[scope] = order
        }
    }

    public func unbind(_ chord: KeyChord, in scope: BindingScope) {
        bindings[scope]?[chord] = nil
        bindingOrder[scope]?.removeAll { $0 == chord }
    }

    /// Commands `chord` could mean, most specific scope first. `chain` is ordered from
    /// the focused view outwards; `.app` is always consulted last.
    public func candidates(for chord: KeyChord, chain: [BindingScope]) -> [Command] {
        var seen = Set<CommandID>()
        return Self.withApp(chain).compactMap { scope in
            guard let id = bindings[scope]?[chord], seen.insert(id).inserted else { return nil }
            return commands[id]
        }
    }

    /// The chord that triggers `id` from this focus chain: the first-registered binding
    /// in the most specific scope that binds `id`, unless a more specific scope has taken
    /// that chord for a different command.
    public func binding(for id: CommandID, chain: [BindingScope]) -> KeyChord? {
        let scopes = Self.withApp(chain)
        for (index, scope) in scopes.enumerated() {
            let chords = (bindingOrder[scope] ?? []).filter { bindings[scope]?[$0] == id }
            for chord in chords {
                let shadowed = scopes[..<index].contains { bindings[$0]?[chord] != nil }
                if !shadowed { return chord }
            }
        }
        return nil
    }

    private static func withApp(_ chain: [BindingScope]) -> [BindingScope] {
        chain.last == .app ? chain : chain + [.app]
    }
}
