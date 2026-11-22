import Darwin
import Foundation

/// One item in a folder listing.
public struct DirectoryEntry: Hashable, Sendable {
    public let url: URL
    public let name: String
    /// A folder, or a symbolic link to one. Packages (`.app`, `.bundle`) are not: they
    /// list as files, as in Finder (PLAN.md §9, open question 2).
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymbolicLink: Bool
    public let isHidden: Bool
    /// Bytes for files; nil for folders.
    public let size: UInt64?
    public let modified: Date?
    /// Finder's kind, e.g. "Folder", "Plain Text Document".
    public let kind: String
}

public enum DirectoryReaderError: Error, Equatable {
    /// The sandbox (or file permissions) refuses this folder; ask the user for access.
    case needsAccess(URL)
    case notFound(URL)
    case notAFolder(URL)
    case failed(URL, String)
}

/// Reads folder listings (M1b). Synchronous: the caller decides where it runs. Async
/// listing for very large folders is M4.
public enum DirectoryReader {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey,
        .contentModificationDateKey, .localizedTypeDescriptionKey, .localizedNameKey,
    ]

    /// The entries of `folder`, folders first, then by name as Finder sorts it.
    public static func entries(
        of folder: URL, includeHidden: Bool = false
    ) throws
        -> [DirectoryEntry]
    {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys,
                options: includeHidden ? [] : [.skipsHiddenFiles])
        } catch let error as CocoaError {
            switch error.code {
            case .fileReadNoPermission: throw DirectoryReaderError.needsAccess(folder)
            case .fileReadNoSuchFile, .fileNoSuchFile: throw DirectoryReaderError.notFound(folder)
            default:
                if (error.underlying as? POSIXError)?.code == .ENOTDIR {
                    throw DirectoryReaderError.notAFolder(folder)
                }
                throw DirectoryReaderError.failed(folder, error.localizedDescription)
            }
        }
        return urls.map(entry).sorted(by: Self.finderOrder)
    }

    static func entry(_ url: URL) -> DirectoryEntry {
        let values = try? url.resourceValues(forKeys: Set(keys))
        let isLink = values?.isSymbolicLink ?? false
        var isDirectory = values?.isDirectory ?? false
        var isPackage = values?.isPackage ?? false
        var fileSize = values?.fileSize
        if isLink {
            let target = try? url.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey])
            isDirectory = target?.isDirectory ?? false
            isPackage = target?.isPackage ?? false
            if let targetSize = target?.fileSize { fileSize = targetSize }
        }
        let isFolder = isDirectory && !isPackage
        return DirectoryEntry(
            url: url, name: values?.localizedName ?? url.lastPathComponent,
            isDirectory: isFolder, isPackage: isPackage, isSymbolicLink: isLink,
            isHidden: values?.isHidden ?? false,
            size: isFolder ? nil : fileSize.map { UInt64($0) },
            modified: values?.contentModificationDate,
            kind: values?.localizedTypeDescription ?? (isFolder ? "Folder" : "Document"))
    }

    static func finderOrder(_ a: DirectoryEntry, _ b: DirectoryEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// The user's real home folder. Inside the sandbox `FileManager`'s home is the
    /// app's container, which is not what a file manager should start in.
    public static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
