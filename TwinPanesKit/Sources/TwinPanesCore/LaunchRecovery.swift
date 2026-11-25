/// The sessions crash recovery found at launch, held until windows are restored
/// (docs/plans/M5.md, D-c). The registry holds sessions weakly, so without this a
/// recovered session would go before a restored tab on its file could claim it.
///
/// Either `takeUnclaimed` or `SessionRegistry` (via a restored tab) must take ownership
/// of every recovered session; dropping `LaunchRecovery` without transferring them lets
/// `EditorSession.deinit` mark their session folders closed and delete them.
@MainActor
public final class LaunchRecovery {
    private var held: [EditorSession]

    /// Adopts `sessions` into `registry`, so opening one of their files finds it.
    public init(_ sessions: [EditorSession], registry: SessionRegistry) {
        held = sessions
        for session in sessions { registry.adopt(session) }
    }

    /// Hands back the held sessions no tab claimed, in the order they were found, and
    /// lets go of all of them. Call once, after windows are restored.
    public func takeUnclaimed(isClaimed: (EditorSession) -> Bool) -> [EditorSession] {
        defer { held = [] }
        return held.filter { !isClaimed($0) }
    }
}
