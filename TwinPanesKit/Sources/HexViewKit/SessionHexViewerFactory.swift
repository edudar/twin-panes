import TwinPanesCore
import WorkspaceKit

/// Creates read-only hex viewers backed by `SessionRegistry` and `CloudDownloads`
/// (`docs/plans/M7.md`, D-a).
@MainActor
public final class SessionHexViewerFactory: HexViewerFactory {
    private let sessions: SessionRegistry
    private let cloudDownloads: any CloudDownloads
    private let preferences: HexViewPreferences?

    /// Creates a factory that observes `sessions`, checks `cloudDownloads` before opening
    /// uncached files from disk, and shares display options via `preferences`.
    public init(
        sessions: SessionRegistry,
        cloudDownloads: any CloudDownloads = RealCloudDownloads(),
        preferences: HexViewPreferences? = nil
    ) {
        self.sessions = sessions
        self.cloudDownloads = cloudDownloads
        self.preferences = preferences
    }

    /// Returns a new read-only hex viewer configured for `style`.
    public func makeHexViewer(style: HexViewerStyle) -> any HexPreviewing {
        ReadOnlyHexViewController(
            style: style, sessions: sessions, cloudDownloads: cloudDownloads,
            preferences: preferences)
    }
}
