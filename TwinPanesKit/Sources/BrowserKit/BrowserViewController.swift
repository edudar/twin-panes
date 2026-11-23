import AppKit
import TwinPanesCore
import WorkspaceKit

/// The browser tab's view: a path field, the file list, and an access prompt shown in
/// place of the list when the sandbox refuses the folder.
@MainActor
final class BrowserViewController: NSViewController, CommandScopeProviding, NSMenuItemValidation {
    weak var item: BrowserItem?
    let tableView = FileListTableView()
    let pathField = NSTextField()
    /// The clickable path above the list (D-h); the field replaces it while editing.
    let pathControl = NSPathControl()
    /// The folder each of the bar's items stands for.
    var pathURLs: [URL] = []
    private let scrollView = NSScrollView()
    private let accessPrompt = NSStackView()
    private let accessLabel = NSTextField(wrappingLabelWithString: "")
    let grantButton = NSButton()

    init(item: BrowserItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
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
            item.go()
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
    private var wantedSelection: String?
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
        scrollView.isHidden = item.needsAccess
        accessPrompt.isHidden = !item.needsAccess
        if item.needsAccess {  // resolving the saved grants isn't free: only when shown
            let request = accessRequest
            accessLabel.stringValue = request.message
            grantButton.title = request.button
        }
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
        scrollView.isHidden = item.needsAccess
        accessPrompt.isHidden = !item.needsAccess
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
    /// (with its key-view loop): tens of milliseconds for each sort of a big folder. The
    /// table only needs the new count and fresh cells in the row views it already has.
    func refreshRows() {
        let step = StepTiming.start("refresh rows")
        defer { step?.end() }
        // A big change in the count (most of a folder deleted) is slower this way than
        // a plain reload: NSTableView then reworks its row data from scratch.
        guard abs(tableView.numberOfRows - numberOfRows(in: tableView)) <= 1_000 else {
            return tableView.reloadData()
        }
        tableView.noteNumberOfRowsChanged()
        var rows = IndexSet()
        tableView.enumerateAvailableRowViews { _, row in rows.insert(row) }
        let valid = rows.filteredIndexSet { $0 < tableView.numberOfRows }
        tableView.reloadData(
            forRowIndexes: valid, columnIndexes: IndexSet(0..<tableView.numberOfColumns))
        restripe()
    }

    /// The names whose rows a reload needs: the selected entry and the one to select.
    var namesToKeep: Set<String> { Set([selectedName, wantedSelection].compactMap { $0 }) }

    /// A small live update (D-f): removes, inserts and reloads just the rows that
    /// changed, so the scroll position, the selection and the other rows' views stay.
    /// The changes were worked out with the listing; false if there's no view to update.
    func applyRowChanges(_ changes: RowChanges) -> Bool {
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
        tableView.beginUpdates()
        tableView.removeRows(at: removed, withAnimation: [])
        tableView.insertRows(at: inserted, withAnimation: [])
        tableView.endUpdates()
        tableView.reloadData(
            forRowIndexes: changed, columnIndexes: IndexSet(0..<tableView.numberOfColumns))
        restripe()
        if tableView.selectedRow < 0, selected >= 0, tableView.numberOfRows > 0 {
            // The selected entry went: the row that took its place is selected.
            restoreSelection(min(selected, tableView.numberOfRows - 1), parentRow: false)
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
        if !isRestoringSelection { wantedSelection = nil }
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
        if isParentRowSelected {
            item?.goToParent()
        } else if let entry = selectedEntry {
            item?.open(entry)
        } else {
            NSSound.beep()
        }
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

    @objc func pathEntered(_ sender: NSTextField) {
        guard let item else { return }
        var text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            sender.stringValue = item.folder.path
            return
        }
        if text == "~" || text.hasPrefix("~/") {
            text = DirectoryReader.realHomeDirectory.path + text.dropFirst()
        }
        if item.go(to: URL(fileURLWithPath: text, isDirectory: true)) {
            view.window?.makeFirstResponder(tableView)
        } else {
            sender.stringValue = item.folder.path
        }
    }

    /// What the access prompt asks for in the current folder.
    var accessRequest: AccessRequest {
        guard let item else {
            return AccessRequest(directory: URL(fileURLWithPath: "/"), button: "", message: "")
        }
        return AccessRequest.for(
            folder: item.folder, lost: item.grants.lostGrant(covering: item.folder),
            home: DirectoryReader.realHomeDirectory)
    }

    @objc func browserGrantAccess(_ sender: Any?) {
        guard item != nil, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a folder to let Twin Panes browse it and everything inside it."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = accessRequest.directory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.item?.granted(url)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let item else { return false }
        switch menuItem.action {
        case #selector(browserOpen(_:)):
            return selectedEntry != nil || isParentRowSelected
        case #selector(browserView(_:)), #selector(browserEdit(_:)):
            return selectedEntry != nil
        case #selector(browserParent(_:)):
            return item.folder.path != "/"
        case #selector(browserShowPackageContents(_:)):
            return selectedEntry?.isPackage == true
        case #selector(browserBack(_:)):
            return !item.backStack.isEmpty
        case #selector(browserForward(_:)):
            return !item.forwardStack.isEmpty
        case #selector(browserToggleHidden(_:)):
            menuItem.state = item.showsHidden ? .on : .off
            return true
        default:
            return true
        }
    }
}
