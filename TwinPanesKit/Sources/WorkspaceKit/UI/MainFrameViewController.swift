import AppKit

extension NSToolbarItem.Identifier {
    /// Toolbar identifier for toggling the operations activity popover.
    public static let toggleOperations = NSToolbarItem.Identifier("toggleOperations")
    /// Toolbar identifier for toggling the trailing preview pane.
    public static let togglePreviewPane = NSToolbarItem.Identifier("togglePreviewPane")
}

/// Renders a `MainFrameLayout`: panel slots with tab bars, optional sidebar and trailing
/// preview pane, the zoom overlay, bottom accessory, and status line. Also the responder
/// for frame-level commands (close tab, zoom, tab switching).
///
/// The bottom drawer (M12) exists in the model but isn't drawn yet.
@MainActor
public final class MainFrameViewController: NSViewController, WorkspaceHost,
    CommandScopeProviding, NSMenuItemValidation, NSToolbarItemValidation, NSSplitViewDelegate,
    NSPopoverDelegate
{
    public let layout: MainFrameLayout
    private let closeCoordinator: CloseCoordinator

    private var slotControllers: [SlotID: SlotViewController] = [:]
    private let zoomHost = ItemHostViewController()
    private let split = NSSplitView()
    /// The split controller hosting the sidebar and the panel area so AppKit gives the
    /// sidebar full-height system material and toolbar tracking.
    private let splitViewController = SidebarSplitViewController()
    private let sidebarHostController = ContainerViewController()
    private let contentController = ContainerViewController()
    private let previewHostController = ContainerViewController()
    private lazy var sidebarItem: NSSplitViewItem = {
        let item = NSSplitViewItem(sidebarWithViewController: sidebarHostController)
        item.canCollapse = true
        item.isCollapsed = true
        item.minimumThickness = 120
        item.maximumThickness = 400
        item.holdingPriority = .init(260)
        return item
    }()
    private lazy var contentItem: NSSplitViewItem = {
        let item = NSSplitViewItem(viewController: contentController)
        item.holdingPriority = .defaultLow
        return item
    }()
    // Regular split item (never `inspectorWithViewController:`), so `SidebarSplitViewController`
    // does not claim or validate `toggleInspector:` against the hex editor's Data Inspector.
    private lazy var previewItem: NSSplitViewItem = {
        let item = NSSplitViewItem(viewController: previewHostController)
        item.canCollapse = true
        item.isCollapsed = true
        item.minimumThickness = 220
        item.maximumThickness = 480
        item.holdingPriority = .init(260)
        return item
    }()
    private static let defaultSidebarWidth: CGFloat = 180
    private static let defaultPreviewWidth: CGFloat = 260
    /// The width to show the sidebar at: restored, or its last width before hiding.
    private var sidebarWidth = MainFrameViewController.defaultSidebarWidth
    private var wantsSidebarShown = true
    /// The width to show the preview pane at: restored, or its last width before hiding.
    private var previewWidth = MainFrameViewController.defaultPreviewWidth
    private var wantsPreviewShown = false
    private var isPlacingSidePanes = false
    private var lastNotifiedPreviewShown: Bool?
    private let statusLabel = NSTextField(labelWithString: "")
    private let trailingStatusLabel = NSTextField(labelWithString: "")
    private var token: ObservationToken?
    private var lastFocusedItemID: ItemID?
    /// Set once the divider is placed, when the window first appears.
    private var hasPlacedDivider = false
    private var restoredDividerFraction: Double?
    /// Each item's own host; items hold theirs weakly.
    private var itemHosts: [ItemID: FrontItemHost] = [:]

    /// With a `dispatcher`, the frame shows the function-key bar (docs/plans/M6.md, D-b).
    public init(
        layout: MainFrameLayout, closeCoordinator: CloseCoordinator,
        dispatcher: CommandDispatcher? = nil
    ) {
        self.layout = layout
        self.closeCoordinator = closeCoordinator
        functionKeyBar = dispatcher.map(FunctionKeyBar.init(dispatcher:))
        super.init(nibName: nil, bundle: nil)
    }

    public let functionKeyBar: FunctionKeyBar?

    /// Whether the function-key bar shows; it starts hidden (D51), and the app keeps the
    /// choice for every window.
    public var isFunctionKeyBarShown = false {
        didSet { showFunctionKeyBar() }
    }
    private var functionKeyBarHeight: NSLayoutConstraint?
    private static let functionKeyBarShownHeight: CGFloat = 24

    private func showFunctionKeyBar() {
        guard let functionKeyBar else { return }
        functionKeyBar.isHidden = !isFunctionKeyBarShown
        functionKeyBarHeight?.constant =
            isFunctionKeyBarShown ? Self.functionKeyBarShownHeight : 0
        if isFunctionKeyBarShown { functionKeyBar.update(for: viewIfLoaded?.window) }
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
            contentController.addChild(controller)
            split.addArrangedSubview(controller.view)
        }

        contentController.addChild(zoomHost)
        zoomHost.view.translatesAutoresizingMaskIntoConstraints = false
        zoomHost.view.isHidden = true

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityIdentifier("statusLine")

        trailingStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        trailingStatusLabel.textColor = .secondaryLabelColor
        trailingStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        trailingStatusLabel.alignment = .right
        trailingStatusLabel.lineBreakMode = .byTruncatingTail
        trailingStatusLabel.setContentHuggingPriority(.required, for: .horizontal)
        trailingStatusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        trailingStatusLabel.setAccessibilityIdentifier("statusTrailing")

        let titlebarSeparator = NSBox(frame: NSRect(x: 0, y: 0, width: 100, height: 1))
        titlebarSeparator.boxType = .separator
        titlebarSeparator.translatesAutoresizingMaskIntoConstraints = false
        titlebarSeparator.setAccessibilityIdentifier("titlebarSeparator")

        let contentView = contentController.view
        contentView.addSubview(split)
        contentView.addSubview(zoomHost.view)
        contentView.addSubview(titlebarSeparator)
        NSLayoutConstraint.activate([
            titlebarSeparator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titlebarSeparator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titlebarSeparator.topAnchor.constraint(
                equalTo: contentView.safeAreaLayoutGuide.topAnchor),
            titlebarSeparator.heightAnchor.constraint(equalToConstant: 1),
            split.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            split.topAnchor.constraint(equalTo: titlebarSeparator.bottomAnchor),
            split.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            zoomHost.view.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            zoomHost.view.trailingAnchor.constraint(equalTo: split.trailingAnchor),
            zoomHost.view.topAnchor.constraint(equalTo: split.topAnchor),
            zoomHost.view.bottomAnchor.constraint(equalTo: split.bottomAnchor),
        ])

        splitViewController.splitView.dividerStyle = .thin
        splitViewController.onResize = { [weak self] in self?.sidePanesDidResize() }
        splitViewController.onToggleSidebar = { [weak self] sender in
            self?.toggleSidebarShown(sender)
        }
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
        splitViewController.addSplitViewItem(previewItem)
        addChild(splitViewController)
        splitViewController.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitViewController.view)
        root.addSubview(statusLabel)
        root.addSubview(trailingStatusLabel)
        // The function-key bar sits between the panels and the status line; hidden, it
        // takes no height.
        let bar = functionKeyBar ?? NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        accessoryHolder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(accessoryHolder)
        // Empty, it takes no height; a strip's content sets it, hugging its rows.
        let barHeight = bar.heightAnchor.constraint(equalToConstant: 0)
        functionKeyBarHeight = barHeight
        showFunctionKeyBar()
        NSLayoutConstraint.activate([
            splitViewController.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitViewController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitViewController.view.topAnchor.constraint(equalTo: root.topAnchor),
            splitViewController.view.bottomAnchor.constraint(equalTo: accessoryHolder.topAnchor),
            accessoryHolder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            accessoryHolder.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            accessoryHolder.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -2),
            emptyAccessoryHeight,

            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            bar.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -2),
            barHeight,
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            trailingStatusLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 12),
            trailingStatusLabel.trailingAnchor.constraint(
                equalTo: root.trailingAnchor, constant: -8),
            trailingStatusLabel.firstBaselineAnchor.constraint(
                equalTo: statusLabel.firstBaselineAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 481),
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
        onUpdate?()
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
        if let responderView = window.firstResponder as? NSView,
            responderView.isDescendant(of: current.viewController.view)
        {
            return
        }
        let target = current.preferredFirstResponder
        window.makeFirstResponder(target ?? current.viewController.view)
    }

    public func showStatus(_ message: String) {
        showStatus(message, trailing: "")
    }

    public func showStatus(_ message: String, trailing: String) {
        statusLabel.stringValue = message
        trailingStatusLabel.stringValue = trailing
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
            withSidePanesPlaced {}
            view.layoutSubtreeIfNeeded()
            let fraction = restoredDividerFraction ?? 0.5
            split.setPosition(usableSplitWidth * fraction, ofDividerAt: 0)
        }
        lastFocusedItemID = nil
        focusCurrentItemIfChanged()
        updateOperationsToolbarItem()
    }

    // MARK: Restoration (docs/plans/M5.md, D-c)

    /// The window's tabs, panel divider, sidebar, and preview state, to save.
    public var windowState: WindowState {
        var state = layout.savedState
        state.dividerFraction = placedDividerFraction ?? restoredDividerFraction
        if sidebar != nil {
            state.sidebarShown = isSidebarShown
            state.sidebarWidth = Double(
                isSidebarShown && hasPlacedDivider
                    ? displayedSidebarWidth : sidebarWidth)
        }
        if previewPane != nil {
            state.previewShown = isPreviewPaneShown
            let shownWidth =
                isPreviewPaneShown && hasPlacedDivider && displayedPreviewWidth >= 220
                ? min(displayedPreviewWidth, 480) : previewWidth
            state.previewWidth = Double(shownWidth)
        }
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

    private var displayedSidebarWidth: CGFloat {
        splitViewController.splitView.arrangedSubviews.first?.frame.width
            ?? sidebarHostController.view.frame.width
    }

    private var displayedPreviewWidth: CGFloat {
        splitViewController.splitView.arrangedSubviews.last?.frame.width
            ?? previewHostController.view.frame.width
    }

    private func sidePanesDidResize() {
        guard hasPlacedDivider, !isPlacingSidePanes else { return }
        if sidebar != nil {
            if !sidebarItem.isCollapsed {
                let width = displayedSidebarWidth
                if width >= 120 { sidebarWidth = min(width, 400) }
            }
            if isSidebarShown != wantsSidebarShown {
                wantsSidebarShown = isSidebarShown
                if !isSidebarShown { restoreFocusIfInside(sidebarHostController.view) }
            }
        }
        if previewPane != nil {
            if !previewItem.isCollapsed {
                let width = displayedPreviewWidth
                if width >= 220 { previewWidth = min(width, 480) }
            }
            if isPreviewPaneShown != lastNotifiedPreviewShown {
                wantsPreviewShown = isPreviewPaneShown
                if !isPreviewPaneShown { restoreFocusIfInside(previewHostController.view) }
                notifyPreviewVisibilityChange()
            }
        }
        view.window?.invalidateRestorableState()
    }

    /// Puts back saved tabs, panel divider, sidebar, and preview state. Call before the
    /// window first appears: the panel divider is placed then, instead of the even split.
    public func restore(_ state: WindowState, using restorer: ItemRestorer) {
        layout.restore(state, using: restorer)
        // Saved state is data from disk: keep the fraction a fraction.
        restoredDividerFraction = state.dividerFraction.flatMap {
            $0.isFinite ? min(max($0, 0), 1) : nil
        }
        // Saved state is data from disk: a width the window can show.
        if let width = state.sidebarWidth, width.isFinite {
            sidebarWidth = min(max(CGFloat(width), 120), 400)
        }
        if let shown = state.sidebarShown {
            wantsSidebarShown = shown
            if sidebar != nil { withSidePanesPlaced { sidebarItem.isCollapsed = !shown } }
        }
        if let width = state.previewWidth, width.isFinite {
            previewWidth = min(max(CGFloat(width), 220), 480)
        }
        if let shown = state.previewShown {
            wantsPreviewShown = shown
            if previewPane != nil {
                withSidePanesPlaced { previewItem.isCollapsed = !shown }
                notifyPreviewVisibilityChange()
            }
        } else if isPreviewPaneShown {
            withSidePanesPlaced {}
        }
    }

    // MARK: The sidebar (docs/plans/M5.md, D-d)

    private let accessoryHolder = NSView()
    private lazy var emptyAccessoryHeight = accessoryHolder.heightAnchor.constraint(
        equalToConstant: 0)

    /// A view controller shown under the panels, above the function-key bar, as tall as
    /// it needs: the file operations' progress strip (docs/plans/M6.md, D-e). The app
    /// supplies it, so WorkspaceKit doesn't know what it shows.
    public var bottomAccessory: NSViewController? {
        didSet {
            oldValue?.view.removeFromSuperview()
            oldValue?.removeFromParent()
            _ = view
            emptyAccessoryHeight.isActive = bottomAccessory == nil
            guard let bottomAccessory else { return }
            addChild(bottomAccessory)
            let content = bottomAccessory.view
            content.translatesAutoresizingMaskIntoConstraints = false
            accessoryHolder.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: accessoryHolder.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: accessoryHolder.trailingAnchor),
                content.topAnchor.constraint(equalTo: accessoryHolder.topAnchor),
                content.bottomAnchor.constraint(equalTo: accessoryHolder.bottomAnchor),
            ])
        }
    }

    /// A view controller shown at the leading edge, beside the panels; the app supplies
    /// it, so WorkspaceKit doesn't know what a sidebar holds.
    public var sidebar: NSViewController? {
        didSet {
            attachSidePane(
                sidebar, replacing: oldValue, in: sidebarHostController, item: sidebarItem,
                shown: wantsSidebarShown)
        }
    }

    public var isSidebarShown: Bool { sidebar != nil && !sidebarItem.isCollapsed }

    private func attachSidePane(
        _ pane: NSViewController?, replacing oldValue: NSViewController?,
        in host: NSViewController, item: NSSplitViewItem, shown: Bool
    ) {
        oldValue?.view.removeFromSuperview()
        oldValue?.removeFromParent()
        if let pane {
            _ = view
            host.addChild(pane)
            pane.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.addSubview(pane.view)
            NSLayoutConstraint.activate([
                pane.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
                pane.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
                pane.view.topAnchor.constraint(equalTo: host.view.topAnchor),
                pane.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            ])
        }
        withSidePanesPlaced { item.isCollapsed = pane == nil || !shown }
    }

    private func withSidePanesPlaced(_ update: () -> Void) {
        let ratio = hasPlacedDivider ? placedDividerFraction : nil
        isPlacingSidePanes = true
        defer { isPlacingSidePanes = false }
        update()
        let splitView = splitViewController.splitView
        splitView.adjustSubviews()
        view.window?.layoutIfNeeded()
        let totalWidth = splitView.bounds.width
        let divider = splitView.dividerThickness
        let activeDividers = CGFloat((isSidebarShown ? 1 : 0) + (isPreviewPaneShown ? 1 : 0))
        let minContentWidth: CGFloat = 481
        var remaining = totalWidth - minContentWidth - activeDividers * divider
        var contentStart: CGFloat = 0
        if isSidebarShown {
            let reservedPreview = isPreviewPaneShown ? previewItem.minimumThickness : 0
            let maxSidebar = max(sidebarItem.minimumThickness, remaining - reservedPreview)
            let targetSidebar = min(sidebarWidth, maxSidebar)
            if totalWidth >= minContentWidth + divider + sidebarItem.minimumThickness {
                splitView.setPosition(targetSidebar, ofDividerAt: 0)
            }
            let actualSidebar =
                splitView.arrangedSubviews.first?.frame.width ?? targetSidebar
            remaining -= actualSidebar
            contentStart = actualSidebar + divider
        }
        if isPreviewPaneShown {
            let maxPreview = max(previewItem.minimumThickness, remaining)
            let targetPreview = min(previewWidth, maxPreview)
            let position = totalWidth - targetPreview - divider
            if position >= contentStart + minContentWidth {
                splitView.setPosition(position, ofDividerAt: 1)
            }
        }
        if let ratio {
            contentController.view.layoutSubtreeIfNeeded()
            if usableSplitWidth > 0 {
                split.setPosition(round(usableSplitWidth * ratio), ofDividerAt: 0)
            }
        }
    }

    /// The panel slot under `windowPoint` (in window coordinates), or nil when the point
    /// lies over the sidebar, the preview pane, or outside the panels.
    public func panelSlot(at windowPoint: NSPoint) -> SlotID? {
        guard isViewLoaded else { return nil }
        if isPreviewPaneShown, contains(windowPoint, in: previewHostController.view) {
            return nil
        }
        if isSidebarShown, contains(windowPoint, in: sidebarHostController.view) {
            return nil
        }
        if let zoomed = layout.zoomedItem {
            return contains(windowPoint, in: zoomHost.view)
                ? (layout.slot(of: zoomed.id) ?? layout.activePanel) : nil
        }
        return slotControllers.first { contains(windowPoint, in: $0.value.view) }?.key
    }

    private func contains(_ windowPoint: NSPoint, in target: NSView) -> Bool {
        !target.isHidden && target.bounds.contains(target.convert(windowPoint, from: nil))
    }

    /// Called after every redraw of the layout: a tab, the selection, or an item's title
    /// changed. The app keeps the sidebar's highlight on the active panel's folder.
    public var onUpdate: (() -> Void)?

    /// A view controller shown at the trailing edge, beside the panels; the app supplies
    /// it, so WorkspaceKit doesn't know what a preview pane holds.
    public var previewPane: NSViewController? {
        didSet {
            attachSidePane(
                previewPane, replacing: oldValue, in: previewHostController, item: previewItem,
                shown: wantsPreviewShown)
            notifyPreviewVisibilityChange()
        }
    }

    /// Whether the trailing preview pane is currently visible.
    public var isPreviewPaneShown: Bool { previewPane != nil && !previewItem.isCollapsed }

    /// Called when the preview pane is attached, restored, toggled, or collapsed/expanded by drag.
    public var onPreviewVisibilityChange: ((Bool) -> Void)?

    /// Called when the owning window is about to close so external hosts can tear down resources.
    public var onWillClose: (() -> Void)?

    // MARK: Operations popover

    private lazy var operationsPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        return popover
    }()

    /// Content controller shown inside the toolbar's anchored activity popover.
    public var operationsPopoverContent: NSViewController? {
        didSet {
            if operationsPopoverContent == nil { hideOperationsPopover() }
            operationsPopover.contentViewController = operationsPopoverContent
            updateOperationsToolbarItem()
        }
    }

    /// Visual state reflected on the toolbar's activity button.
    public var operationsIndicatorState: OperationsIndicatorState = .idle {
        didSet {
            guard operationsIndicatorState != oldValue else { return }
            updateOperationsToolbarItem()
        }
    }

    /// Whether the operations popover is currently open.
    public var isOperationsPopoverShown: Bool { operationsPopover.isShown }

    /// Called right before the user opens the popover via the toolbar button.
    public var onOperationsPopoverUserOpen: (() -> Void)?

    /// Called after the popover closes (programmatically or when the user dismisses it).
    public var onOperationsPopoverClose: (() -> Void)?

    /// Opens the operations popover anchored to the toolbar button, if attached to a window.
    public func showOperationsPopover() {
        guard operationsPopoverContent != nil, !operationsPopover.isShown,
            let window = viewIfLoaded?.window
        else { return }
        if let toolbarItem = operationsToolbarItem(in: window) {
            operationsPopover.show(relativeTo: toolbarItem)
        } else {
            let anchor = NSRect(
                x: max(view.bounds.maxX - 36, 0), y: max(view.bounds.maxY - 8, 0),
                width: 28, height: 8)
            operationsPopover.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        }
    }

    /// Closes the operations popover if it is open.
    public func hideOperationsPopover() {
        guard operationsPopover.isShown else { return }
        operationsPopover.performClose(nil)
    }

    /// Toggles the operations popover from the toolbar button.
    @objc public func toggleOperationsPopover(_ sender: Any?) {
        if operationsPopover.isShown {
            hideOperationsPopover()
        } else {
            onOperationsPopoverUserOpen?()
            showOperationsPopover()
        }
    }

    public func popoverDidClose(_ notification: Notification) {
        onOperationsPopoverClose?()
    }

    private func operationsToolbarItem(in window: NSWindow) -> NSToolbarItem? {
        window.toolbar?.items.first { $0.itemIdentifier == .toggleOperations }
    }

    private func updateOperationsToolbarItem() {
        guard let window = viewIfLoaded?.window, let item = operationsToolbarItem(in: window) else {
            return
        }
        item.image = OperationsToolbarIcon.image(for: operationsIndicatorState)
        item.toolTip = OperationsToolbarIcon.toolTip(for: operationsIndicatorState)
    }

    private func notifyPreviewVisibilityChange() {
        let shown = isPreviewPaneShown
        lastNotifiedPreviewShown = shown
        onPreviewVisibilityChange?(shown)
    }

    private func restoreFocusIfInside(_ container: NSView) {
        guard let responder = view.window?.firstResponder as? NSView,
            responder.isDescendant(of: container)
        else { return }
        lastFocusedItemID = nil
        focusCurrentItemIfChanged()
    }

    /// View › Show/Hide Preview (⇧⌘P).
    @objc public func togglePreviewPane(_ sender: Any?) {
        guard previewPane != nil else { return }
        if isPreviewPaneShown, hasPlacedDivider {
            let width = displayedPreviewWidth
            if width >= 220 { previewWidth = min(width, 480) }
        }
        wantsPreviewShown = !isPreviewPaneShown
        withSidePanesPlaced { previewItem.isCollapsed = !wantsPreviewShown }
        if !wantsPreviewShown { restoreFocusIfInside(previewHostController.view) }
        view.window?.invalidateRestorableState()
        notifyPreviewVisibilityChange()
    }

    /// View › Show/Hide Sidebar (⌃⌘S). Forwarded here from the sidebar split controller.
    @objc public func toggleSidebarShown(_ sender: Any?) {
        guard sidebar != nil else { return }
        if isSidebarShown, hasPlacedDivider {
            let width = displayedSidebarWidth
            if width >= 120 { sidebarWidth = min(width, 400) }
        }
        wantsSidebarShown = !isSidebarShown
        withSidePanesPlaced { sidebarItem.isCollapsed = !wantsSidebarShown }
        if !wantsSidebarShown { restoreFocusIfInside(sidebarHostController.view) }
        view.window?.invalidateRestorableState()
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
        case #selector(toggleSidebarShown(_:)):
            menuItem.title = isSidebarShown ? "Hide Sidebar" : "Show Sidebar"
            return sidebar != nil
        case #selector(togglePreviewPane(_:)):
            menuItem.title = isPreviewPaneShown ? "Hide Preview" : "Show Preview"
            return previewPane != nil
        case #selector(exitZoom(_:)):
            return layout.zoomedItem != nil
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return layout.zoomedItem == nil && layout.items(in: layout.activePanel).count > 1
        default:
            return true
        }
    }

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == .toggleSidebar
            || item.action == #selector(toggleSidebarShown(_:))
        {
            item.toolTip = isSidebarShown ? "Hide Sidebar" : "Show Sidebar"
            return sidebar != nil
        }
        if item.itemIdentifier == .toggleOperations
            || item.action == #selector(toggleOperationsPopover(_:))
        {
            item.toolTip = OperationsToolbarIcon.toolTip(for: operationsIndicatorState)
            return operationsPopoverContent != nil
        }
        if item.itemIdentifier == .togglePreviewPane
            || item.action == #selector(togglePreviewPane(_:))
        {
            item.toolTip = isPreviewPaneShown ? "Hide Preview" : "Show Preview"
            return previewPane != nil
        }
        return true
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

    /// The narrowest a panel gets.
    private static let minimumWidth: CGFloat = 240

    override func loadView() {
        // The split view sizes its panels by frame, through autoresizing constraints; a
        // panel that started at zero size would contradict its own minimums until then.
        let root = NSView(
            frame: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: TabBarView.height))
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
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth),
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
        showStatus(message, trailing: "")
    }

    func showStatus(_ message: String, trailing: String) {
        guard let frame, frame.isInFront(itemID) else { return }
        frame.showStatus(message, trailing: trailing)
    }
}

