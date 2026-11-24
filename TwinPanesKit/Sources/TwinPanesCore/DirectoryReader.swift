import Darwin
import Foundation
import Synchronization
import UniformTypeIdentifiers

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
    /// The entry's type, from its name (docs/plans/M4.md, D-b): reading each file's own
    /// type description is what made listing a big folder slow. Also picks the icon.
    public let type: UTType

    /// The Kind column, e.g. "Folder", "Plain text". Stored, not looked up on each use
    /// (docs/plans/M4.md, performance pass, step 2): a Kind sort of 100k entries looked
    /// it up millions of times under a lock the main actor's cells also take.
    public let kind: String
    /// An app, whose icon is its own rather than its type's.
    public let isApplication: Bool

    /// `kind` is the type's description unless given.
    public init(
        url: URL, name: String, isDirectory: Bool, isPackage: Bool, isSymbolicLink: Bool,
        isHidden: Bool, size: UInt64?, modified: Date?, type: UTType, kind: String? = nil
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.isHidden = isHidden
        self.size = size
        self.modified = modified
        self.type = type
        self.kind = kind ?? TypeNames.description(of: type)
        isApplication = type.conforms(to: .application)
    }
}

/// Type descriptions for the Kind column, looked up once per type.
public enum TypeNames {
    private static let cache = Mutex<[UTType: String]>([:])

    static var cachedCount: Int { cache.withLock { $0.count } }

    public static func description(of type: UTType) -> String {
        if type.isDynamic { return "Document" }
        if let known = cache.withLock({ $0[type] }) { return known }
        var text = type.localizedDescription ?? "Document"
        text = text.prefix(1).uppercased() + text.dropFirst()
        cache.withLock { $0[type] = text }
        return text
    }

    /// The type of a file called `name`: by its extension, or plain data without one.
    static func type(named name: String, folder: Bool, package: Bool) -> UTType {
        if folder { return .folder }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return package ? .package : .data }
        // The lookup matches only types under its base, data unless asked otherwise.
        let byName = UTType(filenameExtension: ext, conformingTo: package ? .package : .data)
        if let byName, !(package && byName.isDynamic) { return byName }
        return package ? .package : .data
    }
}

public enum DirectoryReaderError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The sandbox (or file permissions) refuses this folder; ask the user for access.
    case needsAccess(URL)
    case notFound(URL)
    case notAFolder(URL)
    case failed(URL, String)

    /// True for `.needsAccess`: the tab shows the access prompt rather than refusing.
    public var needsAccess: Bool {
        if case .needsAccess = self { true } else { false }
    }

    public var description: String {
        switch self {
        case .needsAccess(let url): "No permission to open \(url.lastPathComponent)"
        case .notFound(let url): "\(url.lastPathComponent) was not found"
        case .notAFolder(let url): "\(url.lastPathComponent) is not a folder"
        case .failed(_, let message): message
        }
    }
}

/// Reads folder listings (M1b). Synchronous: the caller decides where it runs.
/// Only cheap keys are read; names are the real file names, not Finder's display names.
public enum DirectoryReader {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey,
        .contentModificationDateKey,
    ]
    private static let keySet = Set(keys)
    private static let targetKeySet: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey,
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
        } catch {
            throw DirectoryReaderError.failed(folder, error.localizedDescription)
        }
        return urls.map(entry).sorted(by: Self.finderOrder)
    }

    /// The entry at `url` read again, or nil if nothing is there now (D-f).
    public static func entryIfPresent(_ url: URL) -> DirectoryEntry? {
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: keySet) else { return nil }
        return entry(url, values: values)
    }

    static func entry(_ url: URL) -> DirectoryEntry {
        entry(url, values: try? url.resourceValues(forKeys: keySet))
    }

    static func entry(_ url: URL, values: URLResourceValues?) -> DirectoryEntry {
        let isLink = values?.isSymbolicLink ?? false
        var isDirectory = values?.isDirectory ?? false
        var isPackage = values?.isPackage ?? false
        var fileSize = values?.fileSize
        var typeName = url.lastPathComponent
        var brokenLink = false
        if isLink {
            let resolved = url.resolvingSymlinksInPath()
            var st = stat()
            if stat(url.path, &st) == 0 {
                let target = try? resolved.resourceValues(forKeys: targetKeySet)
                isDirectory = target?.isDirectory ?? false
                isPackage = target?.isPackage ?? false
                let targetIsFolder = isDirectory && !isPackage
                fileSize = (targetIsFolder || isPackage) ? nil : target?.fileSize
                typeName = resolved.lastPathComponent
            } else {
                isDirectory = false
                isPackage = false
                fileSize = nil
                brokenLink = true
            }
        }
        let isFolder = isDirectory && !isPackage
        let type: UTType =
            brokenLink
            ? .symbolicLink
            : TypeNames.type(named: typeName, folder: isFolder, package: isPackage)
        return DirectoryEntry(
            url: url, name: url.lastPathComponent,
            isDirectory: isFolder, isPackage: isPackage, isSymbolicLink: isLink,
            isHidden: values?.isHidden ?? false,
            size: (isFolder || isPackage) ? nil : fileSize.flatMap { UInt64(exactly: $0) },
            modified: values?.contentModificationDate,
            type: type)
    }

    static func finderOrder(_ a: DirectoryEntry, _ b: DirectoryEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// The user's real home folder. Inside the sandbox `FileManager`'s home is the
    /// app's container, which is not what a file manager should start in.
    public static var realHomeDirectory: URL {
        let bufSize = max(sysconf(_SC_GETPW_R_SIZE_MAX), 4096)
        var pwd = passwd()
        var buffer = [CChar](repeating: 0, count: bufSize)
        var result: UnsafeMutablePointer<passwd>?
        if getpwuid_r(getuid(), &pwd, &buffer, bufSize, &result) == 0,
            let dir = result?.pointee.pw_dir
        {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
