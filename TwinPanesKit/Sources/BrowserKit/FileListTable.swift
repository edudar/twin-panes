import AppKit
import TwinPanesCore
import UniformTypeIdentifiers
import WorkspaceKit

/// The file list: adds the `item.browser.fileList` scope, so keys like Tab, Return and
/// Backspace are bound only while the list has focus (PLAN.md §4.11).
final class FileListTableView: NSTableView, CommandScopeProviding {
    var commandScopes: [BindingScope] { [.item(.browser, part: "fileList")] }
    /// The icons drawn for the rows no longer match: a new appearance or screen scale.
    var iconsChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        iconsChanged?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        iconsChanged?()
    }
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
        let step = StepTiming.start("cell draw")
        defer { step?.end() }
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

/// Row icons, by type (docs/plans/M4.md, D-b), each drawn once into a 16-point bitmap
/// for one screen scale and appearance (performance pass, step 3a): the workspace's
/// icons carry every size up to 1024 px, and drawing one scaled and colour-matched it
/// on every draw. Applications have icons of their own, so they are kept by path, the
/// last few hundred.
///
/// Emptied when the system colours change (folders follow the accent colour) and when
/// the app becomes active (a newly installed app may claim a type); `didEmpty` then
/// tells the tables to fetch their icons again.
@MainActor
final class IconCache {
    static let shared = IconCache(center: .default)
    static let didEmpty = Notification.Name("IconCache.didEmpty")

    struct Key: Hashable {
        let id: String
        let scale: CGFloat
        let appearance: NSAppearance.Name
    }

    private var byType: [Key: NSImage] = [:]
    private var byPath: [Key: NSImage] = [:]
    private var pathOrder: [Key] = []
    let pathLimit = 256
    private let center: NotificationCenter

    init(center: NotificationCenter) {
        self.center = center
        for name in [
            NSColor.systemColorsDidChangeNotification, NSApplication.didBecomeActiveNotification,
        ] {
            center.addObserver(self, selector: #selector(empty), name: name, object: nil)
        }
    }

    /// The generic folder icon at 16 points, for the path bar and the ".." row, whose
    /// image views pick a size themselves.
    private(set) lazy var folder: NSImage = {
        let copy = NSWorkspace.shared.icon(for: .folder).copy() as? NSImage ?? NSImage()
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }()

    @objc func empty() {
        byType = [:]
        byPath = [:]
        pathOrder = []
        center.post(name: Self.didEmpty, object: self)
    }

    /// The entry at `path` changed (a new icon pasted in Get Info, say).
    func forget(path: String) {
        let gone = pathOrder.filter { $0.id == path }
        guard !gone.isEmpty else { return }
        for key in gone { byPath[key] = nil }
        pathOrder.removeAll { $0.id == path }
    }

    func icon(
        for entry: DirectoryEntry, scale: CGFloat, appearance: NSAppearance.Name
    ) -> NSImage {
        guard entry.type.conforms(to: .application) else {
            let key = Key(id: entry.type.identifier, scale: scale, appearance: appearance)
            if let icon = byType[key] { return icon }
            let icon = StepTiming.measure("icon lookup") {
                Self.drawn(NSWorkspace.shared.icon(for: entry.type), key)
            }
            byType[key] = icon
            return icon
        }
        let key = Key(id: entry.url.path, scale: scale, appearance: appearance)
        if let icon = byPath[key] { return icon }
        let icon = StepTiming.measure("icon lookup") {
            Self.drawn(NSWorkspace.shared.icon(forFile: key.id), key)
        }
        byPath[key] = icon
        pathOrder.append(key)
        if pathOrder.count > pathLimit { byPath[pathOrder.removeFirst()] = nil }
        return icon
    }

    /// `icon` drawn once, at 16 points, for the key's scale and appearance.
    static func drawn(_ icon: NSImage, _ key: Key) -> NSImage {
        let pixels = Int((16 * key.scale).rounded())
        let size = NSSize(width: 16, height: 16)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return icon }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let appearance = NSAppearance(named: key.appearance) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            icon.draw(in: NSRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
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
        // Stripes come from the row views (see `stripe`): NSTableView's own filled its
        // whole clip rect, 100-180 ms of software drawing per navigation once a folder
        // had 100k rows (docs/plans/M4.md, step 13).
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = NSColor.alternatingContentBackgroundColors[0]
        tableView.allowsMultipleSelection = false
        tableView.style = .fullWidth
        tableView.target = self
        tableView.doubleAction = #selector(browserOpen(_:))
        tableView.setAccessibilityIdentifier("fileList")
        tableView.iconsChanged = { [weak self] in self?.refreshIcons() }
        NotificationCenter.default.addObserver(
            forName: IconCache.didEmpty, object: IconCache.shared, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshIcons() } }
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

    /// The background of the row view showing `row`.
    func stripe(_ row: Int) -> NSColor {
        let colors = NSColor.alternatingContentBackgroundColors
        return colors[row % colors.count]
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        rowView.backgroundColor = stripe(row)
    }

    /// Rows moved under their row views (a refresh, a live update): colour them again.
    func restripe() {
        tableView.enumerateAvailableRowViews { rowView, row in
            rowView.backgroundColor = stripe(row)
        }
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
        let step = StepTiming.start("cell config")
        defer { step?.end() }
        guard let id = tableColumn?.identifier.rawValue, let column = Column(rawValue: id)
        else { return nil }
        if showsParentRow, row == 0 { return parentCell(column) }
        guard let entry = entry(atRow: row) else { return nil }
        let cell = reusableCell(column == .name ? "name" : "detail")
        cell.text = text(for: entry, column)
        cell.icon = column == .name ? icon(for: entry) : nil
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

    /// The icon for `entry` in the table's current scale and appearance.
    func icon(for entry: DirectoryEntry) -> NSImage {
        let scale = tableView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let appearance = tableView.effectiveAppearance.name
        return IconCache.shared.icon(for: entry, scale: scale, appearance: appearance)
    }

    /// The icons no longer match the screen or the appearance: give the name cells on
    /// screen theirs again.
    func refreshIcons() {
        tableView.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: 0) as? FileCell, let entry = entry(atRow: row)
            else { return }
            cell.icon = icon(for: entry)
        }
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
