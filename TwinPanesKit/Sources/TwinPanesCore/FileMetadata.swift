import Darwin
import Foundation
import UniformTypeIdentifiers

/// O(1) file metadata read directly via POSIX and URL type APIs without enumerating folder
/// contents (docs/plans/M7.md, D-c).
public struct FileMetadata: Equatable, Sendable {
    /// Name and byte size of a single POSIX extended attribute.
    public struct ExtendedAttribute: Equatable, Sendable {
        public let name: String
        public let size: Int

        public init(name: String, size: Int) {
            self.name = name
            self.size = size
        }
    }

    private typealias ClassifiedTarget = (
        isDirectory: Bool, isPackage: Bool, isDataless: Bool, type: UTType,
        size: UInt64?, allocatedSize: UInt64?, symlinkTarget: String?
    )

    /// Maximum number of extended attributes returned by ``read(url:)``.
    public static let maxExtendedAttributes = 64

    public let url: URL
    public let name: String
    public let kind: String
    public let typeIdentifier: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymbolicLink: Bool
    public let isDataless: Bool
    /// Logical byte size for regular files; `nil` for folders, packages, and broken links.
    public let size: UInt64?
    /// Allocated disk bytes (`st_blocks * 512`) for regular files; `nil` for folders, packages,
    /// and broken links.
    public let allocatedSize: UInt64?
    public let created: Date?
    public let modified: Date?
    public let accessed: Date?
    public let posixMode: UInt16
    public let owner: String
    public let group: String
    public let hardLinkCount: UInt32
    public let flags: [String]
    public let symlinkTarget: String?
    public let extendedAttributes: [ExtendedAttribute]
    public let hasMoreExtendedAttributes: Bool

    /// Reads O(1) metadata for `url`, throwing `POSIXError` when `lstat` fails.
    public static func read(url: URL) throws -> FileMetadata {
        let path = url.path
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw POSIXErrorCode(rawValue: errno).map { POSIXError($0) }
                ?? NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let isSymlink = (info.st_mode & S_IFMT) == S_IFLNK
        let classified = classify(url: url, lstatInfo: info, isLink: isSymlink)
        let isDataless = classified.isDataless
        let (xattrs, hasMore) = readExtendedAttributes(at: path)

        return FileMetadata(
            url: url, name: url.lastPathComponent,
            kind: TypeNames.description(of: classified.type),
            typeIdentifier: classified.type.identifier,
            isDirectory: classified.isDirectory, isPackage: classified.isPackage,
            isSymbolicLink: isSymlink, isDataless: isDataless,
            size: classified.size, allocatedSize: classified.allocatedSize,
            created: date(from: info.st_birthtimespec), modified: date(from: info.st_mtimespec),
            accessed: date(from: info.st_atimespec), posixMode: UInt16(info.st_mode & 0o7777),
            owner: resolveName(fallback: String(info.st_uid), hint: sysconf(_SC_GETPW_R_SIZE_MAX)) {
                var (pwd, res) = (passwd(), UnsafeMutablePointer<passwd>(nil))
                let status = getpwuid_r(info.st_uid, &pwd, $0, $1, &res)
                return (status, res?.pointee.pw_name.map { String(cString: $0) })
            },
            group: resolveName(fallback: String(info.st_gid), hint: sysconf(_SC_GETGR_R_SIZE_MAX)) {
                var (grp, res) = (Darwin.group(), UnsafeMutablePointer<Darwin.group>(nil))
                let status = getgrgid_r(info.st_gid, &grp, $0, $1, &res)
                return (status, res?.pointee.gr_name.map { String(cString: $0) })
            },
            hardLinkCount: UInt32(info.st_nlink),
            flags: bsdFlags(from: info.st_flags, isDataless: isDataless),
            symlinkTarget: classified.symlinkTarget,
            extendedAttributes: xattrs, hasMoreExtendedAttributes: hasMore)
    }

    /// Permissions formatted as 9 `rwx` characters followed by the octal mode, e.g.
    /// `"rw-r--r-- (0644)"`.
    public var formattedPermissions: String {
        let m = posixMode
        let groups: [(UInt16, UInt16, UInt16, UInt16, String, String)] = [
            (UInt16(S_IRUSR), UInt16(S_IWUSR), UInt16(S_IXUSR), UInt16(S_ISUID), "s", "S"),
            (UInt16(S_IRGRP), UInt16(S_IWGRP), UInt16(S_IXGRP), UInt16(S_ISGID), "s", "S"),
            (UInt16(S_IROTH), UInt16(S_IWOTH), UInt16(S_IXOTH), UInt16(S_ISVTX), "t", "T"),
        ]
        let rwx = groups.map { r, w, x, sp, se, so in
            let xc = (m & sp) != 0 ? ((m & x) != 0 ? se : so) : ((m & x) != 0 ? "x" : "-")
            return ((m & r) != 0 ? "r" : "-") + ((m & w) != 0 ? "w" : "-") + xc
        }.joined()
        let oct = String(m, radix: 8)
        return "\(rwx) (\(String(repeating: "0", count: max(0, 4 - oct.count)) + oct))"
    }