@MainActor
@MainActor
final class SidebarSplitView: NSSplitView {
    /// Clips the trailing preview-pane divider so it starts below the unified toolbar
    /// rather than cutting through the titlebar; the leading sidebar divider stays full height.
    func clippedDividerRect(for rect: NSRect) -> NSRect {
        guard isVertical, arrangedSubviews.count >= 3,
            !arrangedSubviews[2].isHidden,
            rect.minX >= arrangedSubviews[1].frame.maxX - 1
        else { return rect }
        let top = safeAreaInsets.top
        guard top > 0, rect.height > top else { return rect }
        return NSRect(
            x: rect.minX, y: rect.minY + top, width: rect.width, height: rect.height - top)
    }

    override func drawDivider(in rect: NSRect) {
        super.drawDivider(in: clippedDividerRect(for: rect))
    }
}

private final class SidebarSplitViewController: NSSplitViewController {
    var onResize: (() -> Void)?
    var onToggleSidebar: ((Any?) -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
        let custom = SidebarSplitView()
        custom.isVertical = true
        splitView = custom
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        onResize?()
    }

    @objc override func toggleSidebar(_ sender: Any?) {
        onToggleSidebar?(sender)
    }
}

@MainActor
private final class ContainerViewController: NSViewController {
    override func loadView() { view = NSView() }
}
