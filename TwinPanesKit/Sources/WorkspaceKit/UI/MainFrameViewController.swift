import AppKit

/// Renders a `MainFrameLayout`: panel slots with tab bars, the zoom overlay and a status
/// line. Also the responder for frame-level commands (close tab, zoom, tab switching).
///
/// It shows both panel slots; the preview pane (M7) and bottom drawer (M12) exist in the
/// model but aren't drawn yet.
@MainActor
public final class MainFrameViewController: NSViewController, WorkspaceHost,
    CommandScopeProviding, NSMenuItemValidation, NSSplitViewDelegate
{
    public let layout: MainFrameLayout
    private let closeCoordinator: CloseCoordinator

    private var slotControllers: [SlotID: SlotViewController] = [:]
    private let zoomHost = ItemHostViewController()
    private let split = NSSplitView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var token: ObservationToken?
    private var lastFocusedItemID: ItemID?
    /// Set once the divider is placed, when the window first appears.
    private var hasPlacedDivider = false
    private var restoredDividerFraction: Double?
    /// Each item's own host; items hold theirs weakly.
    private var itemHosts: [ItemID: FrontItemHost] = [:]

    public init(layout: MainFrameLayout, closeCoordinator: CloseCoordinator) {
        self.layout = layout
        self.closeCoordinator = closeCoordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public var commandScopes: [BindingScope] { [.mainFrame] }

    // MARK: View

    public override func loadView() {
        let root = NSView()

        split.isVertical = true
        split.delegate = self
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        for slot in [SlotID.leftPanel, .rightPanel] {
            let controller = SlotViewController(slot: slot, frame: self)
            slotControllers[slot] = controller
            addChild(controller)
            split.addArrangedSubview(controller.view)
        }

        addChild(zoomHost)
        zoomHost.view.translatesAutoresizingMaskIntoConstraints = false
        zoomHost.view.isHidden = true

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityIdentifier("statusLine")

        root.addSubview(split)
        root.addSubview(zoomHost.view)
        root.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            zoomHost.view.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            zoomHost.view.trailingAnchor.constraint(equalTo: split.trailingAnchor),
            zoomHost.view.topAnchor.constraint(equalTo: split.topAnchor),
            zoomHost.view.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        view = root
        token = layout.observe { [weak self] in self?.render() }
        render()
    }

    /// Brings the view hierarchy in line with the layout. Hosts release items before
    /// others attach them, so an item is never shown twice.
    func render() {
        guard isViewLoaded else { return }
        let zoomed = layout.zoomedItem
        if zoomed == nil { zoomHost.release() }
        for (slot, controller) in slotControllers {
            let selected = layout.selectedItem(in: slot)
            controller.update(
                items: layout.items(in: slot),
                showing: selected?.id == zoomed?.id ? nil : selected,
                isActive: layout.activePanel == slot)
        }
        zoomHost.display(zoomed)
        zoomHost.view.isHidden = zoomed == nil
        split.isHidden = zoomed != nil
        let items = layout.allItems
        itemHosts = Dictionary(
            uniqueKeysWithValues: items.map { item in
                (item.id, itemHosts[item.id] ?? FrontItemHost(itemID: item.id, frame: self))
            })
        for item in items {
            item.host = itemHosts[item.id]
            item.onChange = { [weak self] in self?.render() }
        }
        focusCurrentItemIfChanged()
        view.window?.invalidateRestorableState()
    }

    /// Moves keyboard focus into the item that just became current.
    private func focusCurrentItemIfChanged() {
        let current = layout.zoomedItem ?? layout.focusedPanelItem
        // Re-hosting a view (zoom, moving tabs) drops its focus back to the window, so
        // also refocus when nothing inside the window has focus any more.
        let window = view.window
        let focusLost = window.map { $0.firstResponder == nil || $0.firstResponder === $0 } ?? false
        guard current?.id != lastFocusedItemID || focusLost else { return }
        lastFocusedItemID = current?.id
        guard let current, let window else { return }
        let target = current.preferredFirstResponder
        window.makeFirstResponder(target ?? current.viewController.view)
    }

    public func showStatus(_ message: String) {
        statusLabel.stringValue = message
    }

    /// Whether `id` is the item in front: the zoomed item, or the active panel's tab.
    fileprivate func isInFront(_ id: ItemID) -> Bool {
        (layout.zoomedItem ?? layout.focusedPanelItem)?.id == id
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        // The panels start as two equal halves (docs/plans/M5.md, D-a), or where a
        // restored window had them. Earlier layouts run before the window has its size,
        // and the split gives later growth to one side.
        if !hasPlacedDivider {
            hasPlacedDivider = true
            view.layoutSubtreeIfNeeded()
            let fraction = restoredDividerFraction ?? 0.5
            split.setPosition(usableSplitWidth * fraction, ofDividerAt: 0)
        }
        lastFocusedItemID = nil
        focusCurrentItemIfChanged()
    }

    // MARK: Restoration (docs/plans/M5.md, D-c)

    /// The window's tabs and divider, to save.
    public var windowState: WindowState {
        var state = layout.savedState
        state.dividerFraction = placedDividerFraction ?? restoredDividerFraction
        return state
    }

    private var usableSplitWidth: CGFloat { split.bounds.width - split.dividerThickness }

    private var placedDividerFraction: Double? {
        guard hasPlacedDivider, usableSplitWidth > 0,
            let left = slotControllers[.leftPanel]?.view
        else { return nil }
        return Double(left.frame.width / usableSplitWidth)
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        if hasPlacedDivider { view.window?.invalidateRestorableState() }
    }

    /// Puts back saved tabs and the divider. Call before the window first appears: the
    /// divider is placed then, instead of the even split.
    public func restore(_ state: WindowState, using restorer: ItemRestorer) {
        layout.restore(state, using: restorer)
        // Saved state is data from disk: keep the fraction a fraction.
        restoredDividerFraction = state.dividerFraction.map { min(max($0, 0), 1) }
    }

    /// Makes the panel that holds `responder` the active one, so clicking or tabbing into
    /// a panel activates it (docs/plans/M5.md, D-b). Focus outside both panels, such as
    /// in the zoomed item or on the window itself, leaves the active panel as it is.
    public func followFocus(to responder: NSResponder?) {
        guard let view = responder as? NSView,
            let panel = slotControllers.first(where: { view.isDescendant(of: $0.value.view) })?
                .key,
            panel != layout.activePanel
        else { return }
        layout.activate(panel)
    }

    // MARK: Item management

    /// Asks the close workflow, then removes the item. A tab the layout won't remove
    /// (a panel's only browser) isn't asked about.
    public func closeItem(_ id: ItemID) {
        guard let item = layout.item(id), layout.canRemove(id) else { return }
        Task {
            guard await closeCoordinator.confirmClose([item]), layout.item(id) != nil,
                layout.canRemove(id)
            else { return }
            item.willClose()
            item.host = nil
            item.onChange = nil
            layout.remove(id)
        }
    }

    // MARK: Commands

    @objc public func closeTab(_ sender: Any?) {
        if let id = (layout.zoomedItem ?? layout.focusedPanelItem)?.id { closeItem(id) }
    }

    @objc public func toggleZoom(_ sender: Any?) {
        layout.toggleZoom()
        showStatus(layout.zoomedItem.map { "Zoomed: \($0.title)" } ?? "Zoom off")
    }

    @objc public func exitZoom(_ sender: Any?) {
        layout.exitZoom()
        showStatus("Zoom off")
    }

    /// Makes the other panel active and focuses its tab (`panel.switch`, docs/plans/M5.md,
    /// D-b). Does nothing while an item is zoomed.
    @objc public func switchPanel(_ sender: Any?) {
        guard canSwitchPanel, let other = layout.activePanel.otherPanel else { return }
        layout.activate(other)
    }

    private var canSwitchPanel: Bool {
        layout.zoomedItem == nil
            && layout.activePanel.otherPanel.flatMap { layout.selectedItem(in: $0) } != nil
    }

    /// Moves the active panel's tab to the other panel, which becomes active, unless the
    /// layout won't let it go (a panel's only browser).
    @objc public func moveTabToOtherPanel(_ sender: Any?) {
        guard let (item, other) = movableTab else { return }
        layout.move(item.id, to: other)
    }

    /// The tab Move Tab to Other Panel would move, and where to.
    private var movableTab: (any WorkspaceItem, SlotID)? {
        guard layout.zoomedItem == nil, let item = layout.focusedPanelItem,
            let other = layout.activePanel.otherPanel, layout.canMove(item.id, to: other)
        else { return nil }
        return (item, other)
    }

    // MARK: Dragging tabs

    /// Whether a dragged tab can land on `slot`'s tab bar: it's from this window and the
    /// layout lets it go there. Tabs from other windows wait for M11.
    func canDropTab(_ id: ItemID, in slot: SlotID) -> Bool {
        layout.item(id) != nil && layout.canMove(id, to: slot)
    }

    /// Moves a dropped tab into `slot` at `insertion`, an index into the slot's tabs as
    /// the tab bar shows them during the drag, with the dragged tab still in its place.
    func dropTab(_ id: ItemID, in slot: SlotID, at insertion: Int) {
        guard canDropTab(id, in: slot) else { return }
        // `move` takes the tab out before putting it back, so a tab moving right
        // within its own bar lands one place earlier than the bar's index.
        let current = layout.items(in: slot).firstIndex { $0.id == id }
        let index = current.map { $0 < insertion ? insertion - 1 : insertion } ?? insertion
        layout.move(id, to: slot, at: index)
    }

    @objc public func selectNextTab(_ sender: Any?) { layout.selectAdjacentTab(1) }
    @objc public func selectPreviousTab(_ sender: Any?) { layout.selectAdjacentTab(-1) }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(closeTab(_:)):
            return (layout.zoomedItem ?? layout.focusedPanelItem).map { layout.canRemove($0.id) }
                ?? false
        case #selector(toggleZoom(_:)):
            menuItem.title = layout.zoomedItem == nil ? "Zoom Item" : "Exit Zoom"
            return layout.focusedPanelItem != nil || layout.zoomedItem != nil
        case #selector(switchPanel(_:)):
            return canSwitchPanel
        case #selector(moveTabToOtherPanel(_:)):
            return movableTab != nil
        case #selector(exitZoom(_:)):
            return layout.zoomedItem != nil
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return layout.items(in: layout.activePanel).count > 1
        default:
            return true
        }
    }
}

