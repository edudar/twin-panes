import AppKit
import BrowserKit
import Darwin
import EditorKit
import TwinPanesCore
import WorkspaceKit

extension SmokeTest {
    /// M7 integration checks (docs/plans/M7.md): collapsible preview pane, Quick Look vs hex
    /// auto-selection, pinning, F3 / ⇧F3 Quick View, active-panel F4, live dirty-session sync,
    /// and a 1,000-file cursor sweep creating zero EditorSessions under the stall gate.
    func previewAndQuickView(
        _ check: (Bool, String) -> Void, in controller: MainWindowController
    )
        async
    {
        guard let window = controller.window,
            let leftBrowser = controller.layout.selectedItem(in: .leftPanel) as? BrowserItem,
            let rightBrowser = controller.layout.selectedItem(in: .rightPanel) as? BrowserItem,
            let leftTable = leftBrowser.preferredFirstResponder as? NSTableView,
            let rightTable = rightBrowser.preferredFirstResponder as? NSTableView,
            let preview = controller.frameController.previewPane as? PreviewPaneViewController
        else { return check(false, "window has both browsers and a preview pane") }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-preview-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        guard makePreviewFixtures(in: tempRoot) else {
            return check(false, "create preview smoke fixtures")
        }

        let savedLeft = leftBrowser.folder
        let savedRight = rightBrowser.folder
        defer {
            if controller.frameController.isPreviewPaneShown {
                _ = dispatch(KeyChord("p", [.command, .shift]), in: window)
            }
            for item in controller.layout.allItems
            where item is QuickViewItem || item is HexEditorItem {
                item.willClose()
                controller.layout.remove(item.id)
            }
            controller.layout.select(leftBrowser.id)
            leftBrowser.go(to: savedLeft)
            rightBrowser.go(to: savedRight)
        }

        leftBrowser.go(to: tempRoot)
        await leftBrowser.listed()
        rightBrowser.go(to: tempRoot)
        await rightBrowser.listed()
        controller.layout.select(leftBrowser.id)
        window.makeFirstResponder(leftTable)

        await previewPaneChecks(
            check, browser: leftBrowser, table: leftTable, preview: preview,
            controller: controller, window: window)
        await quickViewChecks(
            check, browser: leftBrowser, table: leftTable, controller: controller, window: window)
        await activePanelAndDirtySyncChecks(
            check, leftBrowser: leftBrowser, leftTable: leftTable, rightBrowser: rightBrowser,
            rightTable: rightTable, preview: preview, controller: controller, window: window)
        check(app.sessions.sessions.isEmpty, "closing editor leaves zero active EditorSessions")
        await cursorSweepCheck(
            check, browser: leftBrowser, table: leftTable, controller: controller, window: window)

        await leftBrowser.listed()
        await rightBrowser.listed()
    }

    private func previewPaneChecks(
        _ check: (Bool, String) -> Void, browser: BrowserItem, table: NSTableView,
        preview: PreviewPaneViewController, controller: MainWindowController, window: NSWindow
    ) async {
        check(
            dispatch(KeyChord("p", [.command, .shift]), in: window), "⇧⌘P opens the preview pane")
        window.layoutIfNeeded()
        check(
            controller.frameController.isPreviewPaneShown
                && controller.frameController.windowState.previewShown == true
                && preview.view.frame.width >= 200,
            "preview pane is shown with real width (\(Int(preview.view.frame.width)) pt)")

        select(name: "hello.txt", in: browser, table: table)
        await waitFor {
            preview.activeMode == .quickLook
                && Self.allText(in: preview.view, underID: "previewMetadata")
                    .contains("com.twinpanes.smoke")
        }
        check(
            preview.activeMode == .quickLook
                && Self.allText(in: preview.view, underID: "previewMetadata")
                    .contains("com.twinpanes.smoke"),
            "preview pane uses Quick Look and shows xattr metadata for hello.txt")

        select(name: "raw.bin", in: browser, table: table)
        await waitFor { preview.activeMode == .hex }
        check(preview.activeMode == .hex, "preview pane auto-selects hex for binary data")

        if let modeControl = Self.view(in: preview.view, id: "previewModeControl")
            as? NSSegmentedControl
        {
            modeControl.selectedSegment = 0
            _ = modeControl.action.map { modeControl.sendAction($0, to: modeControl.target) }
            check(preview.activeMode == .quickLook, "mode control switches preview to Quick Look")
            modeControl.selectedSegment = 1
            _ = modeControl.action.map { modeControl.sendAction($0, to: modeControl.target) }
            check(preview.activeMode == .hex, "mode control switches preview back to Hex")
        } else {
            check(false, "preview pane exposes previewModeControl")
        }

        if let pin = Self.view(in: preview.view, id: "previewPinButton") as? NSButton {
            pin.performClick(nil)
            check(preview.isPinned, "Pin freezes the preview pane")
            select(name: "hello.txt", in: browser, table: table)
            await settle(milliseconds: 80)
            check(preview.activeMode == .hex, "pinned preview ignores selection changes")
            pin.performClick(nil)
            await waitFor { preview.activeMode == .quickLook }
            check(!preview.isPinned && preview.activeMode == .quickLook, "unpin catches up")
        } else {
            check(false, "preview pane exposes previewPinButton")
        }

        check(
            dispatch(KeyChord("p", [.command, .shift]), in: window), "⇧⌘P hides the preview pane")
        check(
            !controller.frameController.isPreviewPaneShown
                && controller.frameController.windowState.previewShown == false,
            "preview pane is collapsed and recorded in WindowState")
    }

