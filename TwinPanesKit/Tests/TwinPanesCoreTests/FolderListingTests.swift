import Foundation
import Testing
import UniformTypeIdentifiers

@testable import TwinPanesCore

/// The folder model: orders, batches merged into place, the hidden filter
/// (docs/plans/M4.md, D-c, D-e, step 3).
@Suite struct FolderListingTests {
    /// Random entries with clashing sizes, dates and kinds, so ties get exercised. Names
    /// are unique, as in a real folder, but share stems and numbers.
    static func entries(_ count: Int, seed: UInt64) -> [DirectoryEntry] {
        var rng = SplitMix64(seed: seed)
        let stems = ["a", "B", "file", "File", "Ångström", "img10", "img2", "x"]
        let types: [UTType] = [.plainText, .png, .data, .json]
        return (0..<count).map { i in
            let folder = rng.next() % 5 == 0
            let name =
                stems[Int(rng.next() % 8)] + "\(rng.next() % 50)-\(i)" + (folder ? "" : ".\(i % 3)")
            let hidden = rng.next() % 7 == 0
            return DirectoryEntry(
                url: URL(fileURLWithPath: "/tmp/\(i)/\(name)"), name: hidden ? "." + name : name,
                isDirectory: folder, isPackage: false, isSymbolicLink: false, isHidden: hidden,
                size: folder ? nil : rng.next() % 4 == 0 ? 100 : rng.next() % 10_000,
                modified: rng.next() % 9 == 0
                    ? nil : Date(timeIntervalSince1970: Double(rng.next() % 1_000)),
                type: folder ? .folder : types[Int(rng.next() % 4)])
        }
    }

    static let orders: [ListingOrder] = ListingOrder.Column.allCases.flatMap { column in
        [true, false].flatMap { ascending in
            [true, false].map {
                ListingOrder(column: column, ascending: ascending, foldersFirst: $0)
            }
        }
    }

    @Test(arguments: orders)
    func batchesMergeToTheSameOrderAsOneSort(order: ListingOrder) {
        let all = Self.entries(600, seed: 7)
        var listing = FolderListing(order: order, showsHidden: true)
        var rest = all[...]
        var size = 1
        while !rest.isEmpty {  // batch sizes 1, 2, 4, …, as a lister might send them
            listing = listing.merging(Array(rest.prefix(size)))
            rest = rest.dropFirst(size)
            size *= 2
        }
        let once = FolderListing(order: order, showsHidden: true).merging(all)
        #expect(listing.entries == once.entries)
        #expect(Set(listing.entries) == Set(all) && listing.entries.count == all.count)
        for (a, b) in zip(listing.entries, listing.entries.dropFirst()) {
            #expect(!order.areInIncreasingOrder(b, a), "\(order): \(b.name) before \(a.name)")
        }
    }

    @Test(arguments: orders)
    func theOrderIsTotalAndFoldersStayOnTop(order: ListingOrder) {
        let all = Self.entries(300, seed: 11)
        let sorted = FolderListing(order: order).merging(all).sorted(by: order).entries
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            #expect(order.areInIncreasingOrder(a, b) != order.areInIncreasingOrder(b, a) || a == b)
            if order.foldersFirst { #expect(a.isDirectory || !b.isDirectory) }
        }
    }

    @Test func descendingReversesTheColumnNotTheFolders() {
        let all = Self.entries(200, seed: 3).filter { $0.size != 100 }
        let up = FolderListing(order: ListingOrder(column: .size)).merging(all)
        let down = up.sorted(by: ListingOrder(column: .size, ascending: false))
        #expect(down.entries.first?.isDirectory == true)
        let files = { (l: FolderListing) in l.entries.filter { !$0.isDirectory }.map(\.size) }
        #expect(files(down) == files(up).reversed())
    }

    /// Kind is stored with the entry when it's read (docs/plans/M4.md, performance pass,
    /// step 2): a Kind sort compares what's stored, without looking each type up again.
    @Test func kindSortsByTheStoredDescription() {
        let kinds = ["Zebra file", "apple file", "Mango file"]
        let entries = kinds.enumerated().map { i, kind in
            DirectoryEntry(
                url: URL(fileURLWithPath: "/tmp/k\(i)"), name: "k\(i)", isDirectory: false,
                isPackage: false, isSymbolicLink: false, isHidden: false, size: 1,
                modified: nil, type: .plainText, kind: kind)
        }
        let listing = FolderListing(order: ListingOrder(column: .kind), showsHidden: false)
            .merging(entries)
        #expect(listing.rows.map(\.kind) == ["apple file", "Mango file", "Zebra file"])
        #expect(entries[0].kind == "Zebra file")
        let looked = DirectoryEntry(
            url: URL(fileURLWithPath: "/tmp/t"), name: "t", isDirectory: false,
            isPackage: false, isSymbolicLink: false, isHidden: false, size: 1, modified: nil,
            type: .folder)
        #expect(looked.kind == "Folder")
    }

