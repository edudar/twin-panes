import AppKit
import Synchronization
import TwinPanesCore
import WorkspaceKit

extension ItemKind {
    public static let quickView: ItemKind = "quickView"
}

/// Read-only Quick View tab (`docs/plans/M7.md`, D-e): displays a file via Quick Look or
/// a lazy read-only hex viewer without ever creating an `EditorSession`.
@MainActor
public final class QuickViewItem: WorkspaceItem {
    private final class ObservationToken {}

    public let id = ItemID()
    public let kind: ItemKind = .quickView
    public let preferredSlot: SlotID = .rightPanel
    public weak var host: WorkspaceHost?
    public var onChange: (() -> Void)?

    public var isDirty: Bool { false }
    public var restorableState: ItemState? { nil }
    public var title: String { currentURL?.lastPathComponent ?? "Quick View" }
    public var icon: NSImage? {
        NSImage(systemSymbolName: "eye", accessibilityDescription: "Quick View")
    }
    public var viewController: NSViewController { controller }
    public var preferredFirstResponder: NSView? { controller.preferredResponder }

    public private(set) var isPinned: Bool
    public private(set) var isFollowing: Bool
    public private(set) var currentURL: URL?
    public private(set) var activeMode: PreviewMode = .quickLook
    public private(set) var isDataless = false

    private(set) var currentEntry: DirectoryEntry?
    private(set) var currentScope: SecurityScope?
    var showsUnsavedEdits: Bool {
        (observedSession?.isDirty ?? false)
            || (activeMode == .hex && (loadedController?.hexShowsUnsavedEdits ?? false))
    }

    let viewerFactory: any HexViewerFactory
    let makeQuickLook: () -> QuickLookHostView
    let onEdit: (URL, SecurityScope?) -> Void

    private weak var sessions: SessionRegistry?
    private weak var observedSession: EditorSession?
    private var sessionToken: ObservationToken?
    private let debounce: Duration
    private let cloudDownloads: any CloudDownloads
    private let pendingTask = Mutex<Task<Void, Never>?>(nil)
    private var retargetGeneration: UInt64 = 0
    private var userOverrideMode: PreviewMode?
    private var isClosed = false
    private var loadedController: QuickViewViewController?

    var controller: QuickViewViewController {
        if let loadedController { return loadedController }
        let controller = QuickViewViewController(item: self)
        loadedController = controller
        return controller
    }

    public convenience init(
        viewerFactory: any HexViewerFactory, sessions: SessionRegistry? = nil,
        isFollowing: Bool = true, debounce: Duration = .milliseconds(40),
        onEdit: @escaping (URL, SecurityScope?) -> Void
    ) {
        self.init(
            viewerFactory: viewerFactory, sessions: sessions, isFollowing: isFollowing,
            debounce: debounce, onEdit: onEdit,
            makeQuickLook: { QuickLookHostView(style: .normal) })
    }

    init(
        viewerFactory: any HexViewerFactory, sessions: SessionRegistry? = nil,
        isFollowing: Bool = true, debounce: Duration = .milliseconds(40),
        cloudDownloads: any CloudDownloads = RealCloudDownloads(),
        onEdit: @escaping (URL, SecurityScope?) -> Void,
        makeQuickLook: @escaping () -> QuickLookHostView
    ) {
        self.viewerFactory = viewerFactory
        self.sessions = sessions
        self.isFollowing = isFollowing
        self.isPinned = !isFollowing
        self.debounce = debounce
        self.cloudDownloads = cloudDownloads
        self.onEdit = onEdit
        self.makeQuickLook = makeQuickLook
        sessions?.observe(self) { [weak self] session in self?.sessionRegistered(session) }
    }

    deinit {
        pendingTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    /// Updates the displayed entry when following (`!isPinned`); ignored once pinned.
    public func retarget(to entry: DirectoryEntry?, scope: SecurityScope?) {
        guard !isClosed, !isPinned else { return }
        cancelPendingRetarget()
        retargetGeneration &+= 1
        if debounce <= .zero {
            applyTarget(entry, scope: scope)
            return
        }
        let expected = retargetGeneration
        let delay = debounce
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isClosed, !self.isPinned,
                self.retargetGeneration == expected
            else { return }
            self.applyTarget(entry, scope: scope)
        }
        pendingTask.withLock { $0 = task }
    }

    /// Immediately displays `entry` regardless of `isPinned` (initial display or explicit F3).
    public func show(_ entry: DirectoryEntry?, scope: SecurityScope?) {
        guard !isClosed else { return }
        cancelPendingRetarget()
        retargetGeneration &+= 1
        applyTarget(entry, scope: scope)
    }

    /// Pins this tab so subsequent `retarget(to:scope:)` calls are ignored.
    public func pin() {
        guard !isPinned else { return }
        isPinned = true
        cancelPendingRetarget()
        loadedController?.syncPinButton()
    }

