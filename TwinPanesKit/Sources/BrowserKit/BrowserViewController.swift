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
    private let scrollView = NSScrollView()
    private let accessPrompt = NSStackView()
    private let accessLabel = NSTextField(wrappingLabelWithString: "")

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

        configureTable()
        if let item { showSortIndicator(item.order) }
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        accessLabel.alignment = .center
        let grant = NSButton(
            title: "Grant Access…", target: self, action: #selector(browserGrantAccess(_:)))
        grant.keyEquivalent = "\r"
        accessPrompt.orientation = .vertical
        accessPrompt.spacing = 12
        accessPrompt.addArrangedSubview(accessLabel)
        accessPrompt.addArrangedSubview(grant)

        let root = NSView()
        for view in [pathField, scrollView, accessPrompt] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            pathField.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            pathField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            pathField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
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
        guard isViewLoaded, let item else { return }
        pathField.stringValue = item.folder.path
        scrollView.isHidden = item.needsAccess
        accessPrompt.isHidden = !item.needsAccess
        accessLabel.stringValue =
            "Twin Panes needs your permission to show “\(item.title)”.\n"
            + "Grant access once and it’s remembered."
        wantedSelection = name
        tableView.reloadData()
        restoreSelection(nil, parentRow: true)
        tableView.scrollRowToVisible(0)
    }

    /// Shows the item's current rows, keeping the selected entry selected by name;
    /// after a re-sort, also in view. Batches don't scroll.
    func reloadKeepingSelection(scrolling: Bool = false) {
        guard isViewLoaded, let item else { return }
        scrollView.isHidden = item.needsAccess
        accessPrompt.isHidden = !item.needsAccess
        let selected = selectedName
        let onParent = selectedParentRow
        tableView.reloadData()
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

    /// A live update (D-f): removes, inserts and reloads just the rows that changed
    /// between `before` and the item's rows, so the scroll position, the selection and
    /// the other rows' views stay. False (nothing done) when the change is too big.
    func updateRows(from before: [DirectoryEntry], touching names: Set<String>) -> Bool {
        guard isViewLoaded, let item, !item.needsAccess else { return false }
        let after = item.listing.rows
        let oldNames = Set(before.map(\.name))
        let newNames = Set(after.map(\.name))
        let offset = showsParentRow ? 1 : 0
        let removed = IndexSet(
            before.indices.filter { !newNames.contains(before[$0].name) }.map { $0 + offset })
        let inserted = IndexSet(
            after.indices.filter { !oldNames.contains(after[$0].name) }.map { $0 + offset })
        let changed = IndexSet(
            after.indices.filter {
                names.contains(after[$0].name) && oldNames.contains(after[$0].name)
            }
            .map { $0 + offset })
        guard removed.count + inserted.count + changed.count <= 100 else { return false }
        let selected = tableView.selectedRow
        tableView.beginUpdates()
        tableView.removeRows(at: removed, withAnimation: [])
        tableView.insertRows(at: inserted, withAnimation: [])
        tableView.endUpdates()
        tableView.reloadData(
            forRowIndexes: changed, columnIndexes: IndexSet(0..<tableView.numberOfColumns))
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

    @objc func browserBack(_ sender: Any?) { item?.goBack() }
    @objc func browserForward(_ sender: Any?) { item?.goForward() }

    @objc func browserToggleHidden(_ sender: Any?) {
        guard let item else { return }
        item.showHidden(!item.showsHidden)
    }

    @objc func browserGoToFolder(_ sender: Any?) {
        view.window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
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

    @objc func browserGrantAccess(_ sender: Any?) {
        guard let item, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a folder to let Twin Panes browse it and everything inside it."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = item.folder
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
