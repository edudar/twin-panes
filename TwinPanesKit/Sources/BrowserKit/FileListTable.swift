import AppKit
import TwinPanesCore
import WorkspaceKit

/// The file list: adds the `item.browser.fileList` scope, so keys like Tab, Return and
/// Backspace are bound only while the list has focus (PLAN.md §4.11).
final class FileListTableView: NSTableView, CommandScopeProviding {
    var commandScopes: [BindingScope] { [.item(.browser, part: "fileList")] }
}

extension BrowserViewController: NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String, CaseIterable {
        case name = "Name", size = "Size", modified = "Date Modified", kind = "Kind"

        var width: CGFloat {
            switch self {
            case .name: return 260
            case .size: return 80
            case .modified: return 150
            case .kind: return 140
            }
        }
    }

    func configureTable() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = column.rawValue
            tableColumn.width = column.width
            tableColumn.minWidth = 50
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.style = .fullWidth
        tableView.target = self
        tableView.doubleAction = #selector(browserOpen(_:))
        tableView.setAccessibilityIdentifier("fileList")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { item.entries.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    )
        -> NSView?
    {
        guard let id = tableColumn?.identifier.rawValue, let column = Column(rawValue: id)
        else { return nil }
        let entry = item.entries[row]
        let label = NSTextField(labelWithString: text(for: entry, column))
        label.lineBreakMode = .byTruncatingMiddle
        if column != .name {
            label.textColor = .secondaryLabelColor
            label.alignment = column == .size ? .right : .left
            return label
        }
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: entry.url.path))
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 6
        return stack
    }

    private func text(for entry: DirectoryEntry, _ column: Column) -> String {
        switch column {
        case .name: return entry.name
        case .size:
            return entry.size.map {
                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
            } ?? "--"
        case .modified:
            return entry.modified?.formatted(date: .abbreviated, time: .shortened) ?? "--"
        case .kind: return entry.kind
        }
    }

    func tableView(
        _ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int
    )
        -> String?
    {
        item.entries[row].name
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let entry = selectedEntry else { return item.updateStatus() }
        let size = entry.size.map { " · \($0.formatted()) bytes" } ?? ""
        item.host?.showStatus("\(entry.url.path)\(size)")
    }
}
