import Foundation

/// Why a name can't be used.
public enum NameRefusal: Error, Equatable {
    case empty
    /// "/" separates folders; "." and ".." name folders that are already there.
    case notAName
    /// Longer than the 255 bytes a file name may have.
    case tooLong
    case taken(URL)
    case failed(FileSystemError)
}

/// F2 and F7: renaming an item and making a folder (docs/plans/M6.md, D-c), each one
/// call that never replaces what's there.
public struct ItemNamer: Sendable {
    let fileSystem: any FileOperationSystem

    public init(fileSystem: any FileOperationSystem) { self.fileSystem = fileSystem }

    /// Renames `item` within its folder; returns where it is now.
    public func rename(_ item: URL, to name: String) throws(NameRefusal) -> MovedItem {
        let target = try validate(name, in: item.deletingLastPathComponent())
        if (try? fileSystem.metadata(of: target)) != nil {
            let isCaseOnly =
                BookmarkStore.sameEntry(item, target) && name != item.lastPathComponent
            if !isCaseOnly { throw .taken(target) }
        }
        do {
            try fileSystem.rename(item, to: target)
        } catch {
            throw error.errno == EEXIST ? .taken(target) : .failed(error)
        }
        return MovedItem(from: item, to: target)
    }

    /// Makes an empty folder called `name` in `folder`.
    public func makeFolder(named name: String, in folder: URL) throws(NameRefusal) -> URL {
        let target = try validate(name, in: folder)
        if (try? fileSystem.metadata(of: target)) != nil { throw .taken(target) }
        do {
            try fileSystem.makeFolder(at: target)
        } catch {
            throw error.errno == EEXIST ? .taken(target) : .failed(error)
        }
        return target
    }

    /// Where an item called `name` goes in `folder`, if that's a usable name.
    private func validate(_ name: String, in folder: URL) throws(NameRefusal) -> URL {
        guard !name.isEmpty else { throw .empty }
        guard !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else {
            throw .notAName
        }
        guard name.utf8.count <= Int(NAME_MAX) else { throw .tooLong }
        return folder.appendingPathComponent(name)
    }
}
