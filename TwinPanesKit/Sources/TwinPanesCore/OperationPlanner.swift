import Foundation

/// One item an operation will copy, found by walking a source.
public struct PlannedItem: Sendable, Equatable {
    public let source: URL
    /// The path below the destination folder: the top-level source's name, then the
    /// path inside it ("Photos/2024/a.jpg").
    public let relativePath: String
    public let metadata: FileItemMetadata
}

/// What walking a source found: its items, folders before what's inside them, and the
/// items that couldn't be read (a folder's contents are then left out; the operation
/// reports them as failed).
public struct SourceWalk: Sendable {
    public var items: [PlannedItem] = []
    public var unreadable: [FileSystemError] = []

    public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.metadata.size } }
    public var fileCount: Int { items.count { $0.metadata.kind == .file } }
}

/// Why an operation can't start at all.
public enum PlanningRefusal: Error, Equatable {
    case sourceMissing(URL)
    /// A folder copied or moved into itself or a folder inside it.
    case intoItself(URL)
    case destinationMissing(URL)
    case destinationNotWritable(URL)
}

/// Checks an operation's sources and destination and walks the sources, off the main
/// actor (docs/plans/M6.md, D-c). Symlinks aren't followed; packages are folders.
public struct OperationPlanner: Sendable {
    let fileSystem: any FileOperationSystem

    public init(fileSystem: any FileOperationSystem) {
        self.fileSystem = fileSystem
    }

    /// Refuses what can't work before anything is touched.
    public func check(sources: [URL], destination: URL) throws(PlanningRefusal) {
        let resolvedDest = destination.resolvingSymlinksInPath()
        guard (try? fileSystem.metadata(of: resolvedDest))?.kind == .folder else {
            throw .destinationMissing(destination)
        }
        let caseSensitive = BookmarkStore.isCaseSensitive(resolvedDest)
        let target = Self.folderPath(resolvedDest)
        let matchOptions: String.CompareOptions =
            caseSensitive ? [.anchored] : [.anchored, .caseInsensitive]
        for source in sources {
            guard let metadata = try? fileSystem.metadata(of: source) else {
                throw .sourceMissing(source)
            }
            if metadata.kind == .folder,
                target.range(of: Self.folderPath(source), options: matchOptions) != nil
            {
                throw .intoItself(source)
            }
        }
        guard fileSystem.canWrite(into: resolvedDest) else {
            throw .destinationNotWritable(destination)
        }
    }

    /// `url`'s canonical path with one trailing "/", so a prefix test can't match a
    /// sibling whose name starts the same ("tree2" isn't inside "tree").
    private static func folderPath(_ url: URL) -> String {
        let path = BookmarkStore.canonicalPath(url)
        return path.hasSuffix("/") ? path : path + "/"
    }

    /// Every item of `source` with the path it gets below a destination. Stops early,
    /// returning what it has, once `isCancelled` says so.
    public func walk(_ source: URL, isCancelled: () -> Bool = { false }) -> SourceWalk {
        var walk = SourceWalk()
        // Depth first with a stack: a folder is listed when it's taken off, after its
        // own item was added, so folders come before their contents.
        var pending = [(url: source, relativePath: source.lastPathComponent)]
        while let next = pending.popLast(), !isCancelled() {
            let metadata: FileItemMetadata
            do {
                metadata = try fileSystem.metadata(of: next.url)
            } catch {
                walk.unreadable.append(error)
                continue
            }
            walk.items.append(
                PlannedItem(source: next.url, relativePath: next.relativePath, metadata: metadata))
            guard metadata.kind == .folder else { continue }
            do {
                for name in try fileSystem.contents(of: next.url).sorted().reversed() {
                    pending.append(
                        (next.url.appendingPathComponent(name), next.relativePath + "/" + name))
                }
            } catch {
                walk.unreadable.append(error)
            }
        }
        return walk
    }
}
