import AppKit
import WorkspaceKit

/// M0 stand-in for the browser (M4): a search field and a fake file list. Exists to
/// exercise focus scopes: F3 means View here, Tab switches panels only from the list.
@MainActor
final class PlaceholderBrowserItem: WorkspaceItem {
    let id = ItemID()
    let kind: ItemKind = .browser
    let preferredSlot: SlotID = .leftPanel
    let title: String
    weak var host: WorkspaceHost?
    var onChange: (() -> Void)?
    private lazy var controller = PlaceholderBrowserViewController(item: self)

    init(title: String) { self.title = title }

    var viewController: NSViewController { controller }
    var preferredFirstResponder: NSView? { controller.tableView }
}

@MainActor
final class PlaceholderBrowserViewController: NSViewController, CommandScopeProviding,
    NSTableViewDataSource, NSTableViewDelegate
{
    private unowned let item: PlaceholderBrowserItem
    let tableView = FileListTableView()
    let searchField = NSSearchField()
    private let rows = (1...40).map { String(format: "file-%02d.bin", $0) }

    init(item: PlaceholderBrowserItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var commandScopes: [BindingScope] { [.item(.browser)] }

    override func loadView() {
        searchField.placeholderString = "Filter (placeholder)"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("browserSearch")

        let column = NSTableColumn(identifier: .init("name"))
        column.title = "Name"
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.setAccessibilityIdentifier("fileList")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(searchField)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        tableView.selectRowIndexes([0], byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    )
        -> NSView?
    {
        let cell = NSTextField(labelWithString: rows[row])
        cell.lineBreakMode = .byTruncatingMiddle
        return cell
    }

    var selectedName: String {
        tableView.selectedRow >= 0 ? rows[tableView.selectedRow] : "(nothing)"
    }

    @objc func browserView(_ sender: Any?) {
        item.host?.showStatus("F3 in browser → browser.view: would view \(selectedName)")
    }

    @objc func browserSwitchPanel(_ sender: Any?) {
        item.host?.showStatus("Tab in file list → browser.switchPanel (one panel until M5)")
    }
}

/// The file list: adds the `item.browser.fileList` scope, so Tab is bound only here.
final class FileListTableView: NSTableView, CommandScopeProviding {
    var commandScopes: [BindingScope] { [.item(.browser, part: "fileList")] }
}