    private func quickViewChecks(
        _ check: (Bool, String) -> Void, browser: BrowserItem, table: NSTableView,
        controller: MainWindowController, window: NSWindow
    ) async {
        select(name: "hello.txt", in: browser, table: table)
        check(dispatch(.function(3), in: window), "F3 opens Quick View")
        let qv = controller.layout.selectedItem(in: .rightPanel) as? QuickViewItem
        check(
            qv?.currentURL?.lastPathComponent == "hello.txt"
                && controller.layout.activePanel == .leftPanel
                && window.firstResponder === table,
            "F3 opens Quick View in opposite panel without stealing focus")

        select(name: "raw.bin", in: browser, table: table)
        await waitFor { qv?.currentURL?.lastPathComponent == "raw.bin" && qv?.activeMode == .hex }
        check(
            qv?.currentURL?.lastPathComponent == "raw.bin" && qv?.activeMode == .hex,
            "moving cursor retargets following Quick View and switches to hex")

        check(dispatch(.function(3), in: window), "second F3 toggles frontmost Quick View closed")
        check(
            controller.layout.items(in: .rightPanel).allSatisfy { !($0 is QuickViewItem) },
            "following Quick View closed")

        let shiftF3 = KeyChord(String(UnicodeScalar(NSF3FunctionKey)!), .shift)
        check(dispatch(shiftF3, in: window), "⇧F3 opens standalone Quick View")
        let standalone = controller.layout.selectedItem(in: .leftPanel) as? QuickViewItem
        check(
            standalone != nil && standalone?.isFollowing == false
                && controller.layout.activePanel == .leftPanel,
            "⇧F3 opens non-following Quick View in the active panel")

        check(dispatch(.function(4), in: window), "F4 inside Quick View promotes to editor")
        let promoted = controller.layout.selectedItem(in: .leftPanel) as? HexEditorItem
        check(
            promoted?.url.lastPathComponent == "raw.bin",
            "F4 from Quick View opens HexEditorItem on the same file")
        for item in [promoted as (any WorkspaceItem)?, standalone].compactMap({ $0 }) {
            item.willClose()
            controller.layout.remove(item.id)
        }
        controller.layout.select(browser.id)
        window.makeFirstResponder(table)
    }

