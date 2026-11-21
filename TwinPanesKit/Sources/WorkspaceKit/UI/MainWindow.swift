import AppKit

/// The main window. Offers every key-down to the command dispatcher before the main
/// menu and the responder chain see it (PLAN.md §4.11).
@MainActor
public final class MainWindow: NSWindow {
    public var dispatcher: CommandDispatcher?

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let dispatcher, dispatcher.handle(event, in: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let dispatcher, dispatcher.handle(event, in: self) {
            return
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

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDropFiles != nil && !fileURLs(sender).isEmpty ? .copy : []
    }

    public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard let onDropFiles, !urls.isEmpty else { return false }
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
            layout: layout, closeCoordinator: closeCoordinator)
        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Twin Panes"
        window.tabbingMode = .disallowed  // per-panel tabs, not system window tabs (§4.9)
        window.dispatcher = dispatcher
        window.contentViewController = frameController
        window.setContentSize(NSSize(width: 900, height: 600))
        super.init(window: window)
        window.delegate = self
        workspace.register(layout)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Closes the window without asking (used after the app-level quit workflow ran).
    public func closeWithoutAsking() {
        closeApproved = true
        window?.close()
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeApproved { return true }
        let items = layout.allItems
        if closeCoordinator.dirtySessions(closing: items).isEmpty { return true }
        Task {
            if await closeCoordinator.confirmClose(items) {
                closeWithoutAsking()
            }
        }
        return false
    }

    public func windowWillClose(_ notification: Notification) {
        workspace.unregister(layout)
        for item in layout.allItems {
            item.host = nil
            item.onChange = nil
        }
        onClose?(self)
    }
}
