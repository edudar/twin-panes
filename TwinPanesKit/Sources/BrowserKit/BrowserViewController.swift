import AppKit
import TwinPanesCore
import WorkspaceKit

/// The browser tab's view: a path field, the file list, and an access prompt shown in
/// place of the list when the sandbox refuses the folder.
@MainActor
final class BrowserViewController: NSViewController, CommandScopeProviding, NSMenuItemValidation {
    weak var item: BrowserItem?
    let tableView = FileListTableView()
    let pathField = PathField()
    /// The clickable path above the list (D-h); the field replaces it while editing.
    let pathControl = NSPathControl()
    /// The folder each of the bar's items stands for.
    var pathURLs: [URL] = []
    /// The names path completion offers, kept while the path field is open (D-e).
    var completionNames: CompletionNames?
    /// The completion waiting for a folder's names; for tests.
    nonisolated(unsafe) var pendingCompletion: Task<Void, Never>?
    /// The last completion applied, whose matches AppKit's list offers.
    var lastCompletion: PathCompletion?
    /// Opens AppKit's completion list; tests stand in for it.
    var showCompletionList: (NSTextView) -> Void = { $0.complete(nil) }
    private let scrollView = NSScrollView()
    private let accessPrompt = NSStackView()
    private let accessLabel = NSTextField(wrappingLabelWithString: "")
    let grantButton = NSButton()
    nonisolated(unsafe) var iconObserver: NSObjectProtocol?

    init(item: BrowserItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }

