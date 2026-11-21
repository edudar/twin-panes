import AppKit

/// Renders a `MainFrameLayout`: panel slots with tab bars, the zoom overlay and a status
/// line. Also the responder for frame-level commands (close tab, zoom, tab switching).
///
/// M0 shows the panel slots only; the preview pane (M7) and bottom drawer (M12) exist in
/// the model but aren't drawn yet. The right panel appears once it has an item (M5).
@MainActor
public final class MainFrameViewController: NSViewController, WorkspaceHost,
    CommandScopeProviding, NSMenuItemValidation
{
    public let layout: MainFrameLayout
    private let closeCoordinator: CloseCoordinator

    private var slotControllers: [SlotID: SlotViewController] = [:]
    private let zoomHost = ItemHostViewController()
    private let split = NSSplitView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var token: ObservationToken?
    private var lastFocusedItemID: ItemID?

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
            controller.view.isHidden = slot != .leftPanel && layout.items(in: slot).isEmpty
        }
        zoomHost.display(zoomed)
        zoomHost.view.isHidden = zoomed == nil
        split.isHidden = zoomed != nil
        for item in layout.allItems {
            item.host = self
            item.onChange = { [weak self] in self?.render() }
        }
        focusCurrentItemIfChanged()
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

    public override func viewDidAppear() {
        super.viewDidAppear()
        lastFocusedItemID = nil
        focusCurrentItemIfChanged()
    }

    // MARK: Item management

    /// Asks the close workflow, then removes the item.
    public func closeItem(_ id: ItemID) {
        guard let item = layout.item(id) else { return }
        Task {
            guard await closeCoordinator.confirmClose([item]) else { return }
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

    @objc public func selectNextTab(_ sender: Any?) { layout.selectAdjacentTab(1) }
    @objc public func selectPreviousTab(_ sender: Any?) { layout.selectAdjacentTab(-1) }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(closeTab(_:)):
            return layout.focusedPanelItem != nil || layout.zoomedItem != nil
        case #selector(toggleZoom(_:)):
            menuItem.title = layout.zoomedItem == nil ? "Zoom Item" : "Exit Zoom"
            return layout.focusedPanelItem != nil || layout.zoomedItem != nil
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
    private unowned let frame: MainFrameViewController
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
        tabBar.onSelect = { [weak self] id in self?.frame.layout.select(id) }
        tabBar.onClose = { [weak self] id in self?.frame.closeItem(id) }
        view = root
    }

    func update(items: [any WorkspaceItem], showing: (any WorkspaceItem)?, isActive: Bool) {
        _ = view
        tabBar.update(
            items: items, selected: frame.layout.selection[slot], isActivePanel: isActive)
        host.display(showing)
    }
}
