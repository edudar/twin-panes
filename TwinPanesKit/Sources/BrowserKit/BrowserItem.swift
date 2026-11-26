import AppKit
import Synchronization
import TwinPanesCore
import WorkspaceKit

extension ItemKind {
    public static let browser: ItemKind = "browser"
}

/// Action selectors of the browser, so menus and the command catalog can name them.
@objc public protocol BrowserActions {
    /// Enter, double-click, ⌘↓: into a folder, or open a file in the editor.
    @objc optional func browserOpen(_ sender: Any?)
    /// ⌘↩ in the path field: open the typed file in the hex editor (Return opens it in
    /// its default app).
    @objc optional func browserOpenInEditor(_ sender: Any?)
    /// F3 and F4: open the file under the cursor in the editor (quick view is M7).
    @objc optional func browserView(_ sender: Any?)
    @objc optional func browserEdit(_ sender: Any?)
    /// ⌘↑, Backspace: the parent folder.
    @objc optional func browserParent(_ sender: Any?)
    /// ⌥⌘↓: enter the selected package (`.app`, `.bundle`) as a folder (D-i).
    @objc optional func browserShowPackageContents(_ sender: Any?)
    /// ⌘[ and ⌘]: the tab's previous and next folder.
    @objc optional func browserBack(_ sender: Any?)
    @objc optional func browserForward(_ sender: Any?)
    /// ⇧⌘.: show or hide hidden files in this tab.
    @objc optional func browserToggleHidden(_ sender: Any?)
    /// ⇧⌘G: focus the path field.
    @objc optional func browserGoToFolder(_ sender: Any?)
    /// Ask for sandbox access to the current folder.
    @objc optional func browserGrantAccess(_ sender: Any?)
}

/// A browser tab over one folder at a time (M1b, PLAN.md §4.7). Folders are listed off
/// the main actor and arrive in batches (docs/plans/M4.md, D-a).
@MainActor
public final class BrowserItem: WorkspaceItem {
    public let id = ItemID()
    public let kind: ItemKind = .browser
    public let preferredSlot: SlotID = .leftPanel
    public weak var host: WorkspaceHost?
    /// Runs the file commands (F2 to ⇧F8, undo); the app supplies it.
    public weak var fileCommands: FileCommandHandling?
    public var onChange: (() -> Void)?

