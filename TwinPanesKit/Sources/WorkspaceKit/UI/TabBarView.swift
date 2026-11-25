import AppKit

/// Per-panel tab bar in the style of Safari's: capsule tabs that share the bar's width,
/// each with a close button on the left (shown on hover and on the selected tab), the
/// item's icon and its title. Tabs are dragged within the bar and onto the other
/// panel's (docs/plans/M5.md, D-b); overflow menus come later.
@MainActor
final class TabBarView: NSView {
    var onSelect: ((ItemID) -> Void)?
    var onClose: ((ItemID) -> Void)?
    /// Whether a dragged tab may be dropped here.
    var canDrop: ((ItemID) -> Bool)?
    /// A tab was dropped at an index into the tabs as shown during the drag.
    var onDrop: ((ItemID, Int) -> Void)?
    /// Where the dragged tab would land, drawn as a line between tabs.
    private var dropIndicatorX: CGFloat? {
        didSet {
            if dropIndicatorX != oldValue { needsDisplay = true }
        }
    }

    private let stack = NSStackView()
    static let height: CGFloat = 34

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.distribution = .fillEqually
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Tabs grow to share the bar, but no wider than Safari's maximum.
        let trailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        trailing.priority = .defaultLow
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            trailing,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        setAccessibilityRole(.tabGroup)
        registerForDraggedTypes([.workspaceTab])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        if let dropIndicatorX {
            NSColor.controlAccentColor.setFill()
            NSRect(x: dropIndicatorX - 1, y: 5, width: 2, height: bounds.height - 10).fill()
        }
    }

    // MARK: Dropping tabs

    private var tabFrames: [NSRect] {
        stack.arrangedSubviews.map { convert($0.frame, from: stack) }
    }

    private func draggedTab(_ info: NSDraggingInfo) -> ItemID? {
        guard let item = info.draggingPasteboard.pasteboardItems?.first else { return nil }
        return ItemID(draggedTab: item)
    }

    private func insertion(for info: NSDraggingInfo) -> Int {
        let x = convert(info.draggingLocation, from: nil).x
        return tabInsertionIndex(at: x, tabCentres: tabFrames.map(\.midX))
    }

    private func indicatorX(at insertion: Int) -> CGFloat {
        let frames = tabFrames
        if insertion < frames.count { return frames[insertion].minX - 2 }
        return (frames.last?.maxX ?? 4) + 2
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let id = draggedTab(sender), canDrop?(id) == true else {
            dropIndicatorX = nil
            return []
        }
        dropIndicatorX = indicatorX(at: insertion(for: sender))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropIndicatorX = nil }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropIndicatorX = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropIndicatorX = nil
        guard let id = draggedTab(sender), canDrop?(id) == true else { return false }
        onDrop?(id, insertion(for: sender))
        return true
    }

    /// `canClose` says which tabs get a close button.
    func update(
        items: [any WorkspaceItem], selected: ItemID?, isActivePanel: Bool,
        canClose: (ItemID) -> Bool
    ) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for item in items {
            let tab = TabItemView(
                id: item.id, title: item.title, icon: item.icon, isDirty: item.isDirty,
                isSelected: item.id == selected, isActivePanel: isActivePanel)
            tab.canClose = canClose(item.id)
            tab.onSelect = { [weak self] id in self?.onSelect?(id) }
            tab.onClose = { [weak self] id in self?.onClose?(id) }
            stack.addArrangedSubview(tab)
            tab.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
            tab.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        }
    }
}

/// One tab: a capsule that highlights when selected or hovered, and that can be dragged.
@MainActor
final class TabItemView: NSView, NSDraggingSource {
    let id: ItemID
    let isSelected: Bool
    let isActivePanel: Bool
    private let isDirty: Bool
    /// False hides the close button: the tab is a panel's only browser.
    var canClose = true {
        didSet { updateAppearance() }
    }
    var onSelect: ((ItemID) -> Void)?
    var onClose: ((ItemID) -> Void)?

    private let closeButton = NSButton()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var isHovered = false {
        didSet { updateAppearance() }
    }

    init(
        id: ItemID, title: String, icon: NSImage?, isDirty: Bool, isSelected: Bool,
        isActivePanel: Bool
    ) {
        self.id = id
        self.isSelected = isSelected
        self.isActivePanel = isActivePanel
        self.isDirty = isDirty
        super.init(frame: .zero)

        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: "Close \(title)")
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab"
        closeButton.refusesFirstResponder = true

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyDown
        iconView.isHidden = icon == nil

        titleLabel.stringValue = title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 12, weight: isSelected ? .medium : .regular)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [closeButton, iconView, titleLabel])
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])

        toolTip = title
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(isDirty ? "\(title), edited" : title)
        setAccessibilityValue(isSelected)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func updateAppearance() {
        // Edited tabs show a dot where the close button sits until you hover.
        let showClose = isHovered || (isSelected && !isDirty)
        closeButton.image = NSImage(
            systemSymbolName: showClose ? "xmark" : (isDirty ? "circle.fill" : "xmark"),
            accessibilityDescription: "Close tab")
        closeButton.symbolConfiguration = .init(pointSize: showClose ? 9 : 6, weight: .semibold)
        closeButton.alphaValue = canClose && (showClose || isDirty) ? 1 : 0
        closeButton.isEnabled = canClose
        closeButton.contentTintColor = .secondaryLabelColor
        titleLabel.textColor =
            isSelected && isActivePanel ? .labelColor : .secondaryLabelColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor?
        if isSelected {
            fill = isActivePanel ? .tertiarySystemFill : .quaternarySystemFill
        } else if isHovered {
            fill = .quaternarySystemFill
        } else {
            fill = nil
        }
        guard let fill else { return }
        fill.setFill()
        let radius = bounds.height / 2
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// A click on a tab in a background window selects it, as in Finder and Safari.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Selects on mouse-up, or starts a drag once the mouse moves. Selecting rebuilds the
    /// tab bar's views, so it can't happen on mouse-down: this view must still be there
    /// to start the drag.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                onSelect?(id)
                return
            }
            let moved = hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y)
            if moved > 3 {
                startDragging(with: event)
                return
            }
        }
    }

    private func startDragging(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: id.draggedTab)
        let snapshot = bitmapImageRepForCachingDisplay(in: bounds).map { rep in
            cacheDisplay(in: bounds, to: rep)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(rep)
            return image
        }
        item.setDraggingFrame(bounds, contents: snapshot)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    /// Middle-click closes, as in Safari.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?(id) } else { super.otherMouseDown(with: event) }
    }

    @objc private func closeClicked() { onClose?(id) }

    override func accessibilityPerformPress() -> Bool {
        onSelect?(id)
        return true
    }
}
