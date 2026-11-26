import Foundation
import Testing
import UniformTypeIdentifiers

@testable import TwinPanesCore

@Suite struct ListingSelectionTests {
    private func entry(_ name: String, isHidden: Bool = false, size: UInt64 = 1) -> DirectoryEntry {
        DirectoryEntry(
            url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isDirectory: false,
            isPackage: false, isSymbolicLink: false, isHidden: isHidden, size: size,
            modified: nil, type: .plainText)
    }

    private func listing(_ entries: [DirectoryEntry], showsHidden: Bool = true) -> FolderListing {
        FolderListing(order: ListingOrder(), showsHidden: showsHidden).merging(entries)
    }

    @Test func clampsOutOfBoundsRowsAndHandlesEmptyListings() {
        let nonempty = listing([entry("a"), entry("b"), entry("c")])
        let clamped = ListingSelection(rows: IndexSet([0, 2, 5, 99]), of: nonempty)
        #expect(clamped.rows == IndexSet([0, 2]) && clamped.count == 2 && !clamped.isEmpty)

        let empty = FolderListing(order: ListingOrder(), showsHidden: false)
        let fromEmpty = ListingSelection(rows: IndexSet([0, 1]), of: empty)
        #expect(fromEmpty.isEmpty && fromEmpty.count == 0 && fromEmpty.entries.isEmpty)
        #expect(ListingSelection.none.isEmpty && ListingSelection.none.rows(in: nonempty).isEmpty)
    }

    @Test func entriesFollowRowOrder() {
        let list = listing([entry("c"), entry("a"), entry("b")])
        let selection = ListingSelection(rows: IndexSet([2, 0]), of: list)
        #expect(selection.entries.map(\.name) == ["a", "c"])
    }

    @Test func rowsInOtherListingTracksReordersAdditionsAndRemovals() {
        let original = listing([
            entry("a", size: 30), entry("b", size: 10), entry("c", size: 40),
            entry(".hidden", isHidden: true, size: 20),
        ])
        let selection = ListingSelection(rows: IndexSet([0, 2]), of: original)
        #expect(selection.entries.map(\.name) == [".hidden", "b"])

        let reordered = original.sorted(by: ListingOrder(column: .size, ascending: true))
        #expect(selection.rows(in: reordered) == IndexSet([0, 1]))

        let withAdditions = original.merging([entry("aa"), entry("bb")])
        #expect(selection.rows(in: withAdditions) == IndexSet([0, 3]))

        let hidingDotfiles = original.showingHidden(false)
        #expect(selection.rows(in: hidingDotfiles) == IndexSet([1]))

        let allGone = hidingDotfiles.removing(names: ["b"])
        #expect(selection.rows(in: allGone).isEmpty)
    }
}