    private static func classify(url: URL, lstatInfo: stat, isLink: Bool) -> ClassifiedTarget {
        guard isLink else {
            return classifyTarget(url: url, info: lstatInfo, target: nil)
        }
        let target = readSymlinkTarget(at: url.path)
        var targetInfo = stat()
        guard stat(url.path, &targetInfo) == 0 else {
            let isDataless = (lstatInfo.st_flags & UInt32(SF_DATALESS)) != 0
            return (false, false, isDataless, .symbolicLink, nil, nil, target)
        }
        return classifyTarget(
            url: url.resolvingSymlinksInPath(), info: targetInfo, target: target)
    }

    private static func classifyTarget(url: URL, info: stat, target: String?) -> ClassifiedTarget {
        let isDataless = (info.st_flags & UInt32(SF_DATALESS)) != 0
        let fileType = info.st_mode & S_IFMT
        if fileType == S_IFDIR {
            var clean = url
            clean.removeAllCachedResourceValues()
            let isPackage = (try? clean.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
            let utType = TypeNames.type(
                named: url.lastPathComponent, folder: !isPackage, package: isPackage)
            return (!isPackage, isPackage, isDataless, utType, nil, nil, target)
        }
        let utType = TypeNames.type(named: url.lastPathComponent, folder: false, package: false)
        guard fileType == S_IFREG else {
            return (false, false, isDataless, utType, nil, nil, target)
        }
        let size = info.st_size >= 0 ? UInt64(info.st_size) : 0
        let blocks = UInt64(max(0, info.st_blocks)).multipliedReportingOverflow(by: 512)
        let allocated: UInt64? = blocks.overflow ? nil : blocks.partialValue
        return (false, false, isDataless, utType, size, allocated, target)
    }

    private static func readSymlinkTarget(at path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(path, &buffer, buffer.count - 1)
        guard length >= 0 else { return nil }
        return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func date(from spec: timespec) -> Date? {
        guard spec.tv_sec != 0 || spec.tv_nsec != 0 else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec)
                / 1_000_000_000)
    }

    private static func resolveName(
        fallback: String, hint: Int,
        lookup: (UnsafeMutablePointer<CChar>, Int) -> (Int32, String?)
    ) -> String {
        var size = max(hint, 4096)
        for _ in 0..<4 {
            var buffer = [CChar](repeating: 0, count: size)
            let (status, name) = buffer.withUnsafeMutableBufferPointer { ptr in
                ptr.baseAddress.map { lookup($0, size) } ?? (EINVAL, nil)
            }
            if status == 0, let name { return name }
            if status != ERANGE { break }
            size *= 2
        }
        return fallback
    }

    private static func bsdFlags(from stFlags: UInt32, isDataless: Bool) -> [String] {
        var result: [String] = []
        if (stFlags & (UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE))) != 0 {
            result.append("Locked")
        }
        if (stFlags & UInt32(UF_HIDDEN)) != 0 { result.append("Hidden") }
        if isDataless { result.append("Dataless") }
        return result
    }

    private static func readExtendedAttributes(at path: String) -> ([ExtendedAttribute], Bool) {
        var buffer: [CChar] = []
        var bytesRead = 0
        for _ in 0..<4 {
            let totalBytes = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            guard totalBytes > 0 else { return ([], false) }
            buffer = [CChar](repeating: 0, count: totalBytes)
            bytesRead = listxattr(path, &buffer, totalBytes, XATTR_NOFOLLOW)
            if bytesRead >= 0 { break }
            if errno != ERANGE { return ([], false) }
        }
        guard bytesRead > 0 else { return ([], false) }

        let names = buffer[..<bytesRead].split(separator: 0).compactMap { slice -> String? in
            guard !slice.isEmpty else { return nil }
            return String(decoding: slice.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }.sorted()

        let hasMore = names.count > maxExtendedAttributes
        let attributes: [ExtendedAttribute] = names.prefix(maxExtendedAttributes).compactMap {
            name in
            let attrSize = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            return attrSize >= 0 ? ExtendedAttribute(name: name, size: attrSize) : nil
        }
        return (attributes, hasMore)
    }
}