/// One panel slot: its tab bar plus the selected item's view.
@MainActor
final class SlotViewController: NSViewController, CommandScopeProviding {
    let slot: SlotID
    private weak var frame: MainFrameViewController?
    private let tabBar = TabBarView()
    private let host = ItemHostViewController()

    init(slot: SlotID, frame: MainFrameViewController) {
        self.slot = slot
        self.frame = frame
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var commandScopes: [BindingScope] { [.slot(slot)] }

    override func loadView() {
        let root = NSView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabBar)
        root.addSubview(host.view)
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            host.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        root.setAccessibilityIdentifier(slot.rawValue)
        tabBar.onSelect = { [weak self] id in self?.frame?.layout.select(id) }
        tabBar.onClose = { [weak self] id in self?.frame?.closeItem(id) }
        tabBar.canDrop = { [weak self] id in
            guard let self, let frame else { return false }
            return frame.canDropTab(id, in: slot)
        }
        tabBar.onDrop = { [weak self] id, insertion in
            guard let self else { return }
            frame?.dropTab(id, in: slot, at: insertion)
        }
        view = root
    }

    func update(items: [any WorkspaceItem], showing: (any WorkspaceItem)?, isActive: Bool) {
        _ = view
        tabBar.update(
            items: items, selected: frame?.layout.selection[slot], isActivePanel: isActive,
            canClose: { [weak self] id in self?.frame?.layout.canRemove(id) ?? false })
        host.display(showing)
    }
}

/// The host one item sees. Its status messages reach the status line only while the item
/// is in front, so a browser updating in the other panel, or in a tab behind, doesn't
/// overwrite what the item you're looking at said.
@MainActor
private final class FrontItemHost: WorkspaceHost {
    let itemID: ItemID
    private weak var frame: MainFrameViewController?

    init(itemID: ItemID, frame: MainFrameViewController) {
        self.itemID = itemID
        self.frame = frame
    }

    func showStatus(_ message: String) {
        guard let frame, frame.isInFront(itemID) else { return }
        frame.showStatus(message)
    }
}
