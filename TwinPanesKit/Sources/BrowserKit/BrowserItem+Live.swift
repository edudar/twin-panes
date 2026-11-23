import AppKit
import TwinPanesCore

/// A tab, weakly, for work off the main actor to hand its result back to.
final class WeakItem: Sendable {
    @MainActor weak var item: BrowserItem?
    @MainActor init(_ item: BrowserItem) { self.item = item }
}

/// Live updates (docs/plans/M4.md, D-f): the shown folder is watched with FSEvents, and
/// what changed is read again off the main actor and merged into the rows through the
/// same pipeline as the listing, so the order and the selection hold.
extension BrowserItem {
    func startWatching() {
        let wanted = generation
        let watcher = FolderWatcher(folder: folder) { [weak self] change in
            guard let self, self.generation == wanted else { return }
            self.folderChanged(change)
        }
        watcher.start()
        self.watcher = watcher
    }

    func folderChanged(_ change: FolderWatcher.Change) {
        switch change {
        case .names(let names):
            // The lister may still deliver these: read them once it's done instead.
            if isListing { changedWhileListing.formUnion(names) } else { read(names) }
        case .relist:
            relist()
        case .folderGone:
            leaveVanishedFolder()
        }
    }

    func readChangedWhileListing() {
        guard !changedWhileListing.isEmpty else { return }
        let names = changedWhileListing
        changedWhileListing = []
        read(names)
    }

    /// Reads `names` again: present ones replace their old versions, missing ones go.
    func read(_ names: Set<String>) {
        let wanted = generation
        let folder = self.folder
        readsInFlight += 1
        // Only a weak box crosses: even `self?` held over the hop would keep a closed
        // tab alive until the main actor ran it.
        let box = WeakItem(self)
        Task.detached(priority: .userInitiated) {
            let entries = names.compactMap {
                DirectoryReader.entryIfPresent(folder.appendingPathComponent($0))
            }
            await MainActor.run { box.item?.readFinished(names, entries, generation: wanted) }
        }
    }

    private func readFinished(
        _ names: Set<String>, _ entries: [DirectoryEntry], generation wanted: Int
    ) {
        guard generation == wanted else { return }
        apply(removing: names, adding: entries)
    }

    /// FSEvents lost track: list the whole folder again in the background and swap it
    /// in as one update, so the rows never empty out and the selection holds. FSEvents
    /// says so to every stream when heavy activity anywhere overflows it, so re-lists
    /// run one at a time, and requests meanwhile become a single one after a pause.
    func relist() {
        guard !isRelisting else {
            relistRequested = true
            return
        }
        isRelisting = true
        relistsStarted += 1
        let wanted = generation
        let lister = FolderLister(folder: folder)
        var all: [DirectoryEntry] = []
        readsInFlight += 1
        lister.start { [weak self] event in
            guard let self, self.generation == wanted else { return }
            switch event {
            case .batch(let batch):
                all += batch
                return
            case .done: self.apply(removing: Set(self.listing.entries.map(\.name)), adding: all)
            case .failed: self.apply(removing: [], adding: [])
            }
            self.relistFinished(generation: wanted)
        }
    }

    static let relistPause: Duration = .seconds(1)

    private func relistFinished(generation wanted: Int) {
        isRelisting = false
        guard relistRequested else { return }
        relistRequested = false
        isRelisting = true  // until the pause is over, more requests wait too
        readsInFlight += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.relistPause)
            guard let self, self.generation == wanted else { return }
            self.readsInFlight -= 1
            self.isRelisting = false
            self.relist()
        }
    }

    private func apply(removing names: Set<String>, adding entries: [DirectoryEntry]) {
        readsInFlight -= 1
        pendingRemovals.formUnion(names)
        pendingBatch += entries
        if names.isEmpty && entries.isEmpty { return listingFinished() }
        applyPending()
    }

    /// The folder was deleted, moved or unmounted: go to the nearest folder above it
    /// that's still there, and say why.
    func leaveVanishedFolder() {
        let gone = folder
        var up = gone.deletingLastPathComponent()
        while up.path != "/", let problem = FolderLister.check(up), !problem.needsAccess {
            up = up.deletingLastPathComponent()
        }
        navigate(to: up, selecting: nil, recording: false, quietly: true)
        notice = "“\(gone.lastPathComponent)” is no longer there · showing \(up.path)"
        updateStatus()
    }
}