    @Test func namesSortAsInFinder() {
        let names = ["img10.png", "img2.png", "Ångström", "apple", "Banana"]
        let entries = names.map { name in
            DirectoryEntry(
                url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isDirectory: false,
                isPackage: false, isSymbolicLink: false, isHidden: false, size: 1, modified: nil,
                type: .data)
        }
        let rows = FolderListing().merging(entries).rows.map(\.name)
        #expect(rows == ["Ångström", "apple", "Banana", "img2.png", "img10.png"])
    }

    /// A live update: remove the old versions, merge the new ones; the order holds.
    @Test(arguments: orders)
    func updatesKeepTheOrder(order: ListingOrder) {
        let all = Self.entries(300, seed: 13)
        let listing = FolderListing(order: order, showsHidden: true).merging(all)
        let gone = Set(all.prefix(40).map(\.name))
        let replaced = all.dropFirst(40).prefix(20).map { old in
            DirectoryEntry(
                url: old.url, name: old.name, isDirectory: old.isDirectory, isPackage: false,
                isSymbolicLink: false, isHidden: old.isHidden, size: (old.size ?? 0) + 7_777,
                modified: nil, type: old.type)
        }
        let updated = listing.removing(names: gone.union(replaced.map(\.name))).merging(replaced)
        let expected = FolderListing(order: order, showsHidden: true)
            .merging(Array(all.dropFirst(60)) + replaced)
        #expect(updated.entries == expected.entries)
        #expect(listing.removing(names: []).entries == listing.entries)
    }

