import AppKit
import TwinPanesCore
import UniformTypeIdentifiers
import WorkspaceKit

/// The file list: adds the `item.browser.fileList` scope, so keys like Tab, Return and
/// Backspace are bound only while the list has focus (PLAN.md §4.11).
final class FileListTableView: NSTableView, CommandScopeProviding {
    var commandScopes: [BindingScope] { [.item(.browser, part: "fileList")] }
}

/// A file-list cell that draws its icon and text itself (docs/plans/M4.md, step 13):
/// with an image view and a text field per cell, building the first screenful of a
/// folder's rows (some 200 views) cost 120-200 ms. The ".." row keeps a real text field.
final class FileCell: NSTableCellView {
    var text = "" {
        didSet { if text != oldValue { needsDisplay = true } }
    }
    var icon: NSImage? {
        didSet { if icon !== oldValue { needsDisplay = true } }
    }
    var alignment = NSTextAlignment.left {
        didSet { if alignment != oldValue { needsDisplay = true } }
    }
    let secondary: Bool

    init(secondary: Bool) {
        self.secondary = secondary
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 2
        if let icon {
            icon.draw(in: NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16))
            x += 22
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.alignment = alignment
        let selected = backgroundStyle == .emphasized
        let color: NSColor =
            selected
            ? .alternateSelectedControlTextColor
            : secondary ? .secondaryLabelColor : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let height = ceil(
            NSFont.systemFont(ofSize: NSFont.systemFontSize).boundingRectForFont.height)
        let rect = NSRect(
            x: x, y: (bounds.height - height) / 2, width: max(0, bounds.width - x - 2),
            height: height)
        (text as NSString).draw(
            with: rect, options: [.usesLineFragmentOrigin], attributes: attributes)
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

    /// The generic folder icon at 16 points.
    private(set) lazy var folder = Self.small(NSWorkspace.shared.icon(for: .folder))

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
        let cell = reusableCell(column == .name ? "name" : "detail")
        cell.text = text(for: entry, column)
        cell.icon = column == .name ? IconCache.shared.icon(for: entry) : nil
        cell.alignment = column == .size ? .right : .left
        return cell
    }

    /// The ".." row: a folder icon and ".." in the name column, the rest blank. One row,
    /// so it keeps real subviews (and an accessible label).
    private func parentCell(_ column: Column) -> NSView? {
        guard column == .name else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("parent")
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) {
            return cell
        }
        let label = NSTextField(labelWithString: "..")
        label.setAccessibilityLabel("Parent folder")
        let icon = NSImageView(image: IconCache.shared.folder)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 6
        stack.identifier = identifier
        stack.setAccessibilityIdentifier("parentRow")
        return stack
    }

    /// A cell from the table's reuse queue, or a new one.
    private func reusableCell(_ id: String) -> FileCell {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? FileCell {
            return cell
        }
        let cell = FileCell(secondary: id == "detail")
        cell.identifier = identifier
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
