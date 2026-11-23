import AppKit
import TwinPanesCore
import WorkspaceKit

extension ItemKind {
    public static let browser: ItemKind = "browser"
}

/// Action selectors of the browser, so menus and the command catalog can name them.
@objc public protocol BrowserActions {
    /// Enter, double-click, ⌘↓: into a folder, or open a file in the editor.
    @objc optional func browserOpen(_ sender: Any?)
    /// F3 and F4: open the file under the cursor in the editor (quick view is M7).
    @objc optional func browserView(_ sender: Any?)
    @objc optional func browserEdit(_ sender: Any?)
    /// ⌘↑, Backspace: the parent folder.
    @objc optional func browserParent(_ sender: Any?)
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
    public var onChange: (() -> Void)?

    public let grants: FolderGrants
    /// Opens a file in an editor tab; supplied by the app so BrowserKit doesn't
    /// import EditorKit (§4). The scope covers the file's folder, if one was needed.
    public let openFile: (URL, SecurityScope?) -> Void

    public private(set) var folder: URL
    /// The folder's entries, sorted and filtered (D-c).
    public private(set) var listing = FolderListing()
    /// The rows shown, without "..".
    public var entries: [DirectoryEntry] { listing.rows }
    /// True while the current folder's listing is still arriving.
    public private(set) var isListing = false
    /// Bumped by every navigation: work started for an older one is dropped.
    private var generation = 0
    private(set) var lister: FolderLister?
    /// Batches waiting for the merge that's running off the main actor.
    private var pendingBatch: [DirectoryEntry] = []
    private var isMerging = false
    private var listedWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set when the sandbox refuses the folder until the user grants access.
    public private(set) var needsAccess = false
    /// False until the first listing; the view lists the folder when it first loads.
    public private(set) var hasListed = false
    /// Access to the current folder, held for as long as this tab shows it (§5).
    private(set) var scope: SecurityScope?
    lazy var controller = BrowserViewController(item: self)

    public init(
        folder: URL, grants: FolderGrants, openFile: @escaping (URL, SecurityScope?) -> Void
    ) {
        self.folder = folder.standardizedFileURL
        self.grants = grants
        self.openFile = openFile
    }

    public var title: String {
        folder.path == "/" ? "/" : FileManager.default.displayName(atPath: folder.path)
    }
    public var icon: NSImage? { NSWorkspace.shared.icon(forFile: folder.path) }
    public var viewController: NSViewController { controller }
    public var preferredFirstResponder: NSView? { controller.tableView }

    /// Lists `url` (default: the current folder again). On success the tab moves
    /// there and the rows arrive in batches; if access is needed the tab moves there and
    /// shows the access prompt. Returns false (and stays put) for missing or non-folder
    /// paths: those are checked at once, before anything is listed.
    @discardableResult
    public func go(to url: URL? = nil, selecting name: String? = nil) -> Bool {
        let target = (url ?? folder).standardizedFileURL
        let newScope = grants.scope(covering: target)
        let problem = FolderLister.check(target)
        if let problem, !problem.needsAccess {
            host?.showStatus("Can’t open “\(target.path)”: \(problem)")
            NSSound.beep()
            return false
        }
        stopListing()
        needsAccess = problem != nil
        listing = FolderListing(order: listing.order, showsHidden: listing.showsHidden)
        folder = target
        scope = newScope
        hasListed = true
        controller.startShowing(selecting: name)
        onChange?()
        if !needsAccess { startListing() }
        updateStatus()
        if !isListing { finishWaiting() }
        return true
    }

    private func startListing() {
        let lister = FolderLister(folder: folder)
        let wanted = generation
        self.lister = lister
        isListing = true
        lister.start { [weak self] event in
            guard let self, self.generation == wanted else { return }
            self.received(event)
        }
    }

    private func stopListing() {
        lister?.cancel()
        lister = nil
        generation += 1
        pendingBatch = []
        isMerging = false
        isListing = false
    }

    private func received(_ event: FolderLister.Event) {
        switch event {
        case .batch(let batch):
            pendingBatch += batch
            mergePending()
        case .done:
            isListing = false
            if !isMerging { listingFinished() }
        case .failed(let error):
            isListing = false
            needsAccess = error.needsAccess
            host?.showStatus("Can’t list “\(folder.path)”: \(error)")
            listingFinished()
        }
    }

    /// Merges the waiting batches: here when the folder is small, else off the main
    /// actor, one merge at a time; a result for an older navigation is dropped.
    private func mergePending() {
        guard !isMerging, !pendingBatch.isEmpty else { return }
        let batch = pendingBatch
        pendingBatch = []
        let base = listing
        if base.entries.count + batch.count <= FolderListing.mainActorLimit {
            return show(base.merging(batch))
        }
        isMerging = true
        let wanted = generation
        Task.detached(priority: .userInitiated) {
            let merged = base.merging(batch)
            await MainActor.run { [weak self] in
                guard let self, self.generation == wanted else { return }
                self.isMerging = false
                self.show(merged)
            }
        }
    }

    private func show(_ merged: FolderListing) {
        listing = merged
        controller.reloadKeepingSelection()
        if !pendingBatch.isEmpty {
            mergePending()
        } else if !isListing {
            listingFinished()
        } else {
            updateStatus()
        }
    }

    private func listingFinished() {
        lister = nil
        controller.reloadKeepingSelection()
        updateStatus()
        finishWaiting()
    }

    /// Returns once the current folder has been listed completely.
    public func listed() async {
        guard isListing || isMerging else { return }
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

    public func goToParent() {
        let parent = folder.deletingLastPathComponent()
        guard parent.path != folder.path else { return NSSound.beep() }
        go(to: parent, selecting: folder.lastPathComponent)
    }

    /// Records a folder the user granted in an open panel and lists it.
    public func granted(_ url: URL) {
        try? grants.add(url)
        go(to: url == folder ? nil : url)
    }

    func updateStatus() {
        if needsAccess {
            host?.showStatus("\(folder.path) · no access yet")
        } else if isListing {
            host?.showStatus("\(folder.path) · Listing… \(listing.entries.count.formatted()) items")
        } else {
            let folders = entries.filter(\.isDirectory).count
            host?.showStatus(
                "\(folder.path) · \(entries.count) items (\(folders) folders)")
        }
    }
}