    /// The row changes of a live update match what a table needs: remove the old rows,
    /// insert the new ones, and the result lines up with the new rows.
    @Test(arguments: orders)
    func rowChangesReplayToTheNewRows(order: ListingOrder) throws {
        let all = Self.entries(300, seed: 17)
        let old = FolderListing(order: order).merging(all)
        let gone = Set(all.prefix(10).map(\.name))
        let fresh = Self.entries(8, seed: 99).map { entry in
            DirectoryEntry(
                url: entry.url, name: "new-" + entry.name, isDirectory: entry.isDirectory,
                isPackage: false, isSymbolicLink: false, isHidden: entry.isHidden, size: entry.size,
                modified: entry.modified, type: entry.type)
        }
        let touched = gone.union(fresh.map(\.name)).union([all[20].name])
        let new = old.removing(names: gone.union([all[20].name])).merging(fresh + [all[20]])
        let changes = try #require(new.rowChanges(from: old, touching: touched, limit: 100))
        var replay = old.rows.map(\.name)
        for row in changes.removed.reversed() { replay.remove(at: row) }
        for row in changes.inserted { replay.insert(new.rows[row].name, at: row) }
        #expect(replay == new.rows.map(\.name))
        #expect(
            changes.changed.map { new.rows[$0].name } == (all[20].isHidden ? [] : [all[20].name]))
        #expect(new.rowChanges(from: old, touching: touched, limit: 3) == nil)
        #expect(new.folderCount == new.rows.filter(\.isDirectory).count)
        #expect(new.rows(named: [all[30].name, "missing"]).count == (all[30].isHidden ? 0 : 1))
    }

    /// Touched entries whose sort key changed enough to move them past other rows are
    /// removed from their old rows and inserted at their new rows so replaying the changes
    /// still matches the new listing.
    @Test(arguments: orders)
    func rowChangesReplayWhenEntriesMoveRank(order: ListingOrder) throws {
        let all = Self.entries(300, seed: 23)
        let old = FolderListing(order: order).merging(all)
        let visible = old.rows
        let gone = Set([visible[1].name, visible[50].name, visible[100].name])
        let movedTargets = [visible[5], visible[6], visible[25], visible[75], visible[120]]
        var replacements: [DirectoryEntry] = []
        for (idx, e) in movedTargets.enumerated() {
            let flippedKind = idx == 2 ? !e.isDirectory : e.isDirectory
            let flippedSize: UInt64? =
                flippedKind ? nil : (idx.isMultiple(of: 2) ? 99_999 - UInt64(idx) : 0)
            let flippedDate = Date(
                timeIntervalSince1970: idx.isMultiple(of: 2) ? 2_000_000 : 1)
            let flippedType: UTType = flippedKind ? .folder : (e.type == .png ? .json : .png)
            replacements.append(
                DirectoryEntry(
                    url: e.url, name: e.name, isDirectory: flippedKind, isPackage: false,
                    isSymbolicLink: false, isHidden: false, size: flippedSize,
                    modified: flippedDate, type: flippedType))
        }
        let staysInPlace = visible[150]
        let fresh = DirectoryEntry(
            url: URL(fileURLWithPath: "/tmp/fresh-move"), name: "fresh-move.txt",
            isDirectory: false, isPackage: false, isSymbolicLink: false, isHidden: false,
            size: 500, modified: Date(timeIntervalSince1970: 500), type: .plainText)
        let touched = gone.union(replacements.map(\.name)).union([staysInPlace.name, fresh.name])
        let new = old.removing(names: touched).merging(replacements + [staysInPlace, fresh])
        let changes = try #require(new.rowChanges(from: old, touching: touched, limit: 100))
        var replay = old.rows
        for row in changes.removed.reversed() { replay.remove(at: row) }
        for row in changes.inserted { replay.insert(new.rows[row], at: row) }
        for row in changes.changed { replay[row] = new.rows[row] }
        #expect(replay == new.rows)
        #expect(
            new.sorted(by: ListingOrder(column: order.column == .name ? .size : .name))
                .rowChanges(from: old, touching: touched, limit: 100) == nil)
        #expect(new.showingHidden(true).rowChanges(from: old, touching: touched, limit: 100) == nil)
    }

    @Test(arguments: orders)
    func mergingDeduplicatesByName(order: ListingOrder) {
        let base = Self.entries(40, seed: 31)
        let dupSource = base[0]
        let updatedInSameBatch = DirectoryEntry(
            url: dupSource.url, name: dupSource.name, isDirectory: dupSource.isDirectory,
            isPackage: false, isSymbolicLink: false, isHidden: dupSource.isHidden,
            size: dupSource.isDirectory ? nil : 88_888,
            modified: Date(timeIntervalSince1970: 9_999), type: dupSource.type)
        let first = FolderListing(order: order, showsHidden: true)
            .merging(base + [updatedInSameBatch])
        #expect(first.entries.count == base.count)
        #expect(first.entries.first { $0.name == dupSource.name } == updatedInSameBatch)
        let nextTarget = base[10]
        let updatedInNextBatch = DirectoryEntry(
            url: nextTarget.url, name: nextTarget.name, isDirectory: !nextTarget.isDirectory,
            isPackage: false, isSymbolicLink: false, isHidden: nextTarget.isHidden,
            size: nextTarget.isDirectory ? 1 : nil,
            modified: Date(timeIntervalSince1970: 12_345),
            type: nextTarget.isDirectory ? .plainText : .folder)
        let second = first.merging([updatedInNextBatch])
        let expectedMap = Dictionary(
            (base + [updatedInSameBatch, updatedInNextBatch]).map { ($0.name, $0) },
            uniquingKeysWith: { _, new in new })
        let expected = expectedMap.values.sorted(by: order.areInIncreasingOrder)
        #expect(second.entries == expected)
        #expect(second.merging([]).entries == second.entries)
        #expect(second.merging([]).rows == second.rows)
    }

    @Test func hiddenEntriesAreFilteredNotDropped() {
        let all = Self.entries(400, seed: 5)
        let hidden = all.filter(\.isHidden).count
        let listing = FolderListing().merging(all)
        #expect(listing.rows.count == all.count - hidden && listing.hiddenCount == hidden)
        #expect(!listing.rows.contains { $0.isHidden })
        let shown = listing.showingHidden(true)
        #expect(shown.rows == shown.entries && shown.hiddenCount == 0)
        #expect(shown.showingHidden(false).rows == listing.rows)
        let name = try? #require(listing.rows.last?.name)
        #expect(name.flatMap(listing.row(named:)) == listing.rows.count - 1)
        #expect(listing.row(named: all.first { $0.isHidden }!.name) == nil)
    }
}
