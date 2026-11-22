import AppKit
import TwinPanesCore

/// The data inspector panel (PLAN.md §4.6): the bytes at the cursor decoded as
/// integers, floats, characters and timestamps, in the chosen byte order.
@MainActor
public final class InspectorView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public private(set) var endianness: Inspector.Endianness = .little
    private(set) var rows: [Inspector.Row] = []
    private var bytes = Data()

    let order = NSSegmentedControl(
        labels: ["Little Endian", "Big Endian"], trackingMode: .selectOne, target: nil,
        action: nil)
    private let table = NSTableView()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        order.target = self
        order.action = #selector(orderChanged(_:))
        order.selectedSegment = 0
        order.controlSize = .small
        order.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        order.setAccessibilityIdentifier("inspectorByteOrder")

        for (id, title, width) in [("name", "Type", 120.0), ("value", "Value", 200.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.rowSizeStyle = .small
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .none
        table.setAccessibilityIdentifier("inspectorTable")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        for view in [order, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            order.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            order.centerXAnchor.constraint(equalTo: centerXAnchor),
            scroll.topAnchor.constraint(equalTo: order.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        show(Data())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Decodes `bytes` (up to `Inspector.byteCount` from the cursor).
    public func show(_ bytes: Data) {
        self.bytes = bytes
        rows = Inspector.rows(for: bytes, endianness: endianness)
        table.reloadData()
    }

    @objc func orderChanged(_ sender: NSSegmentedControl) {
        endianness = sender.selectedSegment == 1 ? .big : .little
        show(bytes)
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let entry = rows[row]
        let isName = tableColumn?.identifier.rawValue == "name"
        let label = NSTextField(labelWithString: isName ? entry.name : entry.value ?? "—")
        label.font =
            isName
            ? .systemFont(ofSize: NSFont.smallSystemFontSize)
            : .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor =
            isName ? .secondaryLabelColor : entry.value == nil ? .tertiaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = !isName && entry.value != nil
        return label
    }
}
