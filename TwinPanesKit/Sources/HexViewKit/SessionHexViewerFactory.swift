import TwinPanesCore
import WorkspaceKit

/// Creates read-only hex viewers backed by `SessionRegistry` and `CloudDownloads`
/// (`docs/plans/M7.md`, D-a).
@MainActor
public final class SessionHexViewerFactory: HexViewerFactory {
    private let sessions: SessionRegistry
    private let cloudDownloads: any CloudDownloads

    /// Creates a factory that observes `sessions` and checks `cloudDownloads` before opening
    /// uncached files from disk.
    public init(
        sessions: SessionRegistry,
        cloudDownloads: any CloudDownloads = RealCloudDownloads()
    ) {
        self.sessions = sessions
        self.cloudDownloads = cloudDownloads
    }

    /// Returns a new read-only hex viewer configured for `style`.
    public func makeHexViewer(style: HexViewerStyle) -> any HexPreviewing {
        ReadOnlyHexViewController(
            style: style, sessions: sessions, cloudDownloads: cloudDownloads)
    }
}
