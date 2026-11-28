import AppKit
import TwinPanesCore

/// One row of the sidebar: a section heading, or a folder under it.
final class SidebarNode: NSObject {
    let title: String
    /// Nil for a section heading.
    let folder: URL?
    let symbol: String?
    /// Set for a volume that can be ejected: its row gets an eject button.
    let volume: Volume?
    /// Why the row can't be chosen now; nil when it can. Shown as its tooltip.
    let unavailableReason: String?
    var children: [SidebarNode]

    init(
        title: String, folder: URL? = nil, symbol: String? = nil, volume: Volume? = nil,
        unavailableReason: String? = nil, children: [SidebarNode] = []
    ) {
        self.title = title
        self.folder = folder
        self.symbol = symbol
        self.volume = volume
        self.unavailableReason = unavailableReason
        self.children = children
    }
}

/// The sidebar (docs/plans/M5.md, D-d): Favorites and Locations in a source list.
/// Clicking a folder reports it through `onOpen`; the app opens it in the active panel
/// and highlights the row for the folder that panel shows.
@MainActor
public final class SidebarViewController: NSViewController, NSMenuItemValidation {
    /// Called with the folder of a row the user chose.
    public var onOpen: ((URL) -> Void)?
    /// Called with a volume whose eject button was clicked.
    public var onEject: ((Volume) -> Void)?
    /// Called after the user added, moved or removed a favorite here, so the app can
    /// show the change in every window's sidebar.
    public var onFavoritesEdited: (() -> Void)?

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
    private var volumeNodes: [SidebarNode] = []
    private var isTrashListable = false
    var validatedDrag: (sequence: Int, hasFolder: Bool)?
    /// The event the context menu came up for. Tests stand in for it: posting a real event
    /// through `NSApp` stops the main run loop, which ends a test process early.
    var currentEvent: () -> NSEvent? = { NSApp.currentEvent }

