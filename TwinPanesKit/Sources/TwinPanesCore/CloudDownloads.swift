import Darwin
import Foundation

/// iCloud's side of a file: whether its bytes are only in the cloud (`SF_DATALESS`), and
/// asking for them (docs/plans/M6.md, D-h). A seam, since CI has no iCloud.
public protocol CloudDownloads: Sendable {
    func isDataless(_ url: URL) -> Bool
    /// Asks iCloud for the file's bytes and returns at once.
    func startDownload(_ url: URL) throws
}

public struct RealCloudDownloads: CloudDownloads {
    public init() {}

    public func isDataless(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }

    public func startDownload(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}
