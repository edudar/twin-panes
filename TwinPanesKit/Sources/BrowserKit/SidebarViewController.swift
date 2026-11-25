import AppKit
import TwinPanesCore

/// One row of the sidebar: a section heading, or a folder under it.
final class SidebarNode: NSObject {
    let title: String
    /// Nil for a section heading.
    let folder: URL?
    let symbol: String?
    var children: [SidebarNode]

    init(title: String, folder: URL? = nil, symbol: String? = nil, children: [SidebarNode] = []) {
        self.title = title
        self.folder = folder
        self.symbol = symbol
        self.children = children
    }
}

/// The sidebar (docs/plans/M5.md, D-d): Favorites and Locations in a source list.
/// Clicking a folder reports it through `onOpen`; the app opens it in the active panel
/// and highlights the row for the folder that panel shows.
@MainActor
public final class SidebarViewController: NSViewController {
    /// Called with the folder of a row the user chose.
    public var onOpen: ((URL) -> Void)?

    let favorites: Favorites
    let outlineView = NSOutlineView()
    let favoritesSection = SidebarNode(title: "Favorites")
    let locationsSection = SidebarNode(title: "Locations")

    public init(favorites: Favorites) {
        self.favorites = favorites
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Set while the app highlights a row, so the selection doesn't count as a click.
    private var isHighlighting = false
    private var highlighted: URL?

    public override func loadView() {
        let column = NSTableColumn(identifier: .init("sidebar"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityIdentifier("sidebar")
        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
        reloadFavorites()
    }

    public func show(volumes: [Volume]) {
        locationsSection.children = volumes.map { volume in
            SidebarNode(
                title: volume.name, folder: volume.url,
                symbol: volume.url.path == "/" ? "internaldrive" : "externaldrive")
        }
        reload()
    }

    public func reloadFavorites() {
        let home = favorites.standard.first
        favoritesSection.children = favorites.folders.map { folder in
            SidebarNode(
                title: FileManager.default.displayName(atPath: folder.path), folder: folder,
                symbol: Self.symbol(for: folder, home: home))
        }
        reload()
    }

    public func highlight(_ folder: URL?) {
        highlighted = folder?.standardizedFileURL
        let row = (0..<outlineView.numberOfRows).first { row in
            guard let path = (outlineView.item(atRow: row) as? SidebarNode)?.folder?.path
            else { return false }
            return path == highlighted?.path
        }
        isHighlighting = true
        defer { isHighlighting = false }
        if let row {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    private func reload() {
        guard isViewLoaded else { return }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        highlight(highlighted)
    }

    /// Finder's symbols for the standard folders, a plain folder for the rest.
    private static func symbol(for folder: URL, home: URL?) -> String {
        if folder.path == home?.path { return "house" }
        switch folder.lastPathComponent {
        case "Desktop": return "menubar.dock.rectangle"
        case "Documents": return "doc"
        case "Downloads": return "arrow.down.circle"
        case "Applications": return "app.dashed"
        default: return "folder"
        }
    }
}

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    private func node(_ item: Any?) -> SidebarNode? { item as? SidebarNode }

    public func outlineView(
        _ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?
    )
        -> Int
    {
        node(item)?.children.count ?? 2
    }

    public func outlineView(
        _ outlineView: NSOutlineView, child index: Int, ofItem item: Any?
    )
        -> Any
    {
        node(item)?.children[index] ?? (index == 0 ? favoritesSection : locationsSection)
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        node(item)?.folder == nil
    }

    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        node(item)?.folder == nil
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        node(item)?.folder != nil
    }

    public func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let node = node(item) else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: node.title)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        var leading = label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
        if let symbol = node.symbol {
            let image = NSImageView(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                    ?? NSImage())
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
            ])
            leading = label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6)
        }
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isHighlighting,
            let folder = node(outlineView.item(atRow: outlineView.selectedRow))?.folder
        else { return }
        onOpen?(folder)
    }
}
