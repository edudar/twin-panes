import AppKit
import BrowserKit
import WorkspaceKit

extension SmokeTest {
    /// Two panels, always (docs/plans/M5.md, D-a): a new window shows a browser in each
    /// panel, a panel's only browser can't be closed, and closing a panel's last other tab
    /// leaves a browser at the other panel's folder.
    func twoPanels(_ check: (Bool, String) -> Void, in controller: MainWindowController) async {
        let layout = controller.layout
        guard let window = controller.window, let content = window.contentView,
            let left = layout.selectedItem(in: .leftPanel) as? BrowserItem,
            let right = layout.selectedItem(in: .rightPanel) as? BrowserItem
        else {
            check(false, "a new window shows a browser in each panel")
            return
        }
        check(right.folder == left.folder, "the right panel starts in the left panel's folder")
        let widths = [SlotID.leftPanel, .rightPanel].map { slot in
            Self.view(in: content, id: slot.rawValue).map { $0.isHidden ? 0 : $0.frame.width } ?? 0
        }
        check(
            widths[0] >= 240 && abs(widths[0] - widths[1]) <= 1,
            "both panels are shown as equal halves: \(widths.map { Int($0) }) pt")

        window.makeFirstResponder(left.preferredFirstResponder)
        check(
            !dispatch(KeyChord("w", .command), in: window),
            "⌘W is disabled on a panel's only browser")
        check(layout.items(in: .leftPanel).map(\.id) == [left.id], "the panel's only browser stays")

        // Clicking into a panel makes it the active one (D-b). Home needs a grant the
        // smoke test doesn't have, so the lists show the temporary folder instead.
        for browser in [left, right] {
            browser.go(to: FileManager.default.temporaryDirectory)
            await browser.listed()
        }
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        for (panel, browser) in [(SlotID.rightPanel, right), (.leftPanel, left)] {
            guard let list = browser.preferredFirstResponder else { continue }
            click(list, in: window)
            await settle()
            check(
                layout.activePanel == panel && window.firstResponder === list,
                "clicking into the \(panel.rawValue)'s file list makes it the active panel")
        }

        // Tab and ⇧Tab in a file list switch panels, as real key events (D-b).
        let switches = [("Tab", KeyChord.tab, right), ("⇧Tab", KeyChord("\t", .shift), left)]
        for (name, chord, target) in switches {
            check(dispatch(chord, in: window), "\(name) in a file list is dispatched")
            check(
                layout.focusedPanelItem === target
                    && window.firstResponder === target.preferredFirstResponder,
                "\(name) switches to the other panel's file list")
        }

        layout.insert(app.makeEditorSession().makeView(), in: .rightPanel)
        controller.frameController.closeItem(right.id)
        await settle()
        check(
            layout.items(in: .rightPanel).map(\.kind) == [.editor],
            "a panel's browser closes while the panel has another tab")
        check(dispatch(KeyChord("w", .command), in: window), "⌘W closes a panel's last editor")
        await settle()
        let replacement = layout.items(in: .rightPanel).first as? BrowserItem
        check(
            layout.items(in: .rightPanel).count == 1 && replacement?.folder == left.folder,
            "closing a panel's last editor leaves a browser at the other panel's folder")

        // Window › Move Tab to Other Panel moves the same item (D-b).
        guard let moveTab = app.registry.command(.moveTabToOtherPanel) else {
            return check(false, "Move Tab to Other Panel is a command")
        }
        let moved = app.makeEditorSession().makeView()
        layout.insert(moved, in: .leftPanel)
        check(app.dispatcher.perform(moveTab, in: window), "Move Tab to Other Panel runs")
        check(
            layout.slot(of: moved.id) == .rightPanel && layout.focusedPanelItem === moved,
            "Move Tab to Other Panel moves the tab and activates its new panel")
        layout.activate(.leftPanel)
        check(
            !app.dispatcher.perform(moveTab, in: window),
            "Move Tab to Other Panel is disabled for a panel's only browser")
        controller.frameController.closeItem(moved.id)
        await settle()
    }

    /// Clicks the middle of `view`'s visible part with real mouse events. The mouse-up is
    /// queued first: a table's mouse-down tracks the mouse until it sees one.
    func click(_ view: NSView, in window: NSWindow) {
        let visible = view.visibleRect
        let point = view.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
    }
}
