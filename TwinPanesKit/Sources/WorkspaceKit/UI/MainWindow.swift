import AppKit

/// The main window. Offers every key-down to the command dispatcher before the main
/// menu and the responder chain see it (PLAN.md §4.11).
@MainActor
public final class MainWindow: NSWindow, NSDraggingDestination {
    public var dispatcher: CommandDispatcher?
    /// Called whenever this window becomes key or its first responder changes, so menus
    /// can refresh focus-dependent key equivalents (PLAN.md §4.11).
    public var onFocusChange: ((NSWindow) -> Void)?
    /// Called with the new first responder whenever it changes; the main frame follows
    /// it to the panel it's in (docs/plans/M5.md, D-b).
    public var onFirstResponderChange: ((NSResponder?) -> Void)?
    private var lastHandledKeyEvent: NSEvent?

    public override func becomeKey() {
        super.becomeKey()
        onFocusChange?(self)
    }

    public override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let changed = super.makeFirstResponder(responder)
        if changed {
            onFirstResponderChange?(firstResponder)
            onFocusChange?(self)
        }
        return changed
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event !== lastHandledKeyEvent {
            lastHandledKeyEvent = event
            if let dispatcher, dispatcher.handle(event, in: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event !== lastHandledKeyEvent {
            lastHandledKeyEvent = event
            if let dispatcher, dispatcher.handle(event, in: self) { return }
        }
        super.sendEvent(event)
    }

    // MARK: Dropping files

    /// Called with file URLs dropped anywhere on the window (that no view took first).
    public var onDropFiles: (([URL]) -> Void)? {
        didSet {
            if onDropFiles != nil { registerForDraggedTypes([.fileURL]) }
        }
    }
    /// Called with file URLs dropped onto a specific panel slot.
    public var onDropFilesInSlot: (([URL], SlotID) -> Void)? {
        didSet {
            if onDropFilesInSlot != nil { registerForDraggedTypes([.fileURL]) }
        }
    }
    /// Maps a window-coordinate drop point to its target panel slot, or nil to reject
    /// drops outside the panels (such as over the preview pane or sidebar).
    public var dropSlotForPoint: ((NSPoint) -> SlotID?)?

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func dragOperation(for info: NSDraggingInfo) -> NSDragOperation {
        guard (onDropFilesInSlot != nil && dropSlotForPoint != nil) || onDropFiles != nil,
            !fileURLs(info).isEmpty
        else { return [] }
        if let dropSlotForPoint, dropSlotForPoint(info.draggingLocation) == nil { return [] }
        return .copy
    }

    public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        if let dropSlotForPoint {
            guard let slot = dropSlotForPoint(sender.draggingLocation) else { return false }
            if let onDropFilesInSlot {
                onDropFilesInSlot(urls, slot)
                return true
            }
        }
        guard let onDropFiles else { return false }
        onDropFiles(urls)
        return true
    }
}

/// Owns one main window and its layout; runs the close workflow before the window
/// closes.
@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate {
    public let layout: MainFrameLayout
    public let frameController: MainFrameViewController
    private let closeCoordinator: CloseCoordinator
    private let workspace: WorkspaceRegistry
    private var closeApproved = false

    /// Called after the window has closed and its layout is unregistered.
    public var onClose: ((MainWindowController) -> Void)?

    public init(
        layout: MainFrameLayout, workspace: WorkspaceRegistry, dispatcher: CommandDispatcher,
        closeCoordinator: CloseCoordinator
    ) {
        self.layout = layout
        self.workspace = workspace
        self.closeCoordinator = closeCoordinator
        frameController = MainFrameViewController(
            layout: layout, closeCoordinator: closeCoordinator, dispatcher: dispatcher)
        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Twin Panes"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.toolbar = MainToolbar()
        window.tabbingMode = .disallowed  // per-panel tabs, not system window tabs (§4.9)
        window.dispatcher = dispatcher
        window.contentViewController = frameController
        window.setContentSize(NSSize(width: 1120, height: 700))
        super.init(window: window)
        window.delegate = self
        window.onFirstResponderChange = { [weak frameController] responder in
            frameController?.followFocus(to: responder)
        }
        window.dropSlotForPoint = { [weak frameController] point in
            frameController?.panelSlot(at: point)
        }
        workspace.register(layout)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Closes the window without asking (used after the app-level quit workflow ran).
    public func closeWithoutAsking() {
        closeApproved = true
        window?.close()
    }

    /// AppKit saves the window's restorable state; the layout invalidates it on changes.
    public func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        // Encoding plain values doesn't fail; if it did, the window would only come
        // back with the default tabs.
        try? frameController.windowState.encode(into: state)
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeApproved { return true }
        let items = layout.allItems
        if closeCoordinator.dirtySessions(closing: items).isEmpty,
            !items.contains(where: \.isSaving)
        {
            return true
        }
        Task {
            if await closeCoordinator.confirmClose(items) {
                closeWithoutAsking()
            }
        }
        return false
    }

    public func windowWillClose(_ notification: Notification) {
        frameController.hideOperationsPopover()
        workspace.unregister(layout)
        for item in layout.allItems {
            item.willClose()
            item.host = nil
            item.onChange = nil
        }
        frameController.onWillClose?()
        onClose?(self)
    }
}

/// The main window's unified toolbar. Uses standard system identifiers so AppKit adapts
/// its appearance (including Liquid Glass on macOS 26+) automatically.
@MainActor
private final class MainToolbar: NSToolbar, NSToolbarDelegate {
    init() {
        super.init(identifier: "MainToolbar")
        delegate = self
        displayMode = .iconOnly
        allowsUserCustomization = false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, .toggleOperations, .togglePreviewPane]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, .toggleOperations, .togglePreviewPane]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar:
            makeToggleItem(
                .toggleSidebar, label: "Sidebar", palette: "Toggle Sidebar",
                toolTip: "Show or hide the sidebar", symbol: "sidebar.leading",
                action: #selector(MainFrameViewController.toggleSidebarShown(_:)))
        case .toggleOperations:
            makeToggleItem(
                .toggleOperations, label: "Activity", palette: "Toggle Activity",
                toolTip: "Show Activity", symbol: "arrow.up.arrow.down.circle",
                action: #selector(MainFrameViewController.toggleOperationsPopover(_:)))
        case .togglePreviewPane:
            makeToggleItem(
                .togglePreviewPane, label: "Preview", palette: "Toggle Preview",
                toolTip: "Show or hide the preview pane", symbol: "sidebar.trailing",
                action: #selector(MainFrameViewController.togglePreviewPane(_:)))
        default:
            nil
        }
    }

    private func makeToggleItem(
        _ id: NSToolbarItem.Identifier, label: String, palette: String, toolTip: String,
        symbol: String, action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = palette
        item.toolTip = toolTip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: palette)
        item.isBordered = true
        item.target = nil
        item.action = action
        return item
    }
}