    /// Permanently detaches a following tab from its source browser, hiding the Keep button
    /// so it behaves like a standalone tab.
    public func detachFromSource() {
        guard isFollowing else { return }
        isFollowing = false
        isPinned = true
        cancelPendingRetarget()
        retargetGeneration &+= 1
        loadedController?.syncPinButton()
    }

    func togglePin() {
        guard isFollowing else { return }
        if isPinned {
            isPinned = false
            loadedController?.syncPinButton()
        } else {
            pin()
        }
    }

    func selectMode(_ mode: PreviewMode) {
        guard !isClosed, let entry = currentEntry,
            !entry.isDirectory, !entry.isPackage, !entry.isBrokenSymbolicLink
        else { return }
        userOverrideMode = mode
        guard activeMode != mode else { return }
        activeMode = mode
        loadedController?.syncView()
        updateStatus()
    }

    func hexStateChanged() {
        guard !isClosed else { return }
        loadedController?.syncHeader()
        updateStatus()
    }

    /// Cancels pending debounced updates, closes Quick Look, clears hex, and drops scopes.
    public func willClose() {
        guard !isClosed else { return }
        isClosed = true
        cancelPendingRetarget()
        detachSession()
        currentEntry = nil
        currentURL = nil
        currentScope = nil
        isDataless = false
        loadedController?.tearDown()
    }

    private func applyTarget(_ entry: DirectoryEntry?, scope: SecurityScope?) {
        let oldTitle = title
        let url = entry?.url.standardizedFileURL
        if url != currentURL { userOverrideMode = nil }
        currentEntry = entry
        currentURL = url

        guard let entry, let url, !entry.isDirectory, !entry.isPackage, !entry.isBrokenSymbolicLink
        else {
            detachSession()
            currentScope = nil
            isDataless = false
            activeMode = .quickLook
            finishTargetUpdate(oldTitle: oldTitle)
            return
        }

        currentScope = scope
        attachSession(sessions?.session(for: url))
        refreshModeFromClassifier(for: entry, url: url)
        finishTargetUpdate(oldTitle: oldTitle)
    }

    private func finishTargetUpdate(oldTitle: String) {
        loadedController?.syncView()
        updateStatus()
        if title != oldTitle { onChange?() }
    }

    private func refreshModeFromClassifier(for entry: DirectoryEntry, url: URL) {
        isDataless = cloudDownloads.isDataless(url)
        if let override = userOverrideMode {
            activeMode = override
            return
        }
        activeMode = PreviewClassifier.defaultMode(
            for: entry.type,
            isDirectory: false,
            isPackage: false,
            isDataless: isDataless,
            hasDirtySession: observedSession?.isDirty ?? false
        )
    }

    private func attachSession(_ session: EditorSession?) {
        if observedSession === session { return }
        detachSession()
        guard let session else { return }
        let token = ObservationToken()
        observedSession = session
        sessionToken = token
        session.observe(token) { [weak self, weak token] change in
            guard let self, token != nil, !self.isClosed else { return }
            self.sessionChanged(change)
        }
    }

    private func detachSession() {
        observedSession = nil
        sessionToken = nil
    }

    private func sessionRegistered(_ session: EditorSession) {
        guard !isClosed, let currentURL, Self.sameFile(session.url, currentURL) else { return }
        attachSession(session)
        if session.isDirty {
            sessionChanged(.edited)
        } else {
            loadedController?.syncHeader()
            updateStatus()
        }
    }

    private func sessionChanged(_ change: EditorSession.Change) {
        guard let entry = currentEntry, let url = currentURL,
            !entry.isDirectory, !entry.isPackage, !entry.isBrokenSymbolicLink
        else { return }
        if change == .closed { detachSession() }
        let previousMode = activeMode
        refreshModeFromClassifier(for: entry, url: url)
        if activeMode != previousMode || change == .closed {
            loadedController?.syncView()
        } else {
            loadedController?.syncHeader()
        }
        updateStatus()
    }

    private func updateStatus() {
        guard let entry = currentEntry else {
            host?.showStatus("Quick View · No selection")
            return
        }
        var parts = [entry.name]
        if let size = entry.size {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if entry.isDirectory {
            parts.append("Folder")
        } else if entry.isPackage {
            parts.append("Package")
        } else if entry.isBrokenSymbolicLink {
            parts.append("Broken symbolic link")
        } else {
            parts.append(activeMode == .quickLook ? "Quick Look" : "Hex")
            if showsUnsavedEdits { parts.append("Includes unsaved edits") }
        }
        parts.append("Read-only")
        host?.showStatus(parts.joined(separator: " · "))
    }

    private func cancelPendingRetarget() {
        pendingTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.standardizedFileURL == rhs.standardizedFileURL { return true }
        guard let a = try? FileIdentity(url: lhs).key, let b = try? FileIdentity(url: rhs).key
        else { return false }
        return a == b
    }
}
