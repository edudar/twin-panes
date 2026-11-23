import AppKit
import TwinPanesCore
import UniformTypeIdentifiers
import WorkspaceKit

/// The file list: adds the `item.browser.fileList` scope, so keys like Tab, Return and
/// Backspace are bound only while the list has focus (PLAN.md §4.11).
final class FileListTableView: NSTableView, CommandScopeProviding {
    var commandScopes: [BindingScope] { [.item(.browser, part: "fileList")] }
}

/// A file-list cell: an optional 16-point icon and a label, laid out by frame: Auto
/// Layout made building the first screenful of rows cost about 100 ms in Debug builds.
final class FileCell: NSTableCellView {
    init(icon: Bool) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        textField = label
        if icon {
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyDown
            addSubview(image)
            imageView = image
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        var x: CGFloat = 2
        if let imageView {
            place(imageView, NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16))
            x += 22
        }
        guard let textField else { return }
        let height = textField.intrinsicContentSize.height
        place(
            textField,
            NSRect(
                x: x, y: (bounds.height - height) / 2, width: max(0, bounds.width - x - 2),
                height: height))
    }

    /// Layout runs again and again as the table rebuilds key-view loops: setting a frame
    /// that hasn't changed still makes an image view work out its drawing rect.
    private func place(_ view: NSView, _ frame: NSRect) {
        if view.frame != frame { view.frame = frame }
    }
}

/// Row icons, by type (docs/plans/M4.md, D-b). Applications have icons of their own, so
/// they are looked up by path and the last few hundred kept.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var byType: [UTType: NSImage] = [:]
    private var byPath: [String: NSImage] = [:]
    private var pathOrder: [String] = []
    let pathLimit = 256

    /// A 16-point copy: the workspace's icons carry every size, which an image view
    /// weighs up each time it lays out.
    static func small(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as? NSImage ?? icon
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    func icon(for entry: DirectoryEntry) -> NSImage {
        guard entry.type.conforms(to: .application) else {
            if let icon = byType[entry.type] { return icon }
            let icon = Self.small(NSWorkspace.shared.icon(for: entry.type))
            byType[entry.type] = icon
            return icon
        }
        let path = entry.url.path
        if let icon = byPath[path] { return icon }
        let icon = Self.small(NSWorkspace.shared.icon(forFile: path))
        byPath[path] = icon
        pathOrder.append(path)
        if pathOrder.count > pathLimit { byPath[pathOrder.removeFirst()] = nil }
        return icon
    }
}

extension BrowserViewController: NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String, CaseIterable {
        case name = "Name", size = "Size", modified = "Date Modified", kind = "Kind"

        var sortColumn: ListingOrder.Column {
            switch self {
            case .name: return .name
            case .size: return .size
            case .modified: return .modified
            case .kind: return .kind
            }
        }

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
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: column.sortColumn.rawValue, ascending: true)
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

    /// The header's sort indicator, matching `order`.
    func showSortIndicator(_ order: ListingOrder) {
        let wanted = [NSSortDescriptor(key: order.column.rawValue, ascending: order.ascending)]
        if tableView.sortDescriptors != wanted { tableView.sortDescriptors = wanted }
    }

    /// A header click: sort by that column (D-c). Folders stay on top either way.
    func tableView(
        _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard let item, let first = tableView.sortDescriptors.first,
            let column = first.key.flatMap(ListingOrder.Column.init(rawValue:))
        else { return }
        var order = item.order
        order.column = column
        order.ascending = first.ascending
        item.sort(by: order)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let item else { return 0 }
        return item.entries.count + (showsParentRow ? 1 : 0)
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    )
        -> NSView?
    {
        guard let id = tableColumn?.identifier.rawValue, let column = Column(rawValue: id)
        else { return nil }
        if showsParentRow, row == 0 { return parentCell(column) }
        guard let entry = entry(atRow: row) else { return nil }
        let cell = reusableCell(column == .name ? "name" : "detail", icon: column == .name)
        cell.textField?.stringValue = text(for: entry, column)
        if column == .name {
            cell.imageView?.image = IconCache.shared.icon(for: entry)
        } else {
            cell.textField?.alignment = column == .size ? .right : .left
        }
        return cell
    }

    /// The ".." row: a folder icon and ".." in the name column, the rest blank.
    private func parentCell(_ column: Column) -> NSView? {
        guard column == .name else { return nil }
        let cell = reusableCell("parent", icon: true)
        cell.textField?.stringValue = ".."
        cell.textField?.setAccessibilityLabel("Parent folder")
        cell.imageView?.image = NSWorkspace.shared.icon(for: .folder)
        cell.setAccessibilityIdentifier("parentRow")
        return cell
    }

    /// A cell from the table's reuse queue, or a new one (docs/plans/M4.md, step 13:
    /// building every cell afresh cost tens of milliseconds per reload of 100k rows).
    private func reusableCell(_ id: String, icon: Bool) -> FileCell {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? FileCell {
            return cell
        }
        let cell = FileCell(icon: icon)
        cell.identifier = identifier
        if id == "detail" { cell.textField?.textColor = .secondaryLabelColor }
        return cell
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
        entry(atRow: row)?.name
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let item else { return }
        selectionChanged()
        if isParentRowSelected {
            let parent = item.folder.deletingLastPathComponent().path
            item.host?.showStatus("Parent folder: \(parent)")
            return
        }
        guard let entry = selectedEntry else { return item.updateStatus() }
        let size = entry.size.map { " · \($0.formatted()) bytes" } ?? ""
        item.host?.showStatus("\(entry.url.path)\(size)")
    }
}
