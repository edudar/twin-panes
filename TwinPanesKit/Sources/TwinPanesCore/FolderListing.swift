import Foundation

/// How a folder's entries are ordered (docs/plans/M4.md, D-c).
public struct ListingOrder: Hashable, Sendable {
    public enum Column: String, CaseIterable, Sendable {
        case name, size, modified, kind
    }

    public var column: Column
    public var ascending: Bool
    /// Folders above files in either direction, as Finder's "Keep folders on top".
    public var foldersFirst: Bool

    public init(column: Column = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.column = column
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }

    /// The order's comparison. Ties on the column fall back to the name, ascending,
    /// and then to the raw name, so the order is total.
    public func areInIncreasingOrder(_ a: DirectoryEntry, _ b: DirectoryEntry) -> Bool {
        if foldersFirst, a.isDirectory != b.isDirectory { return a.isDirectory }
        let primary: ComparisonResult
        switch column {
        case .name: primary = a.name.localizedStandardCompare(b.name)
        case .size: primary = Self.compare(a.size, b.size)
        case .modified: primary = Self.compare(a.modified, b.modified)
        case .kind: primary = a.kind.localizedStandardCompare(b.kind)
        }
        if primary != .orderedSame {
            return (primary == .orderedAscending) == ascending
        }
        if column != .name {
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
        }
        return a.name < b.name
    }

    /// Missing values (a folder's size, an unknown date) sort first.
    static func compare<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case (let a?, let b?):
            return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }
    }
}

/// One folder's entries in display order, and the rows shown after the hidden-files
/// filter (docs/plans/M4.md, D-c, D-e). A value: big sorts and merges run off the main
/// actor on a copy, and the result replaces the tab's listing if it's still current.
public struct FolderListing: Sendable {
    /// Every entry, hidden ones included, sorted by `order`.
    public private(set) var entries: [DirectoryEntry] = []
    /// What the table shows.
    public private(set) var rows: [DirectoryEntry] = []
    public private(set) var order: ListingOrder
    public private(set) var showsHidden: Bool

    public init(order: ListingOrder = ListingOrder(), showsHidden: Bool = false) {
        self.order = order
        self.showsHidden = showsHidden
    }

    public var hiddenCount: Int { showsHidden ? 0 : entries.count - rows.count }

    /// Above this many entries, sorting and merging belong off the main actor.
    public static let mainActorLimit = 5_000

    /// Adds a batch from the lister: sorts it, then merges it into place.
    public func merging(_ batch: [DirectoryEntry]) -> FolderListing {
        let order = self.order
        let sortedBatch = batch.sorted(by: order.areInIncreasingOrder)
        var merged: [DirectoryEntry] = []
        merged.reserveCapacity(entries.count + sortedBatch.count)
        var i = entries.startIndex
        var j = sortedBatch.startIndex
        while i < entries.endIndex, j < sortedBatch.endIndex {
            if order.areInIncreasingOrder(sortedBatch[j], entries[i]) {
                merged.append(sortedBatch[j])
                j += 1
            } else {
                merged.append(entries[i])
                i += 1
            }
        }
        merged += entries[i...]
        merged += sortedBatch[j...]
        var copy = self
        copy.entries = merged
        copy.filter()
        return copy
    }

    /// Drops the entries called any of `names` (D-f: a live update removes an entry's
    /// old version, then merges the new one, if any, as a batch).
    public func removing(names: Set<String>) -> FolderListing {
        guard !names.isEmpty else { return self }
        var copy = self
        copy.entries.removeAll { names.contains($0.name) }
        copy.filter()
        return copy
    }

    public func sorted(by order: ListingOrder) -> FolderListing {
        var copy = self
        copy.order = order
        copy.entries.sort(by: order.areInIncreasingOrder)
        copy.filter()
        return copy
    }

    public func showingHidden(_ shows: Bool) -> FolderListing {
        var copy = self
        copy.showsHidden = shows
        copy.filter()
        return copy
    }

    /// The row showing the entry called `name`, if it's shown.
    public func row(named name: String) -> Int? { rows.firstIndex { $0.name == name } }

    private mutating func filter() {
        rows = showsHidden ? entries : entries.filter { !$0.isHidden }
    }
}