    deinit {
        pendingCompletion?.cancel()
        if let iconObserver { NotificationCenter.default.removeObserver(iconObserver) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var commandScopes: [BindingScope] { [.item(.browser)] }

    override func loadView() {
        pathField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathField.lineBreakMode = .byTruncatingHead
        pathField.placeholderString = "Folder path"
        pathField.target = self
        pathField.action = #selector(pathEntered(_:))
        pathField.setAccessibilityIdentifier("browserPath")
        pathField.delegate = self
        configurePathBar()

        configureTable()
        if let item { showSortIndicator(item.order) }
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        accessLabel.alignment = .center
        let grant = grantButton
        grant.bezelStyle = .push
        grant.target = self
        grant.action = #selector(browserGrantAccess(_:))
        grant.keyEquivalent = "\r"
        grant.setAccessibilityIdentifier("grantAccess")
        accessPrompt.orientation = .vertical
        accessPrompt.spacing = 12
        accessPrompt.addArrangedSubview(accessLabel)
        accessPrompt.addArrangedSubview(grant)

        let root = NSView()
        for view in [pathControl, pathField, scrollView, accessPrompt] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            pathField.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            pathField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            pathField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            pathControl.centerYAnchor.constraint(equalTo: pathField.centerYAnchor),
            pathControl.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            pathControl.trailingAnchor.constraint(equalTo: pathField.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            accessPrompt.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            accessPrompt.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            accessPrompt.widthAnchor.constraint(
                lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let item else { return }
        if !item.hasListed {
            item.listFirstTime()
        } else {
            startShowing(selecting: nil)
            reloadKeepingSelection()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        item?.updateStatus()
    }

    /// The entry to select once it has been listed (the folder you came from), until the
    /// user moves the selection first.
    private(set) var wantedSelection: String?
    /// Set while the selection is changed here rather than by the user.
    private(set) var isRestoringSelection = false
    /// What's selected, recorded as it changes: by the time the table reloads, the
    /// item's rows may already be new, so its old row no longer names the entry.
    private(set) var selectedName: String?
    private var selectedParentRow = false

    /// A new folder: empties the list (it fills as batches arrive), selects the first
    /// row, and remembers `name` to select once it's listed.
    func startShowing(selecting name: String?) {
        let step = StepTiming.start("start showing")
        defer { step?.end() }
        guard isViewLoaded, let item else { return }
        pathField.stringValue = item.folder.path
        showPath(item.folder)
        updateAccessPrompt()
        wantedSelection = name
        tableView.reloadData()
        restoreSelection(nil, parentRow: true)
        tableView.scrollRowToVisible(0)
    }

    /// Shows the item's current rows, keeping the selected entry selected by name;
    /// after a re-sort, also in view. Batches don't scroll.
    func reloadKeepingSelection(
        scrolling: Bool = false, asked: Set<String> = [], found: [String: Int] = [:]
    ) {
        guard isViewLoaded, let item else { return }
        // The rows of the names asked about were found off the main actor; only a name
        // that wasn't asked about (the selection moved meanwhile) is searched for here.
        func row(named name: String) -> Int? {
            guard asked.contains(name) else { return self.row(named: name) }
            return found[name].map { $0 + (showsParentRow ? 1 : 0) }
        }
        showSortIndicator(item.order)
        updateAccessPrompt()
        let selected = selectedName
        let onParent = selectedParentRow
        refreshRows()
        if let wanted = wantedSelection, let row = row(named: wanted) {
            wantedSelection = nil
            restoreSelection(row, parentRow: false)
            tableView.scrollRowToVisible(row)
        } else {
            restoreSelection(selected.flatMap(row(named:)), parentRow: onParent)
            if scrolling, tableView.selectedRow >= 0 {
                tableView.scrollRowToVisible(tableView.selectedRow)
            }
        }
    }

    /// Shows the item's rows again. reloadData would build every visible row view anew
    /// (with its key-view loop): tens of milliseconds for each sort or listing batch of
    /// a big folder. The table only needs the new count, and the cells it already shows
    /// given their new rows (docs/plans/M4.md, performance pass, step 5).
    func refreshRows() {
        let step = StepTiming.start("refresh rows")
        defer { step?.end() }
        // Most of a big folder deleted is slower this way than a plain reload:
        // NSTableView then reworks its row data from scratch.
        guard tableView.numberOfRows - numberOfRows(in: tableView) <= 1_000 else {
            return tableView.reloadData()
        }
        tableView.noteNumberOfRowsChanged()
        var stale = IndexSet()
        tableView.enumerateAvailableRowViews { rowView, row in
            if showsParentRow, row == 0 { return }
            // Row views past the new end are the table's to remove.
            if row < tableView.numberOfRows, !refreshCells(in: rowView, row: row) {
                stale.insert(row)
            }
        }
        if !stale.isEmpty {
            tableView.reloadData(
                forRowIndexes: stale, columnIndexes: IndexSet(0..<tableView.numberOfColumns))
        }
        restripe()
    }

    /// The names whose rows a reload needs: the selected entry and the one to select.
    var namesToKeep: Set<String> { Set([selectedName, wantedSelection].compactMap { $0 }) }

    /// A small live update (D-f): removes, inserts and reloads just the rows that
    /// changed, so the scroll position, the selection and the other rows' views stay.
    /// The changes were worked out with the listing; false if there's no view to update.
    func applyRowChanges(
        _ changes: RowChanges, asked: Set<String> = [], found: [String: Int] = [:]
    ) -> Bool {
        let step = StepTiming.start("row changes")
        defer { step?.end() }
        guard isViewLoaded, let item, !item.needsAccess else { return false }
        let offset = showsParentRow ? 1 : 0
        // Changes worked out against other rows than the table shows would make
        // NSTableView throw: show everything again instead.
        guard tableView.numberOfRows == changes.oldCount + offset,
            item.listing.rows.count == changes.newCount,
            changes.oldCount - changes.removed.count + changes.inserted.count == changes.newCount
        else { return false }
        let removed = IndexSet(changes.removed.map { $0 + offset })
        let inserted = IndexSet(changes.inserted.map { $0 + offset })
        let changed = IndexSet(changes.changed.map { $0 + offset })
        let selected = tableView.selectedRow
        let priorName = selectedName
        tableView.beginUpdates()
        tableView.removeRows(at: removed, withAnimation: [])
        tableView.insertRows(at: inserted, withAnimation: [])
        tableView.endUpdates()
        tableView.reloadData(
            forRowIndexes: changed, columnIndexes: IndexSet(0..<tableView.numberOfColumns))
        restripe()
        if tableView.selectedRow < 0, selected >= 0, tableView.numberOfRows > 0 {
            if let priorName,
                let movedRow = asked.contains(priorName)
                    ? found[priorName] : item.listing.row(named: priorName)
            {
                restoreSelection(movedRow + offset, parentRow: false)
            } else {
                // The selected entry went: the row that took its place is selected.
                restoreSelection(min(selected, tableView.numberOfRows - 1), parentRow: false)
            }
        }
        return true
    }

    /// The table row of the entry called `name`.
    func row(named name: String) -> Int? {
        item?.listing.row(named: name).map { $0 + (showsParentRow ? 1 : 0) }
    }

    func restoreSelection(_ row: Int?, parentRow: Bool) {
        isRestoringSelection = true
        defer { isRestoringSelection = false }
        if let row {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        } else if tableView.numberOfRows > 0, parentRow || tableView.selectedRow < 0 {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    /// The selection changed: records it, and if the user moved it, the folder you came
    /// from no longer wins it back.
    func selectionChanged() {
        selectedName = selectedEntry?.name
        selectedParentRow = isParentRowSelected
        if !isRestoringSelection {
            wantedSelection = nil
            viewIfLoaded?.window?.invalidateRestorableState()
        }
    }

    /// Row 0 is "..", the parent folder, everywhere but the top folder. It's a view row
    /// only: `item.entries` never contains it.
    var showsParentRow: Bool { item.map { $0.folder.path != "/" } ?? false }

    /// The entry shown in `row`; nil for the ".." row and rows out of range.
    func entry(atRow row: Int) -> DirectoryEntry? {
        let index = row - (showsParentRow ? 1 : 0)
        guard let item, item.entries.indices.contains(index) else { return nil }
        return item.entries[index]
    }

    /// True when the cursor is on the ".." row.
    var isParentRowSelected: Bool { showsParentRow && tableView.selectedRow == 0 }

    var selectedEntry: DirectoryEntry? { entry(atRow: tableView.selectedRow) }

    // MARK: Commands

    @objc func browserOpen(_ sender: Any?) {
        if item?.needsAccess == true {
            grantButton.performClick(nil)
            return
        }
        if isParentRowSelected {
            item?.goToParent()
        } else if let entry = selectedEntry {
            item?.open(entry)
        } else {
            NSSound.beep()
        }
    }

    /// ⌘↩ in the path field: the typed file in the hex editor, from its folder; a path
    /// that isn't a file beeps.
    @objc func browserOpenInEditor(_ sender: Any?) {
        guard let item, isEditingPath, let target = typedURL(), item.isFile(target) else {
            return NSSound.beep()
        }
        openTypedFile(target) { item.openFile($0, item.grants.scope(covering: $0)) }
    }

    /// F3/F4 act on files and folders, not on "..".
    @objc func browserView(_ sender: Any?) {
        if selectedEntry != nil { browserOpen(sender) } else { NSSound.beep() }
    }
    @objc func browserEdit(_ sender: Any?) { browserView(sender) }
    @objc func browserParent(_ sender: Any?) { item?.goToParent() }

    /// Packages list as files, as in Finder; this enters one as a folder (D-i).
    @objc func browserShowPackageContents(_ sender: Any?) {
        guard let entry = selectedEntry, entry.isPackage else { return NSSound.beep() }
        item?.go(to: entry.url)
    }

    @objc func browserBack(_ sender: Any?) { item?.goBack() }
    @objc func browserForward(_ sender: Any?) { item?.goForward() }

    @objc func browserToggleHidden(_ sender: Any?) {
        guard let item else { return }
        item.showHidden(!item.showsHidden)
    }

    @objc func browserGoToFolder(_ sender: Any?) {
        editPath()
    }

    /// Return in the path field: a folder's path goes there; a file's opens in its
    /// default app, from its folder (§4.7).
    @objc func pathEntered(_ sender: NSTextField) {
        guard let item else { return }
        guard let target = typedURL() else {
            sender.stringValue = item.folder.path
            return
        }
        if item.isFile(target) {
            openTypedFile(target, with: item.openInDefaultApp)
        } else if item.go(to: target) {
            view.window?.makeFirstResponder(tableView)
        } else {
            sender.stringValue = item.folder.path
        }
    }

    /// The path field's text as a URL: `~` is the real home folder, and a relative path
    /// starts from the current folder. Nil when the field is empty.
    private func typedURL() -> URL? {
        guard let item else { return nil }
        var text = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text == "~" || text.hasPrefix("~/") {
            text = DirectoryReader.realHomeDirectory.path + text.dropFirst()
        }
        return text.hasPrefix("/")
            ? URL(fileURLWithPath: text, isDirectory: true)
            : URL(fileURLWithPath: text, isDirectory: true, relativeTo: item.folder)
                .standardizedFileURL
    }

    /// Shows `file` selected in its folder, leaving the path field, then opens it with
    /// `open` unless the folder first needs access.
    private func openTypedFile(_ file: URL, with open: (URL) -> Void) {
        guard let item else { return }
        let file = URL(fileURLWithPath: file.path, isDirectory: false)
        guard item.reveal(file) else {
            pathField.stringValue = item.folder.path
            return
        }
        view.window?.makeFirstResponder(tableView)
        if !item.needsAccess { open(file) }
    }

    private func updateAccessPrompt() {
        guard let item else { return }
        scrollView.isHidden = item.needsAccess
        accessPrompt.isHidden = !item.needsAccess
        if item.needsAccess {
            // Resolving the saved grants isn't free: only when shown.
            let request = accessRequest
            accessLabel.stringValue = request.message
            grantButton.title = request.button
            if view.window?.firstResponder === tableView {
                view.window?.makeFirstResponder(grantButton)
            }
        } else if view.window?.firstResponder === grantButton {
            view.window?.makeFirstResponder(tableView)
        }
    }

    /// What the access prompt asks for in the current folder.
    var accessRequest: AccessRequest {
        guard let item else {
            return AccessRequest(directory: URL(fileURLWithPath: "/"), button: "", message: "")
        }
        return AccessRequest.for(
            folder: item.folder, lost: item.grants.lostGrant(covering: item.folder),
            home: DirectoryReader.realHomeDirectory,
            volume: Self.volumeURL(for: item.folder),
            coveringGrant: item.grants.grant(covering: item.folder))
    }

    static func volumeURL(for folder: URL) -> URL? {
        let existing = nearestExistingAncestor(of: folder)
        return (try? existing.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }

    static func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return URL(fileURLWithPath: "/", isDirectory: true)
    }

    @objc func browserGrantAccess(_ sender: Any?) {
        guard item != nil, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a folder to let Twin Panes browse it and everything inside it."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = Self.nearestExistingAncestor(of: accessRequest.directory)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.item?.granted(url)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let item else { return false }
        switch menuItem.action {
        case #selector(browserOpen(_:)):
            return !isEditingPath && !item.needsAccess
                && (selectedEntry != nil || isParentRowSelected)
        case #selector(browserView(_:)), #selector(browserEdit(_:)):
            return selectedEntry != nil
        case #selector(browserParent(_:)):
            return !isEditingPath && item.folder.path != "/"
        case #selector(browserShowPackageContents(_:)):
            return !isEditingPath && selectedEntry?.isPackage == true
        case #selector(browserBack(_:)):
            return !isEditingPath && !item.backStack.isEmpty
        case #selector(browserForward(_:)):
            return !isEditingPath && !item.forwardStack.isEmpty
        case #selector(browserToggleHidden(_:)):
            menuItem.state = item.showsHidden ? .on : .off
            return true
        default:
            return true
        }
    }
}