    private func activePanelAndDirtySyncChecks(
        _ check: (Bool, String) -> Void, leftBrowser: BrowserItem, leftTable: NSTableView,
        rightBrowser: BrowserItem, rightTable: NSTableView, preview: PreviewPaneViewController,
        controller: MainWindowController, window: NSWindow
    ) async {
        controller.layout.select(rightBrowser.id)
        window.makeFirstResponder(rightTable)
        select(name: "raw.bin", in: rightBrowser, table: rightTable)
        check(dispatch(.function(4), in: window), "F4 in right panel opens editor")
        guard let editor = controller.layout.selectedItem(in: .rightPanel) as? HexEditorItem else {
            return check(false, "F4 in right panel opens HexEditorItem in .rightPanel")
        }
        check(
            controller.layout.slot(of: editor.id) == .rightPanel,
            "F4 opens HexEditorItem in the active panel (.rightPanel)")

        controller.layout.select(leftBrowser.id)
        window.makeFirstResponder(leftTable)
        select(name: "raw.bin", in: leftBrowser, table: leftTable)
        _ = dispatch(KeyChord("p", [.command, .shift]), in: window)
        _ = dispatch(.function(3), in: window)
        let qv = controller.layout.selectedItem(in: .rightPanel) as? QuickViewItem

        try? editor.session.overwrite(
            Data([0xAA]), at: 0, selectionBefore: 0..<0, selectionAfter: 1..<1)
        await waitFor {
            let banner = Self.view(in: preview.view, id: "previewUnsavedBanner")
            let badge = qv.flatMap {
                Self.view(in: $0.viewController.view, id: "quickViewUnsavedBadge")
            }
            return banner?.isHidden == false && badge?.isHidden == false
        }
        check(
            editor.session.isDirty
                && Self.view(in: preview.view, id: "previewUnsavedBanner")?.isHidden == false
                && qv.flatMap {
                    Self.view(in: $0.viewController.view, id: "quickViewUnsavedBadge")?.isHidden
                } == false,
            "dirty session updates preview pane and Quick View with unsaved-edits markers")

        editor.willClose()
        controller.layout.remove(editor.id)
        if let qv {
            qv.willClose()
            controller.layout.remove(qv.id)
        }
        _ = dispatch(KeyChord("p", [.command, .shift]), in: window)
    }

    private func cursorSweepCheck(
        _ check: (Bool, String) -> Void, browser: BrowserItem, table: NSTableView,
        controller: MainWindowController, window: NSWindow
    ) async {
        let sweepDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-sweep-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: sweepDir) }
        let made = await Task.detached { Self.makeSweepFolder(sweepDir, count: 1_000) }.value
        guard made else { return check(false, "create 1,000-file sweep folder") }

        browser.go(to: sweepDir)
        await browser.listed()
        controller.layout.select(browser.id)
        window.makeFirstResponder(table)
        _ = dispatch(KeyChord("p", [.command, .shift]), in: window)
        table.selectRowIndexes([1], byExtendingSelection: false)
        _ = dispatch(.function(3), in: window)

        let stalls = StallGate(smoke: self)
        defer { stalls.close() }
        await stalls.check("1,000-file cursor sweep in Quick View and preview", check) {
            for row in 1...min(1_000, table.numberOfRows - 1) {
                table.selectRowIndexes([row], byExtendingSelection: false)
                if row % 50 == 0 { await settle(milliseconds: 1) }
            }
        }
        await settle(milliseconds: 60)
        check(
            app.sessions.sessions.isEmpty,
            "1,000-file cursor sweep creates zero EditorSessions (\(app.sessions.sessions.count))")
        check(
            controller.layout.activePanel == .leftPanel,
            "1,000-file cursor sweep keeps activePanel on the browser")
    }

    private func select(name: String, in browser: BrowserItem, table: NSTableView) {
        guard let index = browser.entries.firstIndex(where: { $0.name == name }) else { return }
        table.selectRowIndexes([index + 1], byExtendingSelection: false)
    }

    private func makePreviewFixtures(in folder: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
            let txt = folder.appendingPathComponent("hello.txt")
            try Data("Hello from Twin Panes preview\n".utf8).write(to: txt)
            let attr = Array("ok".utf8)
            _ = attr.withUnsafeBytes { bytes in
                setxattr(txt.path, "com.twinpanes.smoke", bytes.baseAddress, bytes.count, 0, 0)
            }
            let bin = folder.appendingPathComponent("raw.bin")
            try Data((0..<256).map { UInt8(truncatingIfNeeded: $0) }).write(to: bin)
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func makeSweepFolder(_ folder: URL, count: Int) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let exts = ["txt", "bin", "json", "dat"]
            let payload = Data([0x00, 0xFF, 0x41, 0x42])
            for index in 0..<count {
                let name = String(format: "f%04d.%@", index, exts[index % exts.count])
                fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: payload)
            }
            return true
        } catch {
            return false
        }
    }

    private static func allText(in root: NSView, underID id: String) -> String {
        guard let target = view(in: root, id: id) else { return "" }
        var parts: [String] = []
        func collect(_ view: NSView) {
            if let field = view as? NSTextField, !field.stringValue.isEmpty {
                parts.append(field.stringValue)
            }
            for child in view.subviews { collect(child) }
        }
        collect(target)
        return parts.joined(separator: " ")
    }
}
