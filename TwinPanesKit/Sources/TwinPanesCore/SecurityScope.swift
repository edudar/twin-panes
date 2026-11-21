import Foundation

/// Holds sandbox access to a security-scoped URL for as long as the token lives
/// (PLAN.md §5). Owners keep a token until their work finishes: an editor session for
/// its file, a browser tab for its folder, a queued operation until it completes.
/// Releasing the last reference stops access.
public final class SecurityScope: Sendable {
    public let url: URL
    /// `false` when the URL wasn't security-scoped (e.g. outside the sandbox, or a URL
    /// the app can already reach); the token is then a no-op.
    public let isActive: Bool

    public init(url: URL) {
        self.url = url
        self.isActive = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if isActive { url.stopAccessingSecurityScopedResource() }
    }
}
