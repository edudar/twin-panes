import Foundation
import TwinPanesCore
import WorkspaceKit

/// What a browser tab saves to come back after a relaunch (docs/plans/M5.md, D-c).
/// Folders are paths, not bookmarks: access comes from the saved folder grants (D42).
struct BrowserState: Codable, Equatable {
    struct Place: Codable, Equatable {
        var path: String
        var selected: String?
    }

    var folder: String
    var selected: String?
    var back: [Place]
    var forward: [Place]
    var sortColumn: String
    var ascending: Bool
    var foldersFirst: Bool
    var showsHidden: Bool
}

extension BrowserItem {
    /// The `BrowserState` format this build writes and reads.
    public static let stateVersion = 1

    public var restorableState: ItemState? {
        func place(_ entry: HistoryEntry) -> BrowserState.Place {
            BrowserState.Place(path: entry.folder.path, selected: entry.selected)
        }
        let state = BrowserState(
            folder: folder.path,
            selected: hasListed
                ? (controller.selectedName ?? controller.wantedSelection) : restoredSelection,
            back: backStack.map(place), forward: forwardStack.map(place),
            sortColumn: order.column.rawValue, ascending: order.ascending,
            foldersFirst: order.foldersFirst, showsHidden: showsHidden)
        // Encoding strings and Booleans doesn't fail; if it did, the tab would only be
        // left out of the saved window.
        guard let payload = try? JSONEncoder().encode(state) else { return nil }
        return ItemState(kind: .browser, version: Self.stateVersion, payload: payload)
    }

    /// Rebuilds a tab from saved state, or returns nil when the payload isn't a
    /// browser's. The tab lists its folder when its view loads, like a new one; a folder
    /// that's gone opens its nearest existing ancestor and says so in the status line.
    public static func restored(
        from state: ItemState, grants: FolderGrants,
        openFile: @escaping (URL, SecurityScope?) -> Void
    ) -> BrowserItem? {
        // Nil is the restorer's "can't use this state": the tab is skipped.
        guard state.kind == .browser,
            (1...Self.stateVersion).contains(state.version),
            let saved = try? JSONDecoder().decode(BrowserState.self, from: state.payload),
            saved.folder.hasPrefix("/")
        else { return nil }
        let wanted = URL(fileURLWithPath: saved.folder, isDirectory: true).standardizedFileURL
        let folder = nearestFolderThere(at: wanted, grants: grants)
        let item = BrowserItem(folder: folder, grants: grants, openFile: openFile)
        // A column this build doesn't know sorts by name rather than losing the tab.
        let column = ListingOrder.Column(rawValue: saved.sortColumn) ?? .name
        item.order = ListingOrder(
            column: column, ascending: saved.ascending, foldersFirst: saved.foldersFirst)
        item.showsHidden = saved.showsHidden
        item.backStack = Array(
            saved.back.filter { $0.path.hasPrefix("/") }.map(historyEntry).suffix(Self.maxHistory))
        item.forwardStack = Array(
            saved.forward.filter { $0.path.hasPrefix("/") }.map(historyEntry)
                .suffix(Self.maxHistory))
        if folder.path == wanted.path {
            item.restoredSelection = saved.selected
        } else {
            item.restoredNotice =
                "“\(wanted.lastPathComponent)” is no longer there · showing \(folder.path)"
        }
        return item
    }

    private static func historyEntry(_ place: BrowserState.Place) -> HistoryEntry {
        HistoryEntry(
            folder: URL(fileURLWithPath: place.path, isDirectory: true).standardizedFileURL,
            selected: place.selected)
    }

    /// The nearest folder at or above `url` that's still there. One the sandbox needs
    /// access for counts: the tab shows the access prompt for it, as for any folder.
    private static func nearestFolderThere(at url: URL, grants: FolderGrants) -> URL {
        var candidate = url
        while candidate.path != "/" {
            let scope = grants.scope(covering: candidate)
            let problem = withExtendedLifetime(scope) { FolderLister.check(candidate) }
            if problem?.needsAccess != false { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }

    /// The tab's first listing: the restored selection and notice, if it was restored.
    func listFirstTime() {
        go(selecting: restoredSelection)
        restoredSelection = nil
        if let restoredNotice {
            notice = restoredNotice
            self.restoredNotice = nil
            updateStatus()
        }
    }
}