    public let grants: FolderGrants
    /// Opens a file in an editor tab; supplied by the app so BrowserKit doesn't
    /// import EditorKit (§4). The scope covers the file's folder, if one was needed.
    public let openFile: (URL, SecurityScope?) -> Void
    /// Opens a file in the app Finder would open it with, saying in the status line when
    /// it can't; the smoke test stands in for it so it launches no other app.
    public lazy var openInDefaultApp: (URL) -> Void = { [weak self] url in
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) {
            [weak self] _, error in
            guard let error else { return }
            let message = "Can’t open “\(url.lastPathComponent)”: \(error.localizedDescription)"
            Task { @MainActor [weak self] in self?.host?.showStatus(message) }
        }
    }

    public private(set) var folder: URL
    /// The folder's entries, sorted and filtered (D-c).
    public private(set) var listing = FolderListing()
    /// The rows shown, without "..".
    public var entries: [DirectoryEntry] { listing.rows }
    /// True while the current folder's listing is still arriving.
    public private(set) var isListing = false
    /// Bumped by every navigation: work started for an older one is dropped.
    private(set) var generation = 0
    private(set) var lister: FolderLister? {
        didSet { activeTasks.setLister(lister) }
    }
    var relistLister: FolderLister? {
        didSet { activeTasks.setRelistLister(relistLister) }
    }
    var readSequence = 0
    var latestReadSequence: [String: Int] = [:]
    /// Batches waiting for the merge that's running off the main actor.
    var pendingBatch: [DirectoryEntry] = []
    /// A new order waiting for the same; applied before the waiting batches.
    private var pendingOrder: ListingOrder?
    private var pendingHidden: Bool?
    /// Names a live update removes before merging their new versions (D-f).
    var pendingRemovals: Set<String> = []
    /// Whether `pendingBatch` holds entries from the lister, not only entries read again
    /// for a live update: such a run is never applied row by row.
    var pendingHasListed = false
    /// A full re-list's entries, replacing all of them.
    var pendingReplacement: [DirectoryEntry]?
    /// Names that changed while the folder was still listing, read once it's done.
    var changedWhileListing: Set<String> = []
    var watcher: FolderWatcher? {
        didSet { activeTasks.setWatcher(watcher) }
    }
    private let activeTasks = ActiveTasks()
    /// Called after each live update reaches the rows; for tests.
    var didUpdate: (() -> Void)?
    /// Live-update reads (and a full re-list) still running off the main actor.
    var readsInFlight = 0
    var isReadingChanges: Bool { readsInFlight > 0 }
    /// One full re-list at a time; requests meanwhile become one more, a little later.
    var isRelisting = false
    var relistRequested = false
    /// Re-lists started, for tests.
    var relistsStarted = 0
    /// Why the tab moved on its own, shown until the next navigation.
    var notice: String?
    /// A restored tab's selection and notice, for its first listing.
    var restoredSelection: String?
    var restoredNotice: String?
    private var hasPending: Bool {
        !pendingBatch.isEmpty || pendingOrder != nil || pendingHidden != nil
            || !pendingRemovals.isEmpty || pendingReplacement != nil
    }
    var isMerging = false
    private var listedWaiters: [CheckedContinuation<Void, Never>] = []
    /// Folders to go back and forward to, most recent last (D-d).
    static let maxHistory = 100
    var backStack: [HistoryEntry] = []
    var forwardStack: [HistoryEntry] = []
    /// Set when the sandbox refuses the folder until the user grants access.
    public internal(set) var needsAccess = false
    /// False until the first listing; the view lists the folder when it first loads.
    public private(set) var hasListed = false
    /// Access to the current folder, held for as long as this tab shows it (§5).
    private(set) var scope: SecurityScope?
    private var loadedController: BrowserViewController?
    var controller: BrowserViewController {
        if let loadedController { return loadedController }
        let controller = BrowserViewController(item: self)
        loadedController = controller
        return controller
    }

    public init(
        folder: URL, grants: FolderGrants, openFile: @escaping (URL, SecurityScope?) -> Void
    ) {
        self.folder = folder.standardizedFileURL
        self.grants = grants
        self.openFile = openFile
    }

    deinit {
        activeTasks.cancelAll()
    }

    public var title: String {
        folder.path == "/" ? "/" : FileManager.default.displayName(atPath: folder.path)
    }
    /// The generic folder icon, cached: asking for this folder's own one on every change
    /// cost tens of milliseconds per navigation.
    public var icon: NSImage? { IconCache.shared.folder }
    public var viewController: NSViewController { controller }
    public var preferredFirstResponder: NSView? { controller.tableView }
    /// Whether the rows on screen show the icons for the tab's scale and appearance.
    public var shownIconsAreCurrent: Bool { controller.shownIconsAreCurrent }

    /// Lists `url` (default: the current folder again). On success the tab moves
    /// there and the rows arrive in batches; if access is needed the tab moves there and
    /// shows the access prompt. Returns false (and stays put) for missing or non-folder
    /// paths: those are checked at once, before anything is listed.
    /// Going to another folder is recorded in the tab's history.
    @discardableResult
    public func go(to url: URL? = nil, selecting name: String? = nil) -> Bool {
        navigate(to: url, selecting: name, recording: true, quietly: false)
    }

    @discardableResult
    func navigate(to url: URL?, selecting name: String?, recording: Bool, quietly: Bool) -> Bool {
        let step = StepTiming.start("navigate")
        defer { step?.end() }
        let target = (url ?? folder).standardizedFileURL
        // Still under the same grant: keep the token rather than start access again.
        let newScope: SecurityScope?
        if let scope,
            let grant = grants.grant(covering: target),
            grant.standardizedFileURL == scope.url.standardizedFileURL
        {
            newScope = scope
        } else {
            newScope = grants.scope(covering: target)
        }
        let problem = withExtendedLifetime(newScope) {
            FolderLister.check(target)
        }
        if let problem, !problem.needsAccess {
            if !quietly {
                host?.showStatus("Can’t open “\(target.path)”: \(problem)")
                NSSound.beep()
            }
            return false
        }
        if recording, hasListed, target.path != folder.path {
            pushHistory(here, onto: \.backStack)
            forwardStack = []
        }
        let order = self.order
        stopListing()
        needsAccess = problem != nil
        replaceListing(with: FolderListing(order: order, showsHidden: showsHidden))
        folder = target
        scope = newScope
        hasListed = true
        controller.startShowing(selecting: name)
        onChange?()
        if !needsAccess {
            startListing()
            startWatching()
        }
        updateStatus()
        if !isListing { finishWaiting() }
        return true
    }

    private func startListing() {
        let lister = FolderLister(folder: folder)
        let wanted = generation
        let activeScope = self.scope
        self.lister = lister
        isListing = true
        lister.start { [weak self] event in
            withExtendedLifetime(activeScope) {
                guard let self, self.generation == wanted else { return }
                self.received(event)
            }
        }
    }

    func stopListing() {
        activeTasks.cancelAll()
        lister = nil
        relistLister = nil
        watcher = nil
        generation += 1
        readSequence = 0
        latestReadSequence = [:]
        pendingBatch = []
        pendingRemovals = []
        pendingReplacement = nil
        pendingHasListed = false
        changedWhileListing = []
        readsInFlight = 0
        isRelisting = false
        relistRequested = false
        notice = nil
        pendingOrder = nil
        pendingHidden = nil
        isMerging = false
        isListing = false
        finishWaiting()
    }

    /// The order the rows are in, or are being sorted into; it outlives navigation. Set
    /// directly only before the first listing (restoring); `sort(by:)` otherwise.
    public internal(set) var order = ListingOrder()

    /// Whether hidden files show in this tab (D-e); it outlives navigation. Set directly
    /// only before the first listing (restoring); `showHidden(_:)` otherwise.
    public internal(set) var showsHidden = false

    /// Shows or hides hidden files. The listing always holds them, so this only
    /// filters: nothing is listed again.
    public func showHidden(_ shows: Bool) {
        guard shows != showsHidden else { return }
        showsHidden = shows
        pendingHidden = shows
        applyPending()
        controller.viewIfLoaded?.window?.invalidateRestorableState()
    }

    /// Sorts the rows (D-c): here for a small folder, off the main actor for a big one,
    /// keeping the selected entry selected. Batches still arriving merge in the new order.
    public func sort(by order: ListingOrder) {
        guard order != self.order else { return }
        self.order = order
        pendingOrder = order
        applyPending()
        controller.viewIfLoaded?.window?.invalidateRestorableState()
    }

    func received(_ event: FolderLister.Event) {
        let step = StepTiming.start("batch")
        defer { step?.end() }
        switch event {
        case .batch(let batch):
            pendingBatch += batch
            pendingHasListed = true
            applyPending()
        case .done:
            isListing = false
            if !isMerging { listingFinished(reloading: false) }  // the last batch is shown
        case .failed(let error):
            isListing = false
            pendingBatch = []
            pendingRemovals = []
            pendingReplacement = nil
            pendingHasListed = false
            isMerging = false
            needsAccess = error.needsAccess
            notice = "Can’t list “\(folder.path)”: \(error)"
            listingFinished()
        }
    }

    /// Applies the waiting order and batches: here when the folder is small, else off
    /// the main actor, one run at a time; a result for an older navigation is dropped.
    func applyPending() {
        guard !isMerging, hasPending else { return }
        let batch = pendingBatch
        let order = pendingOrder
        let hidden = pendingHidden
        let removals = pendingRemovals
        let listed = pendingHasListed
        pendingHasListed = false
        pendingBatch = []
        pendingRemovals = []
        pendingOrder = nil
        pendingHidden = nil
        let replacement = pendingReplacement
        pendingReplacement = nil
        let base = listing
        let keep = controller.namesToKeep
        let selection = controller.selection
        // Everything that walks the rows happens here, off the main actor when big.
        let work: @Sendable () -> Applied = {
            var result =
                replacement.map {
                    FolderListing(order: base.order, showsHidden: base.showsHidden).merging($0)
                } ?? base
            if let order { result = result.sorted(by: order) }
            if let hidden { result = result.showingHidden(hidden) }
            result = result.removing(names: removals)
            if !batch.isEmpty { result = result.merging(Self.latest(batch, of: removals)) }
            let live =
                order == nil && hidden == nil && replacement == nil && !listed
                && !removals.isEmpty
            return Applied(
                listing: result,
                changes: live ? result.rowChanges(from: base, touching: removals, limit: 100) : nil,
                asked: keep, found: result.rows(named: keep),
                selectedRows: selection.rows(in: result))
        }
        let size = base.entries.count + batch.count + (replacement?.count ?? 0)
        if size <= FolderListing.mainActorLimit {
            return show(work(), resorted: order != nil)
        }
        isMerging = true
        let wanted = generation
        let box = WeakItem(self)  // a strong capture would keep a closed tab alive
        Task.detached(priority: .userInitiated) {
            let applied = work()
            await MainActor.run {
                guard let self = box.item, self.generation == wanted else { return }
                self.isMerging = false
                self.show(applied, resorted: order != nil)
            }
        }
    }

    /// `batch` with only the last copy of each entry read again: a live update can share
    /// a run with the lister's last batches, and the entry it read again is the newer one.
    nonisolated static func latest(
        _ batch: [DirectoryEntry], of names: Set<String>
    ) -> [DirectoryEntry] {
        guard !names.isEmpty else { return batch }
        var seen = Set<String>()
        let kept = batch.reversed().filter {
            !names.contains($0.name) || seen.insert($0.name).inserted
        }
        return kept.reversed()
    }

    /// One run of the pipeline, with what the table needs worked out alongside.
    struct Applied: Sendable {
        let listing: FolderListing
        /// A small live update's row changes, to apply row by row.
        let changes: RowChanges?
        /// The names the selection needs back, and the rows found for them.
        let asked: Set<String>
        let found: [String: Int]
        /// Where the selected entries are in `listing`.
        let selectedRows: IndexSet
    }

    private func show(_ applied: Applied, resorted: Bool) {
        let step = StepTiming.start("show")
        defer { step?.end() }
        replaceListing(with: applied.listing)
        if resorted
            || !(applied.changes.map {
                controller.applyRowChanges(
                    $0, asked: applied.asked, found: applied.found,
                    selectedRows: applied.selectedRows)
            } ?? false)
        {
            controller.reloadKeepingSelection(
                scrolling: resorted, asked: applied.asked, found: applied.found,
                selectedRows: applied.selectedRows)
        }
        if hasPending {
            applyPending()
        } else if !isListing {
            listingFinished(reloading: false)  // the rows were just shown
        } else {
            updateStatus()
        }
    }

    /// Swaps in `new`; the old listing is freed off the main actor, since freeing 100k
    /// entries there takes tens of milliseconds.
    func replaceListing(with new: FolderListing) {
        let old = Garbage(listing)
        listing = new
        DispatchQueue.global(qos: .utility).async { old.empty() }
    }

    func listingFinished(reloading: Bool = true) {
        lister = nil
        if reloading {
            controller.reloadKeepingSelection(selectedRows: controller.selection.rows)
        }
        updateStatus()
        readChangedWhileListing()
        if !isReadingChanges { finishWaiting() }
        didUpdate?()
    }

    /// Returns once the current folder has been listed completely.
    public func listed() async {
        guard isListing || isMerging || isReadingChanges else { return }
        await withCheckedContinuation { listedWaiters.append($0) }
    }

    private func finishWaiting() {
        let waiters = listedWaiters
        listedWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Opens a folder entry, or hands a file to the editor.
    public func open(_ entry: DirectoryEntry) {
        if entry.isDirectory {
            go(to: entry.url)
        } else {
            openFile(entry.url, grants.scope(covering: entry.url))
        }
    }

    /// Whether `url` is a file rather than a folder (packages are folders here, as the
    /// path field goes into them); false when it can't be read.
    func isFile(_ url: URL) -> Bool {
        withExtendedLifetime(grants.scope(covering: url)) {
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
                && !isFolder.boolValue
        }
    }

    /// Goes to `file`'s folder with the file selected; false when the folder can't be
    /// shown (the status line says why).
    func reveal(_ file: URL) -> Bool {
        go(to: file.deletingLastPathComponent(), selecting: file.lastPathComponent)
    }

    public func goToParent() {
        let parent = folder.deletingLastPathComponent()
        guard parent.path != folder.path else { return NSSound.beep() }
        go(to: parent, selecting: folder.lastPathComponent)
    }

    /// Records a folder the user granted in an open panel and lists it.
    public func granted(_ url: URL) {
        try? grants.add(url)
        go(to: Self.url(url, covers: folder) ? nil : url)
    }

    private static func url(_ parent: URL, covers child: URL) -> Bool {
        let parentParts = parent.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let childParts = child.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return childParts.starts(with: parentParts)
    }

    public func willClose() { stopListing() }

    func updateStatus() {
        let step = StepTiming.start("status")
        defer { step?.end() }
        if let notice {
            host?.showStatus(notice)
        } else if needsAccess {
            host?.showStatus("\(folder.path) · no access yet")
        } else if isListing {
            host?.showStatus("\(folder.path) · Listing… \(listing.entries.count.formatted()) items")
        } else if loadedController?.updateSelectionStatus() == true {
            return
        } else {
            let folders = listing.folderCount
            let hidden = listing.hiddenCount
            host?.showStatus(
                "\(folder.path) · \(entries.count.formatted()) items (\(folders.formatted()) folders)"
                    + (hidden > 0 ? ", \(hidden.formatted()) hidden" : ""))
        }
    }
}

/// Holds active background tasks so `BrowserItem.deinit` can cancel them without `isolated deinit`.
private final class ActiveTasks: Sendable {
    struct State: Sendable {
        var lister: FolderLister?
        var relistLister: FolderLister?
        var watcher: FolderWatcher?
    }

    private let state = Mutex(State())

    func setLister(_ lister: FolderLister?) {
        state.withLock { $0.lister = lister }
    }

    func setRelistLister(_ lister: FolderLister?) {
        state.withLock { $0.relistLister = lister }
    }

    func setWatcher(_ watcher: FolderWatcher?) {
        state.withLock { $0.watcher = watcher }
    }

    func cancelAll() {
        let current = state.withLock { state in
            let copy = state
            state = State()
            return copy
        }
        current.lister?.cancel()
        current.relistLister?.cancel()
        current.watcher?.stop()
    }
}
