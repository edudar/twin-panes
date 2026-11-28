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
    /// Locale or time zone changed: Size and Date Modified cells need reformatting.
    var formattingChanged: (() -> Void)?
    nonisolated(unsafe) private var formattingObservers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observeFormatting()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        for observer in formattingObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func observeFormatting() {
        for name in [
            NSLocale.currentLocaleDidChangeNotification,
            Notification.Name.NSSystemTimeZoneDidChange,
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.formattingChanged?() }
            }
            formattingObservers.append(observer)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        FileCell.styleVersion += 1
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

    /// The text's font, the same in every cell.
    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    /// Bumped to make every cell lay its text out again: on an appearance change, and
    /// for a font change once there's a preference for it.
    static var styleVersion = 0

    private struct LineKey: Equatable {
        let text: String
        let width: CGFloat
        let version: Int
    }

    /// The text laid out (and truncated in the middle) for one width: kept until the
    /// text, the width or the style changes (docs/plans/M4.md, performance pass, step 4).
    /// It carries no colour, so selecting the row or a new appearance needs no new one.
    private var line: (key: LineKey, line: CTLine, width: CGFloat)?
    /// How many lines this cell has laid out, for tests.
    private(set) var lineBuilds = 0

    func preparedLine(
        width: CGFloat, version: Int = styleVersion
    ) -> (line: CTLine, width: CGFloat) {
        let key = LineKey(text: text, width: width, version: version)
        if let line, line.key == key { return (line.line, line.width) }
        lineBuilds += 1
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        func laidOut(_ string: String) -> CTLine {
            CTLineCreateWithAttributedString(
                NSAttributedString(string: string, attributes: attributes))
        }
        var made = laidOut(text)
        if CTLineGetTypographicBounds(made, nil, nil, nil) > width {
            made = CTLineCreateTruncatedLine(made, width, .middle, laidOut("…")) ?? laidOut("")
        }
        let madeWidth = CGFloat(CTLineGetTypographicBounds(made, nil, nil, nil))
        line = (key, made, madeWidth)
        return (made, madeWidth)
    }

    override func draw(_ dirtyRect: NSRect) {
        let step = StepTiming.start("cell draw")
        defer { step?.end() }
        var x: CGFloat = 2
        if !secondary {  // the name column, whose icon may still be on its way
            icon?.draw(
                in: NSRect(
                    x: x, y: ((bounds.height - 16) / 2).rounded(), width: 16, height: 16))
            x += 22
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let available = max(0, bounds.width - x - 2)
        let (line, width) = preparedLine(width: available)
        let color: NSColor =
            backgroundStyle == .emphasized
            ? .alternateSelectedControlTextColor
            : secondary ? .secondaryLabelColor : .labelColor
        context.saveGState()
        defer { context.restoreGState() }
        if isFlipped {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        color.setFill()
        context.textMatrix = .identity
        let (ascent, descent) = (Self.font.ascender, -Self.font.descender)
        context.textPosition = CGPoint(
            x: alignment == .right ? max(x, x + available - width) : x,
            y: ((bounds.height - ascent - descent) / 2 + descent).rounded())
        CTLineDraw(line, context)
    }
}

/// Row icons, by type (docs/plans/M4.md, D-b), each drawn once into a 16-point bitmap
/// for one screen scale and appearance (performance pass, step 3a): the workspace's
/// icons carry every size up to 1024 px, and drawing one scaled and colour-matched it
/// on every draw. Applications have icons of their own, so they are kept by path, the
/// last few hundred.
///
/// Looked up and drawn off the main actor (step 3b): a first lookup goes through
/// LaunchServices, tens of milliseconds for a screenful of apps. Until it's done there's
/// no icon, and `didChange` then tells the tables to give their visible cells theirs.
/// The system colours changing (folders follow the accent colour) or the app becoming
/// active (a new app may claim a type) draws every icon again; the old ones show until
/// then.
@MainActor
final class IconCache {
    static let shared = IconCache(center: .default)
    static let didChange = Notification.Name("IconCache.didChange")
    private nonisolated static let brokenSymbolicLinkID = "twinpanes.brokenSymbolicLink"

    struct Key: Hashable, Sendable {
        /// A type identifier, or an app's path.
        let id: String
        let isPath: Bool
        let scale: CGFloat
        let appearance: NSAppearance.Name
    }

    typealias Renderer = @Sendable (Key) -> NSImage?
    private var icons: [Key: (image: NSImage?, generation: Int)] = [:]
    private var loading: [Key: (generation: Int, requestID: Int)] = [:]
    private var nextRequestID = 0
    private var pathOrder: [Key] = []
    let pathLimit = 256
    private var customIcons: [String: Bool] = [:]
    private var customIconOrder: [String] = []
    private var probingCustomIcons: Set<String> = []
    private let customIconLimit = 1024
    private var generation = 0
    private var announcing = false
    private let center: NotificationCenter
    private let render: Renderer
    private let queue = DispatchQueue(label: "IconCache", qos: .userInitiated)

    init(center: NotificationCenter, render: @escaping Renderer = IconCache.render) {
        self.center = center
        self.render = render
        for name in [
            NSColor.systemColorsDidChangeNotification, NSApplication.didBecomeActiveNotification,
        ] {
            center.addObserver(self, selector: #selector(redraw), name: name, object: nil)
        }
    }

    /// The generic folder icon at 16 points, for the path bar and the ".." row, whose
    /// image views pick a size themselves.
    private(set) lazy var folder: NSImage = Self.makeFolderIcon()

    private static func makeFolderIcon() -> NSImage {
        let copy = NSWorkspace.shared.icon(for: .folder).copy() as? NSImage ?? NSImage()
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    /// Draws every icon again; until each is done, the old one shows.
    @objc func redraw() {
        folder = Self.makeFolderIcon()
        (customIcons, customIconOrder, probingCustomIcons) = ([:], [], [])
        generation += 1
        announce()
    }

    /// These entries of `folder` changed (a new icon pasted in Get Info, say). The app
    /// icons (at most `pathLimit`) are walked; the custom-icon probes (up to 1024 in a big
    /// folder) are walked only when `names` outnumber them, else each name is looked up:
    /// a live update while a big folder lists can name tens of thousands of entries, and
    /// a burst of small updates, 78 in one turn, would walk the probes each time
    /// (docs/plans/M4.md, performance pass; PLAN.md §9, "From M5").
    func forget(_ names: Set<String>, in folder: URL) {
        guard !names.isEmpty else { return }
        let parent = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let parentNS = parent as NSString
        let nameStart = parentNS.length
        // `NSString` literal prefix and `substring(from:)` share UTF-16 offsets, avoiding
        // Swift String's canonical-equivalence prefix vs UTF-8 byte-offset mismatch and
        // grapheme-cluster rejection when a filename starts with a combining mark.
        func changedPath(_ path: String) -> Bool {
            let ns = path as NSString
            guard ns.length > nameStart,
                ns.range(of: parent, options: [.anchored, .literal]).location == 0
            else { return false }
            return names.contains(ns.substring(from: nameStart))
        }
        func changed(_ key: Key) -> Bool { key.isPath && changedPath(key.id) }
        for key in pathOrder where changed(key) { icons[key] = nil }
        pathOrder.removeAll(where: changed)
        for key in loading.keys where changed(key) { loading[key] = nil }
        if names.count < customIcons.count + probingCustomIcons.count {
            forgetCustomIcons(atPaths: Set(names.map { parent + $0 }))
        } else {
            forgetCustomIcons(atPaths: Set(customIcons.keys.filter(changedPath)))
            for path in probingCustomIcons where changedPath(path) {
                probingCustomIcons.remove(path)
            }
        }
    }

    private func forgetCustomIcons(atPaths paths: Set<String>) {
        var forgotten = Set<String>()
        for path in paths {
            probingCustomIcons.remove(path)
            if customIcons.removeValue(forKey: path) != nil { forgotten.insert(path) }
        }
        if !forgotten.isEmpty { customIconOrder.removeAll(where: forgotten.contains) }
    }

    /// The icon for `entry`, or nil until it's been drawn.
    func icon(
        for entry: DirectoryEntry, scale: CGFloat, appearance: NSAppearance.Name
    ) -> NSImage? {
        if entry.isBrokenSymbolicLink {
            let key = Key(
                id: Self.brokenSymbolicLinkID, isPath: false, scale: scale, appearance: appearance)
            let cached = icons[key]
            if cached?.generation != generation { load(key) }
            return cached?.image
        }
        let path = entry.url.path
        var usePath = entry.isApplication
        if !usePath, let known = customIcons[path] {
            usePath = known
        } else if !usePath {
            probeCustomIcon(atPath: path)
        }
        let key = Key(
            id: usePath ? path : entry.type.identifier, isPath: usePath, scale: scale,
            appearance: appearance)
        let cached = icons[key]
        if cached?.generation != generation { load(key) }
        return cached?.image
    }

    /// Read-only cache lookup for `entry`; never triggers `load` or custom-icon probing.
    func cachedIcon(
        for entry: DirectoryEntry, scale: CGFloat, appearance: NSAppearance.Name
    ) -> NSImage? {
        let key: Key
        if entry.isBrokenSymbolicLink {
            key = Key(
                id: Self.brokenSymbolicLinkID, isPath: false, scale: scale, appearance: appearance)
        } else {
            let path = entry.url.path
            let usePath = entry.isApplication || customIcons[path] == true
            key = Key(
                id: usePath ? path : entry.type.identifier, isPath: usePath, scale: scale,
                appearance: appearance)
        }
        guard let cached = icons[key], cached.generation == generation else { return nil }
        return cached.image
    }

    private func probeCustomIcon(atPath path: String) {
        guard probingCustomIcons.insert(path).inserted else { return }
        let (wanted, box) = (generation, WeakIconCache(self))
        queue.async {
            let hasCustom = Self.hasCustomIcon(atPath: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.cache?.probedCustomIcon(path, hasCustom, wanted) }
            }
        }
    }

    private func probedCustomIcon(_ path: String, _ hasCustom: Bool, _ wanted: Int) {
        guard probingCustomIcons.remove(path) != nil, wanted == generation else { return }
        if customIcons[path] == nil {
            customIconOrder.append(path)
            if customIconOrder.count > customIconLimit {
                customIcons[customIconOrder.removeFirst()] = nil
            }
        }
        customIcons[path] = hasCustom
        if hasCustom { announce() }
    }

    nonisolated static func hasCustomIcon(atPath path: String) -> Bool {
        var buf = [UInt8](repeating: 0, count: 32)
        let len = getxattr(path, "com.apple.FinderInfo", &buf, 32, 0, XATTR_NOFOLLOW)
        guard len >= 10 else { return false }
        return (UInt16(buf[8]) << 8 | UInt16(buf[9])) & 0x0400 != 0
    }

    private func load(_ key: Key) {
        guard loading[key]?.generation != generation else { return }
        nextRequestID += 1
        let (wanted, requestID, render, box) = (
            generation, nextRequestID, render, WeakIconCache(self)
        )
        loading[key] = (wanted, requestID)
        queue.async {
            let image = render(key)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    box.cache?.loaded(key, image, generation: wanted, requestID: requestID)
                }
            }
        }
    }

    private func loaded(
        _ key: Key, _ image: NSImage?, generation wanted: Int, requestID: Int
    ) {
        guard let pending = loading[key], pending == (wanted, requestID) else { return }
        loading[key] = nil
        if key.isPath, icons[key] == nil {
            pathOrder.append(key)
            if pathOrder.count > pathLimit { icons[pathOrder.removeFirst()] = nil }
        }
        icons[key] = (image, wanted)
        if image != nil { announce() }
    }

    /// One `didChange` for everything drawn in one turn of the run loop.
    private func announce() {
        guard !announcing else { return }
        announcing = true
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                announcing = false
                center.post(name: Self.didChange, object: self)
            }
        }
    }

    /// Looks the key's icon up and draws it, off the main actor.
    nonisolated static func render(_ key: Key) -> NSImage? {
        if key.id == brokenSymbolicLinkID {
            return renderBrokenSymbolicLink(key)
        }
        let workspace = NSWorkspace.shared
        let icon =
            key.isPath
            ? workspace.icon(forFile: key.id) : UTType(key.id).map { workspace.icon(for: $0) }
        return icon.map { drawn($0, key) }
    }

    private nonisolated static func renderBrokenSymbolicLink(_ key: Key) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        guard
            let symbol = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "Broken symbolic link")?
                .withSymbolConfiguration(config)
        else { return nil }
        let canvas = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let size = symbol.size
            guard size.width > 0, size.height > 0 else { return false }
            let scale = min(rect.width / size.width, rect.height / size.height)
            let width = size.width * scale
            let height = size.height * scale
            let target = NSRect(
                x: (rect.width - width) / 2, y: (rect.height - height) / 2,
                width: width, height: height)
            symbol.draw(in: target)
            return true
        }
        return drawn(canvas, key)
    }

    /// `icon` drawn once, at 16 points, for the key's scale and appearance.
    nonisolated static func drawn(_ icon: NSImage, _ key: Key) -> NSImage {
        let pixels = Int((16 * key.scale).rounded())
        let size = NSSize(width: 16, height: 16)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return icon.copy() as? NSImage ?? NSImage() }
        // The size in points first: the context takes its scale from it when it's made.
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return icon.copy() as? NSImage ?? NSImage()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let appearance = NSAppearance(named: key.appearance) ?? NSAppearance(named: .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            icon.draw(in: NSRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

/// The cache, weakly, for a drawing done off the main actor to hand back.
private final class WeakIconCache: Sendable {
    @MainActor weak var cache: IconCache?
    @MainActor init(_ cache: IconCache) { self.cache = cache }
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
        tableView.allowsMultipleSelection = true
        tableView.style = .fullWidth
        tableView.target = self
        tableView.doubleAction = #selector(browserOpen(_:))
        tableView.setAccessibilityIdentifier("fileList")
        tableView.iconsChanged = { [weak self] in self?.refreshIcons() }
        tableView.formattingChanged = { [weak self] in self?.refreshFormatting() }
        if let iconObserver { NotificationCenter.default.removeObserver(iconObserver) }
        iconObserver = NotificationCenter.default.addObserver(
            forName: IconCache.didChange, object: IconCache.shared, queue: .main
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
        rowView.canDrawSubviewsIntoLayer = true
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
        configure(cell, entry, column)
        return cell
    }

    private func configure(_ cell: FileCell, _ entry: DirectoryEntry, _ column: Column) {
        cell.text = text(for: entry, column)
        cell.icon = column == .name ? icon(for: entry) : nil
        cell.alignment = column == .size ? .right : .left
        cell.toolTip =
            column == .name && entry.isBrokenSymbolicLink
            ? "Broken symbolic link (target does not exist)" : nil
    }

    /// Gives the cells of `rowView` the entry now at `row`, in place; false if the row
    /// view doesn't hold an entry's cells (the ".." row, or a row becoming it).
    func refreshCells(in rowView: NSTableRowView, row: Int) -> Bool {
        guard !(showsParentRow && row == 0), let entry = entry(atRow: row) else { return false }
        for (index, tableColumn) in tableView.tableColumns.enumerated() {
            guard let column = Column(rawValue: tableColumn.identifier.rawValue),
                let cell = rowView.view(atColumn: index) as? FileCell
            else { return false }
            configure(cell, entry, column)
        }
        return true
    }

    /// The ".." row: a folder icon and ".." in the name column, the rest blank. One row,
    /// so it keeps real subviews (and an accessible label).
    private func parentCell(_ column: Column) -> NSView? {
        guard column == .name else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("parent")
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        cell.setAccessibilityIdentifier("parentRow")

        let imageView = NSImageView(image: IconCache.shared.folder)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let textField = NSTextField(labelWithString: "..")
        textField.font = FileCell.font
        textField.lineBreakMode = .byTruncatingMiddle
        textField.setAccessibilityLabel("Parent folder")
        textField.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(
                lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// The icon for `entry` in the table's current scale and appearance.
    func icon(for entry: DirectoryEntry) -> NSImage? {
        let scale = tableView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let appearance = tableView.effectiveAppearance.name
        return IconCache.shared.icon(for: entry, scale: scale, appearance: appearance)
    }

    private var nameColumn: Int { tableView.column(withIdentifier: .init(Column.name.rawValue)) }

    /// The icons no longer match the screen or the appearance: give the name cells on
    /// screen theirs again.
    func refreshIcons() {
        let column = nameColumn
        guard column >= 0 else { return }
        tableView.enumerateAvailableRowViews { rowView, row in
            if showsParentRow, row == 0 {
                (rowView.view(atColumn: column) as? NSTableCellView)?.imageView?.image =
                    IconCache.shared.folder
                return
            }
            guard let cell = rowView.view(atColumn: column) as? FileCell,
                let entry = entry(atRow: row)
            else { return }
            cell.icon = icon(for: entry)
        }
    }

    /// Locale or time zone changed: update the visible Size and Date Modified cells.
    func refreshFormatting() {
        let columns: [(Int, Column)] = [Column.size, .modified].compactMap { column in
            let index = tableView.column(withIdentifier: .init(column.rawValue))
            return index >= 0 ? (index, column) : nil
        }
        guard !columns.isEmpty else { return }
        tableView.enumerateAvailableRowViews { rowView, row in
            guard let entry = entry(atRow: row) else { return }
            for (index, column) in columns {
                guard let cell = rowView.view(atColumn: index) as? FileCell else { continue }
                cell.text = text(for: entry, column)
            }
        }
    }

    /// True when at least one name cell is on screen and every one shows the cached icon
    /// for the table's current scale and appearance, without triggering a load. For tests
    /// and the smoke test.
    var shownIconsAreCurrent: Bool {
        let column = nameColumn
        guard column >= 0 else { return false }
        let scale = tableView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let appearance = tableView.effectiveAppearance.name
        var checked = 0
        var current = true
        tableView.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: column) as? FileCell,
                let entry = entry(atRow: row)
            else { return }
            checked += 1
            let wanted = IconCache.shared.cachedIcon(
                for: entry, scale: scale, appearance: appearance)
            if wanted == nil || cell.icon !== wanted { current = false }
        }
        return checked > 0 && current
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

    /// ".." goes up a folder; it's never one of several rows F5–F8 act on.
    func tableView(
        _ tableView: NSTableView,
        selectionIndexesForProposedSelection proposed: IndexSet
    ) -> IndexSet {
        guard showsParentRow, proposed.count > 1, proposed.contains(0) else { return proposed }
        var rows = proposed
        rows.remove(0)
        return rows
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let item else { return }
        selectionChanged()
        if !updateSelectionStatus() {
            item.updateStatus()
        }
    }

    /// Formats a byte count for the status bar: exact bytes below 1 KB, and a rounded
    /// decimal size with the exact byte count in parentheses from 1 KB up
    /// (e.g. "12.6 MB (12,623,229 bytes)").
    nonisolated static func formatStatusBytes(_ bytes: UInt64) -> String {
        let exact = "\(bytes.formatted()) bytes"
        guard bytes >= 1_000 else { return exact }
        let rounded = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes), countStyle: .file)
        return "\(rounded) (\(exact))"
    }

    /// Shows "3 of 120 selected · 1 KB (1,234 bytes)"; folders' sizes aren't counted
    /// (D-a). A big selection is added up off the main actor.
    func showSelectionSummary(of item: BrowserItem) {
        selectionSummaryGeneration &+= 1
        let generation = selectionSummaryGeneration
        let selection = selection
        let total = item.entries.count
        let path = item.folder.path
        let summary: @Sendable () -> String = {
            let bytes = selection.rows.reduce(UInt64(0)) {
                $0 + (selection.listing.rows[$1].size ?? 0)
            }
            return "\(path) · \(selection.count.formatted()) of "
                + "\(total.formatted()) selected · \(Self.formatStatusBytes(bytes))"
        }
        guard selection.count > FolderListing.mainActorLimit else {
            return item.host?.showStatus(summary()) ?? ()
        }
        selectionSummaryTask = Task { [weak self, weak item] in
            let text = await Task.detached(priority: .userInitiated) { summary() }.value
            guard let self, let item,
                self.selectionSummaryGeneration == generation,
                item.folder.path == path,
                self.selection.rows == selection.rows
            else { return }
            item.host?.showStatus(text)
        }
    }
}
