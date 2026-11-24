import Foundation

/// Rows a live update changed: `removed` in the old rows, `inserted` and `changed` in the
/// new ones, each ascending.
public struct RowChanges: Equatable, Sendable {
    public var removed: [Int]
    public var inserted: [Int]
    public var changed: [Int]
    /// The row counts before and after, so a table can check the changes are its own.
    public var oldCount: Int
    public var newCount: Int
}

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
    /// How many of the rows are folders, counted with the filter, so the status line
    /// doesn't walk 100k rows on the main actor.
    public private(set) var folderCount = 0

    public init(order: ListingOrder = ListingOrder(), showsHidden: Bool = false) {
        self.order = order
        self.showsHidden = showsHidden
    }

    public var hiddenCount: Int { showsHidden ? 0 : entries.count - rows.count }

    /// Above this many entries, sorting and merging belong off the main actor.
    public static let mainActorLimit = 500

    /// Adds a batch from the lister: deduplicates by name (keeping the latest entry),
    /// sorts it, and merges it into place, replacing any older copy with the same name.
    public func merging(_ batch: [DirectoryEntry]) -> FolderListing {
        guard !batch.isEmpty else { return self }
        let order = self.order
        var batchNames = Set<String>()
        batchNames.reserveCapacity(batch.count)
        var unique: [DirectoryEntry] = []
        unique.reserveCapacity(batch.count)
        for entry in batch.reversed() where batchNames.insert(entry.name).inserted {
            unique.append(entry)
        }
        let sortedBatch = unique.sorted(by: order.areInIncreasingOrder)
        var merged: [DirectoryEntry] = []
        merged.reserveCapacity(entries.count + sortedBatch.count)
        var i = entries.startIndex
        var j = sortedBatch.startIndex
        while i < entries.endIndex {
            if batchNames.contains(entries[i].name) {
                i += 1
                continue
            }
            if j < sortedBatch.endIndex, order.areInIncreasingOrder(sortedBatch[j], entries[i]) {
                merged.append(sortedBatch[j])
                j += 1
            } else {
                merged.append(entries[i])
                i += 1
            }
        }
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

    /// The rows of the entries called any of `names`, in one pass: for restoring the
    /// selection without a search per name on the main actor.
    public func rows(named names: Set<String>) -> [String: Int] {
        guard !names.isEmpty else { return [:] }
        var found: [String: Int] = [:]
        for (row, entry) in rows.enumerated() where names.contains(entry.name) {
            found[entry.name] = row
            if found.count == names.count { break }
        }
        return found
    }

    /// How the rows changed from `old` when only the entries called `names` did (a live
    /// update): the old rows that went, the new rows that came, and the new rows that were
    /// read again in place. Touched entries whose sort position moved are reported as removed
    /// from their old row and inserted at their new row. Nil if `order` or `showsHidden`
    /// changed or more than `limit` row operations are needed.
    public func rowChanges(
        from old: FolderListing, touching names: Set<String>, limit: Int
    ) -> RowChanges? {
        guard order == old.order, showsHidden == old.showsHidden else { return nil }
        let before = old.rows(named: names)
        let after = rows(named: names)
        guard before.count + after.count <= 2 * limit else { return nil }
        let beforeOrdered = before.sorted { $0.value < $1.value }
        let afterOrdered = after.sorted { $0.value < $1.value }
        // Count how many untouched rows precede each touched entry in `old.rows`; a moved
        // entry either changes that count or swaps order relative to another touched entry.
        var oldGap = [String: Int](minimumCapacity: beforeOrdered.count)
        for (offset, item) in beforeOrdered.enumerated() {
            oldGap[item.key] = item.value - offset
        }
        var stay = Set<String>()
        var lastStayBefore = -1
        for (offset, item) in afterOrdered.enumerated() {
            guard let beforeRow = before[item.key],
                oldGap[item.key] == item.value - offset,
                beforeRow > lastStayBefore
            else { continue }
            stay.insert(item.key)
            lastStayBefore = beforeRow
        }
        let removed = beforeOrdered.compactMap { stay.contains($0.key) ? nil : $0.value }
        let inserted = afterOrdered.compactMap { stay.contains($0.key) ? nil : $0.value }
        let changed = afterOrdered.compactMap { stay.contains($0.key) ? $0.value : nil }
        guard removed.count + inserted.count + changed.count <= limit else { return nil }
        return RowChanges(
            removed: removed, inserted: inserted, changed: changed, oldCount: old.rows.count,
            newCount: rows.count)
    }

    private mutating func filter() {
        rows = showsHidden ? entries : entries.filter { !$0.isHidden }
        folderCount = rows.reduce(0) { $0 + ($1.isDirectory ? 1 : 0) }
    }
}
