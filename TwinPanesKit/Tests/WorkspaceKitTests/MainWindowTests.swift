import AppKit
import Testing

@testable import WorkspaceKit

/// Minimal `NSDraggingInfo` carrying a single pasteboard for drag-and-drop tests.
@MainActor
private final class StubDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint = .zero
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any?
    var draggingSequenceNumber: Int = 0
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    var springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(urls: [URL]) {
        let board = NSPasteboard(name: .init("MainWindowTests-\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects(urls as [NSURL])
        draggingPasteboard = board
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}

@MainActor
private final class ScopedResponderView: NSView, CommandScopeProviding, NSMenuItemValidation {
    let commandScopes: [BindingScope]
    var innerEnabled = true
    var innerCount = 0
    var outerCount = 0

    init(scopes: [BindingScope]) {
        commandScopes = scopes
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    @objc func innerAction(_ sender: Any?) { innerCount += 1 }
    @objc func outerAction(_ sender: Any?) { outerCount += 1 }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(innerAction(_:)) { return innerEnabled }
        return true
    }
}

@MainActor
@Suite struct MainWindowTests {
    func makeWindow() -> MainWindow {
        MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
    }

    func keyDown(_ chars: String, _ flags: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)!
    }

    @Test func exposesDraggingDestinationSelectorsToAppKit() {
        let window = makeWindow()
        let url = URL(fileURLWithPath: "/tmp/sample.bin")
        let info = StubDraggingInfo(urls: [url])
        var received: [URL] = []
        window.onDropFiles = { received = $0 }
        // AppKit invokes dragging methods through Objective-C message dispatch, not Swift
        // vtable dispatch; without `@objc` / `NSDraggingDestination`, `MainWindow`'s
        // overrides are invisible to AppKit.
        let destination = window as AnyObject
        #expect(destination is NSDraggingDestination)
        let performed = (destination as? NSDraggingDestination)?.performDragOperation?(info)
        #expect(performed == true)
        #expect(received == [url])
    }

    @Test func acceptsAndDeliversDroppedFileURLs() {
        let window = makeWindow()
        let url = URL(fileURLWithPath: "/tmp/sample.bin")
        let info = StubDraggingInfo(urls: [url])
        #expect(window.draggingEntered(info) == [])

        var received: [URL] = []
        window.onDropFiles = { received = $0 }
        #expect(window.draggingEntered(info) == .copy)
        #expect(window.performDragOperation(info))
        #expect(received == [url])
    }

    @Test func dispatcherFallsBackWhenInnerCandidateIsDisabled() {
        let registry = CommandRegistry()
        registry.register(
            Command("inner", title: "Inner", action: #selector(ScopedResponderView.innerAction(_:)))
        )
        registry.register(
            Command("outer", title: "Outer", action: #selector(ScopedResponderView.outerAction(_:)))
        )
        let innerScope = BindingScope.item("editor", part: "inner")
        let outerScope = BindingScope.item("editor")
        registry.bind(.escape, to: "inner", in: innerScope)
        registry.bind(.escape, to: "outer", in: outerScope)

        let window = makeWindow()
        let dispatcher = CommandDispatcher(registry: registry)
        let outer = ScopedResponderView(scopes: [outerScope])
        let inner = ScopedResponderView(scopes: [innerScope])
        outer.addSubview(inner)
        window.contentView = outer
        _ = window.makeFirstResponder(inner)

        let esc = keyDown("\u{1b}", [], in: window)
        #expect(dispatcher.handle(esc, in: window))
        #expect(inner.innerCount == 1 && inner.outerCount == 0)

        inner.innerEnabled = false
        #expect(dispatcher.handle(esc, in: window))
        #expect(inner.innerCount == 1 && inner.outerCount == 1)
    }

    @Test func focusChainAndMenuUpdaterFollowFirstResponder() {
        let registry = CommandRegistry()
        let scopeA = BindingScope.item("editor")
        registry.register(
            Command("a", title: "Action A", action: #selector(ScopedResponderView.innerAction(_:))))
        registry.bind(KeyChord("k", .command), to: "a", in: scopeA)

        let window = makeWindow()
        let root = ScopedResponderView(scopes: [scopeA])
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        root.addSubview(field)
        window.contentView = root

        // With window as first responder, FocusChain falls back to contentView.
        #expect(FocusChain.scopes(in: window) == [scopeA, .app])

        let updater = MenuBindingUpdater(registry: registry)
        let menu = NSMenu()
        let item = updater.menuItem(for: "a")
        menu.addItem(item)
        #expect(item.keyEquivalent == "")  // not bound in .app alone

        var focusEvents = 0
        window.onFocusChange = { w in
            focusEvents += 1
            updater.refresh(menu, for: w)
        }
        _ = window.makeFirstResponder(field)
        #expect(focusEvents >= 1)
        #expect(FocusChain.scopes(in: window).contains(scopeA))
        #expect(item.keyEquivalent == "k")
        #expect(item.keyEquivalentModifierMask == .command)
    }

    @Test func performKeyEquivalentAndSendEventDoNotDoubleDispatch() {
        let registry = CommandRegistry()
        registry.register(
            Command("act", title: "Act", action: #selector(ScopedResponderView.innerAction(_:))))
        let scope = BindingScope.item("editor")
        registry.bind(KeyChord("k", .command), to: "act", in: scope)

        let window = makeWindow()
        let view = ScopedResponderView(scopes: [scope])
        view.innerEnabled = false
        window.contentView = view
        _ = window.makeFirstResponder(view)
        window.dispatcher = CommandDispatcher(registry: registry)

        let event = keyDown("k", .command, in: window)
        #expect(window.performKeyEquivalent(with: event) == false)
        // Re-enabling before sendEvent proves sendEvent skips the already-checked event.
        view.innerEnabled = true
        window.sendEvent(event)
        #expect(view.innerCount == 0)
    }
}
