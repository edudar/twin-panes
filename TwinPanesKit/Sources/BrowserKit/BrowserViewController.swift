import AppKit
import TwinPanesCore
import WorkspaceKit

/// The browser tab's view: a path field, the file list, and an access prompt shown in
/// place of the list when the sandbox refuses the folder.
@MainActor
final class BrowserViewController: NSViewController, CommandScopeProviding, NSMenuItemValidation {
    unowned let item: BrowserItem
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
        if !item.hasListed { item.go() } else { reload(selecting: nil) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        item.updateStatus()
    }

    /// Shows the item's current listing; selects `name` if given, else the first row.
    func reload(selecting name: String?) {
        guard isViewLoaded else { return }
        pathField.stringValue = item.folder.path
        tableView.reloadData()
        scrollView.isHidden = item.needsAccess
        accessPrompt.isHidden = !item.needsAccess
        accessLabel.stringValue =
            "Twin Panes needs your permission to show “\(item.title)”.\n"
            + "Grant access once and it’s remembered."
        let row =
            name.flatMap { n in item.entries.firstIndex { $0.url.lastPathComponent == n } }
            ?? 0
        if !item.entries.isEmpty {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
    }

    var selectedEntry: DirectoryEntry? {
        item.entries.indices.contains(tableView.selectedRow)
            ? item.entries[tableView.selectedRow] : nil
    }

    // MARK: Commands

    @objc func browserOpen(_ sender: Any?) {
        if let entry = selectedEntry { item.open(entry) } else { NSSound.beep() }
    }

    @objc func browserView(_ sender: Any?) { browserOpen(sender) }
    @objc func browserEdit(_ sender: Any?) { browserOpen(sender) }
    @objc func browserParent(_ sender: Any?) { item.goToParent() }

    @objc func browserGoToFolder(_ sender: Any?) {
        view.window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    @objc func pathEntered(_ sender: NSTextField) {
        var text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("~") {
            text = DirectoryReader.realHomeDirectory.path + text.dropFirst()
        }
        if item.go(to: URL(fileURLWithPath: text, isDirectory: true)) {
            view.window?.makeFirstResponder(tableView)
        } else {
            sender.stringValue = item.folder.path
        }
    }

    @objc func browserGrantAccess(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose a folder to let Twin Panes browse it and everything inside it."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = item.folder
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.item.granted(url)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(browserOpen(_:)), #selector(browserView(_:)), #selector(browserEdit(_:)):
            return selectedEntry != nil
        case #selector(browserParent(_:)):
            return item.folder.path != "/"
        default:
            return true
        }
    }
}