    public override func loadView() {
        // One column as wide as the sidebar: left at its default 100 pt, every name was
        // cut off at a fraction of the sidebar's width.
        let column = NSTableColumn(identifier: .init("sidebar"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.headerView = nil
        outlineView.style = .sourceList
        // Row height follows the system's sidebar size setting, as in Finder.
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityIdentifier("sidebar")
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask([.move, .link], forLocal: true)
        outlineView.menu = makeContextMenu()
        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
        reloadFavorites()
        reloadLocations()
        Task { await refreshTrashAccess() }
        // A selector observer, removed by NotificationCenter when the sidebar goes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        outlineView.sizeLastColumnToFit()
    }

    public func show(volumes: [Volume]) {
        volumeNodes = volumes.map { volume in
            SidebarNode(
                title: volume.name, folder: volume.url,
                symbol: volume.url.path == "/" ? "internaldrive" : "externaldrive",
                volume: volume.isEjectable ? volume : nil)
        }
        reloadLocations()
    }

    /// Checks again whether the Trash can be listed, which the user may have changed in
    /// System Settings while the app ran, and shows its row enabled or greyed out.
    public func refreshTrashAccess() async {
        guard let home = favorites.standard.first else { return }
        let trash = TrashFolder(home: home)
        let isListable = await Task.detached { trash.isListable() }.value
        guard isListable != isTrashListable else { return }
        isTrashListable = isListable
        reloadLocations()
    }

    @objc private func appDidBecomeActive(_ notification: Notification) {
        Task { await refreshTrashAccess() }
    }

    /// Home, the volumes, then the Trash, which needs Full Disk Access to be listed.
    private func reloadLocations() {
        var places: [SidebarNode] = []
        if let home = favorites.standard.first {
            places.append(
                SidebarNode(
                    title: FileManager.default.displayName(atPath: home.path), folder: home,
                    symbol: "house"))
        }
        places += volumeNodes
        if let home = favorites.standard.first {
            places.append(
                SidebarNode(
                    title: "Trash", folder: TrashFolder(home: home).url, symbol: "trash",
                    unavailableReason: isTrashListable
                        ? nil
                        : "Showing the Trash needs Full Disk Access: System Settings › "
                            + "Privacy & Security › Full Disk Access."))
        }
        locationsSection.children = places
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
        // Only the shown folder is resolved (the panel has opened it anyway); the rows are
        // compared by path. Resolving them touched Desktop, Documents and Downloads on
        // every update, and macOS asked for access to each at launch.
        let target = highlighted.map { $0.resolvingSymlinksInPath().path }
        let row = target.flatMap { target in
            (0..<outlineView.numberOfRows).first { row in
                guard let nodeFolder = (outlineView.item(atRow: row) as? SidebarNode)?.folder
                else { return false }
                return Self.samePath(nodeFolder, target)
            }
        }
        isHighlighting = true
        defer { isHighlighting = false }
        if let row {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(removeClickedFavorite(_:)) ? isClickedRowAFavorite : true
    }

    private func reload() {
        guard isViewLoaded else { return }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        highlight(highlighted)
    }

    /// Finder's sidebar symbols for the standard folders, a plain folder for the rest.
    /// Finder's Applications glyph isn't a public symbol; `a.circle` is the closest.
    /// Compares paths without touching the disk, so choosing icons and highlights never
    /// opens a folder macOS guards (Desktop, Documents, Downloads). Case-insensitive, as
    /// on the boot volume; a favorite reached through a symlink isn't matched.
    private static func samePath(_ folder: URL, _ path: String) -> Bool {
        folder.standardizedFileURL.path.caseInsensitiveCompare(path) == .orderedSame
    }

    private static func symbol(for folder: URL, home: URL?) -> String {
        if samePath(folder, "/Applications") { return "a.circle" }
        guard let home else { return "folder" }
        if samePath(folder, home.standardizedFileURL.path) { return "house" }
        let standardSymbols: [(String, String)] = [
            ("Desktop", "menubar.dock.rectangle"),
            ("Documents", "doc"),
            ("Downloads", "arrow.down.circle"),
            ("Applications", "a.circle"),
            ("Movies", "film"),
            ("Music", "music.note"),
            ("Pictures", "photo"),
        ]
        for (name, symbol) in standardSymbols {
            let candidate = home.appendingPathComponent(name, isDirectory: true)
            if samePath(folder, candidate.standardizedFileURL.path) { return symbol }
        }
        return "folder"
    }

    private static func icon(forSymbol symbol: String) -> NSImage {
        if symbol == "a.circle", let applicationsGlyph { return applicationsGlyph }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfiguration) ?? NSImage()
    }

    /// Finder's Applications glyph, which no public symbol matches: the template icon the
    /// system ships for sidebars, readable in the sandbox. `a.circle` stands in if a
    /// macOS release drops the file. Read once, a few KB, on first use.
    private static let applicationsGlyph: NSImage? = {
        let file = URL(
            fileURLWithPath:
                "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SidebarApplicationsFolder.icns"
        )
        guard let image = NSImage(contentsOf: file) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    /// The icon size Finder's sidebar uses for its rows.
    private static let iconConfiguration = NSImage.SymbolConfiguration(
        pointSize: 15, weight: .regular)
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
        guard let node = node(item) else { return false }
        return node.folder != nil && node.unavailableReason == nil
    }

    public func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let node = node(item) else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: node.title)
        if node.folder != nil {
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
        } else {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
        }
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        var leading = label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
        if let symbol = node.symbol {
            let image = NSImageView(image: Self.icon(forSymbol: symbol))
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 20),
            ])
            leading = label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6)
        }
        var trailing = cell.trailingAnchor
        if let volume = node.volume {
            let eject = EjectButton(
                volume: volume, target: self, action: #selector(ejectClicked(_:)))
            cell.addSubview(eject)
            NSLayoutConstraint.activate([
                eject.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                eject.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            trailing = eject.leadingAnchor
        }
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailing, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if let reason = node.unavailableReason {
            cell.toolTip = reason
            label.textColor = .disabledControlTextColor
            cell.imageView?.alphaValue = 0.4
        }
        return cell
    }

    @objc func ejectClicked(_ sender: EjectButton) { onEject?(sender.volume) }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isHighlighting,
            let folder = node(outlineView.item(atRow: outlineView.selectedRow))?.folder
        else { return }
        onOpen?(folder)
    }
}

/// The eject button on an ejectable volume's row.
final class EjectButton: NSButton {
    let volume: Volume

    init(volume: Volume, target: AnyObject, action: Selector) {
        self.volume = volume
        super.init(frame: .zero)
        image = NSImage(
            systemSymbolName: "eject.fill", accessibilityDescription: "Eject \(volume.name)")
        isBordered = false
        refusesFirstResponder = true
        self.target = target
        self.action = action
        toolTip = "Eject “\(volume.name)”"
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
