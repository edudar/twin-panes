import AppKit
import BrowserKit
import EditorKit
import WorkspaceKit

extension SmokeTest {
    /// Selecting several rows and the function-key bar in the real window
    /// (docs/plans/M6.md, D-a and D-b, step 4). The browser shows the sample folder:
    /// "..", "sub" and "data.bin".
    func selectionAndFunctionKeys(
        _ check: (Bool, String) -> Void, browser: BrowserItem, table: NSTableView,
        controller: MainWindowController
    ) async {
        guard let window = controller.window,
            let bar = controller.frameController.functionKeyBar
        else { return check(false, "the window has a function-key bar") }
        window.makeFirstResponder(table)
        table.selectRowIndexes([1], byExtendingSelection: false)
        sendArrowDown(extending: true, to: window)
        check(
            browser.selectedEntries.map(\.name) == ["sub", "data.bin"],
            "⇧↓ extends the selection: \(browser.selectedEntries.map(\.name))")
        check(
            status(of: controller).contains("2 of 2 selected"),
            "the status line counts the selection: \(status(of: controller))")
        table.selectRowIndexes([0], byExtendingSelection: false)
        check(selectAll(in: window), "Edit › Select All (⌘A) reaches the file list")
        check(
            !table.selectedRowIndexes.contains(0) && browser.selectedEntries.count == 2,
            "⌘A selects every entry but \"..\": rows \(Array(table.selectedRowIndexes))")

        window.update()
        check(button(3, of: bar)?.title == "F3 View", "the bar's F3 reads View in a browser")
        check(button(10, of: bar)?.title == "F10 Quit Twin Panes", "and F10 quits")
        table.selectRowIndexes([2], byExtendingSelection: false)
        window.update()
        button(3, of: bar)?.performClick(nil)
        let editors = app.workspace.allItems.compactMap { $0 as? HexEditorItem }
        check(
            editors.contains { $0.url.lastPathComponent == "data.bin" },
            "clicking the bar's F3 opens the selected file")
        if let editor = editors.first {
            window.makeFirstResponder(editor.preferredFirstResponder)
            window.update()
            check(
                button(3, of: bar)?.title == "F3 Find Next",
                "in an editor the bar's F3 reads Find Next: \(button(3, of: bar)?.title ?? "")")
        }
        for editor in editors {
            editor.willClose()
            controller.layout.remove(editor.id)
        }
        controller.layout.select(browser.id)
        window.makeFirstResponder(table)

        await hideFunctionKeys(check, browser: browser, bar: bar, window: window)
    }

    /// View › Hide Function Keys gives the panels the bar's room, in every window.
    private func hideFunctionKeys(
        _ check: (Bool, String) -> Void, browser: BrowserItem, bar: FunctionKeyBar,
        window: NSWindow
    ) async {
        func browserHeight() -> CGFloat {
            window.contentView?.layoutSubtreeIfNeeded()
            return browser.viewController.view.frame.height
        }
        let shown = browserHeight()
        NSApp.sendAction(Selector(("toggleFunctionKeys:")), to: nil, from: nil)
        let hidden = browserHeight()
        check(
            bar.isHidden && hidden >= shown + 20
                && app.windowControllers.allSatisfy {
                    $0.frameController.functionKeyBar?.isHidden == true
                },
            "hiding the function keys gives the panels the room: \(Int(shown)) → \(Int(hidden)) pt")
        NSApp.sendAction(Selector(("toggleFunctionKeys:")), to: nil, from: nil)
        check(!bar.isHidden && browserHeight() == shown, "and showing them takes it back")
    }

    private func button(_ number: Int, of bar: FunctionKeyBar) -> NSButton? {
        Self.view(in: bar, id: "functionKey\(number)") as? NSButton
    }

    /// ⇧↓ as the keyboard sends it, to the window as AppKit hands a key window its keys.
    private func sendArrowDown(extending: Bool, to window: NSWindow) {
        let key = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: extending
                    ? [.shift, .numericPad, .function] : [.numericPad, .function],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 125)
        else { return }
        window.sendEvent(event)
    }

    /// Edit › Select All, the menu item ⌘A triggers, sent to this window's first
    /// responder. The menu sends it to the key window, and the inactive smoke app has
    /// none (`NSApp.keyWindow` is nil), so this window stands in for it.
    private func selectAll(in window: NSWindow) -> Bool {
        let item = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first {
            $0.keyEquivalent == "a" && $0.keyEquivalentModifierMask == .command
        }
        guard let item, let action = item.action else { return false }
        return NSApp.sendAction(action, to: window.firstResponder, from: item)
    }
}
