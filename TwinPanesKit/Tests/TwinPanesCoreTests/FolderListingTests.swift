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
