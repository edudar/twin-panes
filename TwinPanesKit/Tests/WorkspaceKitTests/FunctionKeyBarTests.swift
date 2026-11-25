import AppKit
import Testing

@testable import WorkspaceKit

/// The F-key bar follows focus and sends its commands (docs/plans/M6.md, D-b, step 3).
@MainActor
@Suite struct FunctionKeyBarTests {
    let browserScope = BindingScope.item("browser")
    let editorScope = BindingScope.item("editor")
    let registry = CommandRegistry()

    init() {
        registry.register(Command("view", title: "View", action: #selector(KeyTarget.view(_:))))
        registry.register(
            Command("findNext", title: "Find Next", action: #selector(KeyTarget.findNext(_:))))
        registry.register(Command("quit", title: "Quit", action: #selector(KeyTarget.quit(_:))))
        registry.bind(.function(3), to: "view", in: browserScope)
        registry.bind(.function(3), to: "findNext", in: editorScope)
        registry.bind(.function(10), to: "quit")
    }

    func makeWindow(_ views: [KeyTarget]) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
            backing: .buffered, defer: true)
        let root = NSView()
        for view in views { root.addSubview(view) }
        window.contentView = root
        return window
    }

    @Test func labelsFollowTheFocusedScope() {
        let browser = KeyTarget(scopes: [browserScope])
        let editor = KeyTarget(scopes: [editorScope])
        let window = makeWindow([browser, editor])
        let bar = FunctionKeyBar(dispatcher: CommandDispatcher(registry: registry))
        _ = window.makeFirstResponder(browser)
        bar.update(for: window)
        #expect(bar.title(ofKey: 3) == "View")
        #expect(bar.title(ofKey: 10) == "Quit")
        #expect(bar.title(ofKey: 5) == "" && !bar.isEnabled(key: 5))
        _ = window.makeFirstResponder(editor)
        bar.update(for: window)
        #expect(bar.title(ofKey: 3) == "Find Next")
    }

    @Test func aKeySendsItsCommandToTheFocusedResponder() {
        let browser = KeyTarget(scopes: [browserScope])
        let window = makeWindow([browser])
        let bar = FunctionKeyBar(dispatcher: CommandDispatcher(registry: registry))
        window.contentView?.addSubview(bar)
        _ = window.makeFirstResponder(browser)
        bar.update(for: window)
        bar.press(key: 3)
        #expect(browser.calls == ["view"])
    }

    @Test func aKeyIsEnabledByTheMenusValidation() {
        let browser = KeyTarget(scopes: [browserScope])
        browser.disabled = [#selector(KeyTarget.view(_:))]
        let window = makeWindow([browser])
        let bar = FunctionKeyBar(dispatcher: CommandDispatcher(registry: registry))
        _ = window.makeFirstResponder(browser)
        bar.update(for: window)
        #expect(bar.title(ofKey: 3) == "View" && !bar.isEnabled(key: 3))
        bar.press(key: 3)
        #expect(browser.calls.isEmpty)
    }

    @Test func theFrameShowsAndHidesTheBar() {
        let layout = MainFrameLayout(filler: .testBrowsers)
        layout.fillEmptyPanels()
        let frame = MainFrameViewController(
            layout: layout, closeCoordinator: CloseCoordinator(openItems: { [] }) { _ in .discard },
            dispatcher: CommandDispatcher(registry: registry))
        _ = frame.view
        #expect(frame.isFunctionKeyBarShown)
        #expect(frame.functionKeyBar?.isHidden == false)
        frame.isFunctionKeyBarShown = false
        #expect(frame.functionKeyBar?.isHidden == true)
    }
}

final class KeyTarget: NSView, CommandScopeProviding, NSMenuItemValidation {
    let commandScopes: [BindingScope]
    var calls: [String] = []
    var disabled: Set<Selector> = []

    init(scopes: [BindingScope]) {
        commandScopes = scopes
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    @objc func view(_ sender: Any?) { calls.append("view") }
    @objc func findNext(_ sender: Any?) { calls.append("findNext") }
    @objc func quit(_ sender: Any?) { calls.append("quit") }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        !disabled.contains(menuItem.action ?? #selector(view(_:)))
    }
}
