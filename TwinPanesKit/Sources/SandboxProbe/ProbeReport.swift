import Foundation

/// What the user granted for this run.
public enum GrantKind: String, Sendable {
    /// An open panel on one file: the file only, nothing next to it.
    case file
    /// An open panel on a folder: everything inside it.
    case folder
}

/// Facts about the volume a probed item lives on.
public struct VolumeInfo: Sendable, Equatable {
    public var name = "?"
    public var format = "?"
    public var isLocal: Bool?
    public var isRemovable: Bool?
    public var isInternal: Bool?
    public var supportsCloning: Bool?
    public var isBootVolume: Bool?

    public init() {}

    public init(for url: URL) {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeIsLocalKey,
            .volumeIsRemovableKey, .volumeIsInternalKey, .volumeSupportsFileCloningKey,
            .volumeIsRootFileSystemKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }
        name = values.volumeName ?? "?"
        format = values.volumeLocalizedFormatDescription ?? "?"
        isLocal = values.volumeIsLocal
        isRemovable = values.volumeIsRemovable
        isInternal = values.volumeIsInternal
        supportsCloning = values.volumeSupportsFileCloning
        isBootVolume = values.volumeIsRootFileSystem
    }
}

/// One probe run: a grant on one item, the volume it's on, and every step's outcome.
public struct ProbeReport: Sendable {
    public let date: Date
    public let path: String
    public let grant: GrantKind
    public let volume: VolumeInfo
    public let isSandboxed: Bool
    public let results: [ProbeResult]
    /// App-scoped bookmark created during the run, for the relaunch check.
    public let bookmark: Data?

    public var failureCount: Int { results.filter(\.outcome.isFailure).count }

    public func outcome(of name: String) -> ProbeOutcome? {
        results.first { $0.name == name }?.outcome
    }

    /// One Markdown section, ready to paste into the spike write-up.
    public var markdown: String {
        func flag(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "?" }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var lines = [
            "### \(grant.rawValue) grant — `\(path)`",
            "",
            "- Date: \(ISO8601DateFormatter().string(from: date)) · macOS \(os) · sandboxed: \(isSandboxed ? "yes" : "no")",
            "- Volume: \(volume.name) (\(volume.format)); local \(flag(volume.isLocal)), "
                + "internal \(flag(volume.isInternal)), removable \(flag(volume.isRemovable)), "
                + "boot \(flag(volume.isBootVolume)), cloning \(flag(volume.supportsCloning))",
            "",
            "| Probe | Result | Detail |",
            "|---|---|---|",
        ]
        for result in results {
            let detail = result.outcome.detail.replacingOccurrences(of: "|", with: "\\|")
            lines.append("| \(result.name) | \(result.outcome.symbol) | \(detail) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
