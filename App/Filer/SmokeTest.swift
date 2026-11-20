import AppKit
import WorkspaceKit

/// `Filer --smoke-test`: drives the real app (signed, sandboxed) through the M0 checks
/// and exits 0 on success, 1 on failure. Run by CI on each supported macOS.
///
/// Checks: two independent main windows; F3 resolving to different commands in a
/// browser and an editor, and actually reaching the right responder; Tab bound only in
/// the file list; zoom; the close workflow prompting once per session across windows.
@MainActor
struct SmokeTest {
    let app: AppDelegate

    func run() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            print("SMOKE FAIL: timed out")
            exit(1)
        }
        Task { @MainActor in
            var failures: [String] = []
            func check(_ condition: Bool, _ message: String) {
                print(condition ? "  ok   \(message)" : "  FAIL \(message)")
                if !condition { failures.append(message) }
            }
            await body(check)
            print(failures.isEmpty ? "SMOKE OK" : "SMOKE FAIL: \(failures.count) check(s)")
            exit(failures.isEmpty ? 0 : 1)
        }
    }

    private func body(_ check: (Bool, String) -> Void) async {
        print("Filer smoke test — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print(
            "  sandboxed: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)"
        )

        // Two windows, each with its own layout.
        let first = app.openMainWindow()
        let second = app.openMainWindow()
        check(app.workspace.allLayouts.count == 2, "two main windows registered")
        check(first.layout !== second.layout, "each window has its own layout")
        await settle()

        // Browser focus: F3 → browser.view, Tab → browser.switchPanel.
        guard let window = first.window,
            let browser = first.layout.focusedPanelItem as? PlaceholderBrowserItem
        else {
            check(false, "first window shows a browser")
            return
        }
        window.makeFirstResponder(browser.preferredFirstResponder)
        var chain = FocusChain.scopes(in: window)
        check(
            chain.first == .item(.browser, part: "fileList"),
            "file list is innermost scope (\(chain))")
        check(resolve(.function(3), chain) == .browserView, "F3 in browser → browser.view")
        check(resolve(.tab, chain) == .browserSwitchPanel, "Tab in file list → browser.switchPanel")
        check(dispatch(.function(3), in: window), "F3 dispatched in browser")
        check(
            status(of: first).contains("browser.view"), "browser handled F3: \(status(of: first))")

        // Search field inside the browser: Tab must fall through to the key-view loop.
        if let search = (browser.viewController as? PlaceholderBrowserViewController)?.searchField {
            window.makeFirstResponder(search)
            chain = FocusChain.scopes(in: window)
            check(resolve(.tab, chain) == nil, "Tab in search field is not intercepted")
            check(resolve(.function(3), chain) == .browserView, "F3 in search field → browser.view")
        }

        // Editor focus: same key, different command.
        let session = app.makeEditorSession()
        let editor = session.makeView()
        first.layout.insert(editor)
        await settle()
        window.makeFirstResponder(editor.preferredFirstResponder)
        chain = FocusChain.scopes(in: window)
        check(resolve(.function(3), chain) == .editorFindNext, "F3 in editor → editor.findNext")
        check(resolve(.tab, chain) == nil, "Tab in editor is not intercepted")
        check(dispatch(.function(3), in: window), "F3 dispatched in editor")
        check(
            status(of: first).contains("editor.findNext"), "editor handled F3: \(status(of: first))"
        )

        // Zoom.
        check(dispatch(KeyChord("\r", [.command, .shift]), in: window), "⇧⌘↩ dispatched")
        check(first.layout.zoomedItemID == editor.id, "editor zoomed")
        check(dispatch(.escape, in: window), "Esc dispatched while zoomed")
        check(first.layout.zoomedItemID == nil, "zoom cleared")
        check(!dispatch(.escape, in: window), "Esc falls through when not zoomed")

        // Close workflow across windows: a second view of the session in window two.
        session.textStorage.append(NSAttributedString(string: "edit"))
        check(editor.isDirty, "editing makes the session dirty")
        let secondView = session.makeView()
        second.layout.insert(secondView)
        check(
            app.closeCoordinator.dirtySessions(closing: [editor]).isEmpty,
            "no prompt while another window still shows the session")
        check(
            app.closeCoordinator.dirtySessions(closing: [editor, secondView]).count == 1,
            "one prompt when both views close")
        check(
            app.closeCoordinator.dirtySessions(closing: app.workspace.allItems).count == 1,
            "quit prompts once per dirty session")
        session.setDirty(false)

        // Menu shows the binding for the current focus.
        let viewMenu = NSApp.mainMenu?.item(withTitle: "View")?.submenu
        if let viewMenu {
            window.makeFirstResponder(editor.preferredFirstResponder)
            app.menuUpdater.refresh(viewMenu, for: window)
            let findNext = viewMenu.items.first {
                $0.action == #selector(FilerActions.editorFindNext(_:))
            }
            let browserView = viewMenu.items.first {
                $0.action == #selector(FilerActions.browserView(_:))
            }
            check(
                findNext?.keyEquivalent == KeyChord.function(3).key,
                "menu shows F3 on Find Next in editor")
            check(browserView?.keyEquivalent == "", "menu shows no key on View in editor")
        } else {
            check(false, "View menu exists")
        }

        first.closeWithoutAsking()
        second.closeWithoutAsking()
        await settle()
        check(app.workspace.allLayouts.isEmpty, "closed windows unregister their layouts")
    }

    private func resolve(_ chord: KeyChord, _ chain: [BindingScope]) -> CommandID? {
        app.registry.candidates(for: chord, chain: chain).first?.id
    }

    /// Sends a synthetic key-down through the dispatcher, as `MainWindow` would.
    private func dispatch(_ chord: KeyChord, in window: NSWindow) -> Bool {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: chord.menuKeyEquivalent.mask,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: chord.key,
                charactersIgnoringModifiers: chord.key, isARepeat: false, keyCode: 0)
        else { return false }
        return app.dispatcher.handle(event, in: window)
    }

    private func status(of controller: MainWindowController) -> String {
        controller.frameController.view.subviews.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "statusLine" }?.stringValue ?? ""
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }
}
