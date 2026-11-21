import Foundation

/// The user's answer to "save changes?".
public enum CloseDecision: Sendable {
    case save
    case discard
    case cancel
}

/// One dirty session about to lose its last view.
@MainActor
public struct DirtySession {
    /// Any one view of the session; `save()`/`discardChanges()` act on the session.
    public let representative: any WorkspaceItem
    /// How many views of it are closing.
    public let viewCount: Int
}

/// The single close workflow for tabs, windows and quitting (PLAN.md §4).
///
/// A dirty session prompts exactly once, and only when *all* its open views (across
/// every window) are among the ones closing. Prompts run one at a time; Cancel aborts
/// the whole close.
@MainActor
public final class CloseCoordinator {
    public typealias Prompt = @MainActor (DirtySession) async -> CloseDecision

    private let openItems: @MainActor () -> [any WorkspaceItem]
    private let prompt: Prompt
    private var inProgress = false

    /// - Parameters:
    ///   - openItems: every item open in the app right now, across all windows.
    ///   - prompt: asks the user about one session (a sheet in the app, a stub in tests).
    public init(
        openItems: @escaping @MainActor () -> [any WorkspaceItem], prompt: @escaping Prompt
    ) {
        self.openItems = openItems
        self.prompt = prompt
    }

    /// Sessions that would lose their last view if `closing` closed.
    public func dirtySessions(closing: [any WorkspaceItem]) -> [DirtySession] {
        let closingIDs = Set(closing.map(\.id))
        let stillOpen = Set(
            openItems().filter { !closingIDs.contains($0.id) }.map(\.closeGroupKey))
        var order: [AnyHashable] = []
        var groups: [AnyHashable: [any WorkspaceItem]] = [:]
        for item in closing {
            let key = item.closeGroupKey
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.compactMap { key in
            guard let views = groups[key], !stillOpen.contains(key),
                let first = views.first, first.isDirty
            else { return nil }
            return DirtySession(representative: first, viewCount: views.count)
        }
    }

    /// Asks about every dirty session losing its last view, saving or discarding as
    /// told. Returns `true` if the caller may go ahead and close `closing`.
    public func confirmClose(_ closing: [any WorkspaceItem]) async -> Bool {
        guard !inProgress else { return false }
        inProgress = true
        defer { inProgress = false }

        for session in dirtySessions(closing: closing) {
            // The session may have been saved while an earlier sheet was up.
            guard session.representative.isDirty else { continue }
            switch await prompt(session) {
            case .cancel:
                return false
            case .discard:
                session.representative.discardChanges()
            case .save:
                do {
                    try await session.representative.save()
                } catch {
                    return false
                }
            }
        }
        return true
    }
}
