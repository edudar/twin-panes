import Foundation

/// Selected rows of a folder listing, kept with the listing they were selected in so
/// they can be found again in a newer listing by name. Working out the names walks the
/// selection, so for a big one it runs off the main actor (D39; docs/plans/M6.md, D-a):
/// building 100k names on the main actor took 160 ms in the Debug build.
public struct ListingSelection: Sendable {
    /// Rows of `listing`.
    public let rows: IndexSet
    public let listing: FolderListing

    public init(rows: IndexSet, of listing: FolderListing) {
        self.rows = rows.intersection(IndexSet(integersIn: listing.rows.indices))
        self.listing = listing
    }

    public static let none = ListingSelection(
        rows: [], of: FolderListing(order: ListingOrder(), showsHidden: false))

    public var count: Int { rows.count }
    public var isEmpty: Bool { rows.isEmpty }

    /// The selected entries, in row order.
    public var entries: [DirectoryEntry] { rows.map { listing.rows[$0] } }

    /// The rows of `other` showing the selected entries: after a sort, a filter or an
    /// update, the same names wherever they are now.
    public func rows(in other: FolderListing) -> IndexSet {
        guard !rows.isEmpty else { return [] }
        let names = Set(rows.map { listing.rows[$0].name })
        return IndexSet(other.rows(named: names).values)
    }
}
