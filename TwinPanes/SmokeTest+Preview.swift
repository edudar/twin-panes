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
            rightTable: rightTable, controller: controller, window: window)
        check(app.sessions.sessions.isEmpty, "closing editor leaves zero active EditorSessions")
        await cursorSweepCheck(
            check, browser: leftBrowser, table: leftTable, preview: preview,
            controller: controller, window: window)

        await leftBrowser.listed()
        await rightBrowser.listed()
    }

    private func previewPaneChecks(
        _ check: (Bool, String) -> Void, browser: BrowserItem, table: NSTableView,
        preview: PreviewPaneViewController, controller: MainWindowController, window: NSWindow
    ) async {
        window.layoutIfNeeded()
        let initialFraction = controller.frameController.windowState.dividerFraction
        check(
            dispatch(KeyChord("p", [.command, .shift]), in: window), "⇧⌘P opens the preview pane")
        window.layoutIfNeeded()
        let shownFraction = controller.frameController.windowState.dividerFraction
        let metadataHeight = Self.view(in: preview.view, id: "previewMetadata")?.frame.height ?? 0
        check(
            controller.frameController.isPreviewPaneShown
                && controller.frameController.windowState.previewShown == true
                && preview.view.frame.width >= 200
                && metadataHeight >= 120,
            "preview pane is shown with real layout (\(Int(preview.view.frame.width)) pt wide, metadata \(Int(metadataHeight)) pt tall)"
        )
        panelSlotChecks(check, preview: preview, controller: controller, window: window)

        select(name: "hello.txt", in: browser, table: table)
        await waitFor {
            Self.allText(in: preview.view, underID: "previewMetadata")
                .contains("com.twinpanes.smoke")
        }
        check(
            Self.allText(in: preview.view, underID: "previewMetadata")
                .contains("com.twinpanes.smoke"),
            "preview pane shows Quick Look and xattr metadata for hello.txt")

        check(
            dispatch(KeyChord("p", [.command, .shift]), in: window), "⇧⌘P hides the preview pane")
        window.layoutIfNeeded()
        let hiddenFraction = controller.frameController.windowState.dividerFraction
        check(
            !controller.frameController.isPreviewPaneShown
                && controller.frameController.windowState.previewShown == false,
            "preview pane is collapsed and recorded in WindowState")
        if let initialFraction, let shownFraction, let hiddenFraction {
            check(
                abs(shownFraction - initialFraction) <= 0.01
                    && abs(hiddenFraction - initialFraction) <= 0.01,
                "⇧⌘P preserves panel split ratio (\(String(format: "%.3f -> %.3f -> %.3f", initialFraction, shownFraction, hiddenFraction)))"
            )
        } else {
            check(false, "dividerFraction is available before and after ⇧⌘P")
        }
    }

    private func panelSlotChecks(
        _ check: (Bool, String) -> Void, preview: PreviewPaneViewController,
        controller: MainWindowController, window: NSWindow
    ) {
        guard let content = window.contentView else {
            return check(false, "window has contentView for panelSlot(at:) checks")
        }
        func windowCenter(of view: NSView) -> NSPoint {
            view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }
        let leftView = Self.view(in: content, id: SlotID.leftPanel.rawValue)
        let rightView = Self.view(in: content, id: SlotID.rightPanel.rawValue)
        check(
            leftView.map {
                controller.frameController.panelSlot(at: windowCenter(of: $0)) == .leftPanel
            } ?? false,
            "panelSlot(at:) routes left panel point to .leftPanel")
        check(
            rightView.map {
                controller.frameController.panelSlot(at: windowCenter(of: $0)) == .rightPanel
            } ?? false,
            "panelSlot(at:) routes right panel point to .rightPanel")
        check(
            controller.frameController.panelSlot(at: windowCenter(of: preview.view)) == nil,
            "panelSlot(at:) returns nil over the preview pane")
        if controller.frameController.isSidebarShown,
            let sidebarView = Self.view(in: content, id: "sidebar")
        {
            check(
                controller.frameController.panelSlot(at: windowCenter(of: sidebarView)) == nil,
                "panelSlot(at:) returns nil over the sidebar")
        }
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
                && qv?.activeMode == .quickLook
                && controller.layout.activePanel == .leftPanel
                && window.firstResponder === table,
            "F3 opens Quick View in Quick Look mode in opposite panel without stealing focus")

        select(name: "raw.bin", in: browser, table: table)
        await waitFor { qv?.currentURL?.lastPathComponent == "raw.bin" && qv?.activeMode == .hex }
        check(
            qv?.currentURL?.lastPathComponent == "raw.bin" && qv?.activeMode == .hex,
            "moving cursor retargets following Quick View and switches to hex")

        if let qv,
            let keepButton = Self.view(in: qv.viewController.view, id: "quickViewPinButton")
                as? NSButton
        {
            keepButton.performClick(nil)
            check(keepButton.title == "Keep" && qv.isPinned, "Keep freezes Quick View")
            select(name: "hello.txt", in: browser, table: table)
            await settle(milliseconds: 50)
            check(
                qv.currentURL?.lastPathComponent == "raw.bin",
                "kept Quick View ignores selection changes")
            keepButton.performClick(nil)
            select(name: "raw.bin", in: browser, table: table)
            await waitFor { qv.currentURL?.lastPathComponent == "raw.bin" }
        } else {
            check(false, "Quick View exposes Keep button")
        }

        if let qv,
            let buriedBehind = controller.layout.items(in: .rightPanel).first(where: {
                $0.id != qv.id
            })
        {
            controller.layout.selectInBackground(buriedBehind.id)
            check(
                controller.layout.selectedItem(in: .rightPanel)?.id == buriedBehind.id,
                "opposite panel shows another tab over Quick View")
            check(dispatch(.function(3), in: window), "F3 surfaces buried Quick View")
            check(
                controller.layout.selectedItem(in: .rightPanel)?.id == qv.id
                    && controller.layout.items(in: .rightPanel).contains { $0.id == qv.id }
                    && controller.layout.activePanel == .leftPanel
                    && window.firstResponder === table,
                "F3 brings buried Quick View forward without closing it or stealing activePanel")
        }

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
            "F4 from Quick View opens HexEditorItem in the same panel")
        for item in [promoted as (any WorkspaceItem)?, standalone].compactMap({ $0 }) {
            item.willClose()
            controller.layout.remove(item.id)
        }
        controller.layout.select(browser.id)
        window.makeFirstResponder(table)

        check(dispatch(.function(3), in: window), "F3 opens Quick View for auto-detach check")
        if let movedQV = controller.layout.selectedItem(in: .rightPanel) as? QuickViewItem {
            controller.layout.move(movedQV.id, to: .leftPanel)
            check(
                !movedQV.isFollowing && movedQV.isPinned,
                "moving following Quick View into source panel permanently detaches it")
            let pinHidden =
                Self.view(in: movedQV.viewController.view, id: "quickViewPinButton")?.isHidden
                ?? false
            check(pinHidden, "detached Quick View hides Keep button")
            movedQV.willClose()
            controller.layout.remove(movedQV.id)
        } else {
            check(false, "Quick View opened for auto-detach check")
        }
        controller.layout.select(browser.id)
        window.makeFirstResponder(table)
    }

    private func activePanelAndDirtySyncChecks(
        _ check: (Bool, String) -> Void, leftBrowser: BrowserItem, leftTable: NSTableView,
        rightBrowser: BrowserItem, rightTable: NSTableView,
        controller: MainWindowController, window: NSWindow
    ) async {
        controller.layout.select(rightBrowser.id)
        window.makeFirstResponder(rightTable)
        select(name: "raw.bin", in: rightBrowser, table: rightTable)
        check(dispatch(.function(4), in: window), "F4 in right panel opens editor")
        guard let editor = controller.layout.selectedItem(in: .leftPanel) as? HexEditorItem else {
            return check(false, "F4 in right panel opens HexEditorItem in .leftPanel")
        }
        check(
            controller.layout.slot(of: editor.id) == .leftPanel,
            "F4 opens HexEditorItem in the opposite panel (.leftPanel)")

        controller.layout.select(rightBrowser.id)
        window.makeFirstResponder(rightTable)
        select(name: "raw.bin", in: rightBrowser, table: rightTable)
        _ = dispatch(.function(3), in: window)
        let qv = controller.layout.selectedItem(in: .leftPanel) as? QuickViewItem

        try? editor.session.overwrite(
            Data([0xAA]), at: 0, selectionBefore: 0..<0, selectionAfter: 1..<1)
        await waitFor {
            qv.flatMap {
                Self.view(in: $0.viewController.view, id: "quickViewUnsavedBadge")?.isHidden
            } == false
        }
        check(
            editor.session.isDirty
                && qv.flatMap {
                    Self.view(in: $0.viewController.view, id: "quickViewUnsavedBadge")?.isHidden
                } == false,
            "dirty session updates Quick View with unsaved-edits badge")

        if let qv {
            controller.layout.select(qv.id)
            window.makeFirstResponder(qv.preferredFirstResponder)
            let sessionsBefore = app.sessions.sessions.count
            let tabsBefore = controller.layout.allItems.count
            check(
                dispatch(.function(4), in: window),
                "F4 inside Quick View focuses already-open editor")
            check(
                controller.layout.selectedItem(in: .leftPanel)?.id == editor.id
                    && controller.layout.activePanel == .leftPanel
                    && app.sessions.sessions.count == sessionsBefore
                    && controller.layout.allItems.count == tabsBefore,
                "F4 from Quick View focuses existing editor without duplicating session or tab")
        }

        editor.willClose()
        controller.layout.remove(editor.id)
        if let qv {
            qv.willClose()
            controller.layout.remove(qv.id)
        }
        controller.layout.select(leftBrowser.id)
        window.makeFirstResponder(leftTable)
    }

    private func cursorSweepCheck(
        _ check: (Bool, String) -> Void, browser: BrowserItem, table: NSTableView,
        preview: PreviewPaneViewController, controller: MainWindowController, window: NSWindow
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

        let fdBefore = Self.openFileDescriptorCount()
        let openedPreview = dispatch(KeyChord("p", [.command, .shift]), in: window)
        check(
            openedPreview && controller.frameController.isPreviewPaneShown,
            "⇧⌘P opens preview pane before cursor sweep")
        table.selectRowIndexes([1], byExtendingSelection: false)
        let openedQV = dispatch(.function(3), in: window)
        let qv = controller.layout.selectedItem(in: .rightPanel) as? QuickViewItem
        check(
            openedQV && qv?.isFollowing == true,
            "F3 opens following Quick View before cursor sweep")

        let lastRow = min(1_000, table.numberOfRows - 1)
        let finalName = lastRow >= 1 ? browser.entries[lastRow - 1].name : ""
        if lastRow >= 1 {
            let stalls = StallGate(smoke: self)
            defer { stalls.close() }
            await stalls.check("1,000-file cursor sweep in Quick View and preview", check) {
                for row in 1...lastRow {
                    table.selectRowIndexes([row], byExtendingSelection: false)
                    if row % 50 == 0 { await settle(milliseconds: 1) }
                }
            }
        }
        await waitFor {
            qv?.currentURL?.lastPathComponent == finalName
                && Self.allText(in: preview.view, underID: "previewMetadata").contains(finalName)
        }
        check(
            !finalName.isEmpty
                && qv?.currentURL?.lastPathComponent == finalName
                && Self.allText(in: preview.view, underID: "previewMetadata").contains(finalName),
            "Quick View and preview pane settle on final swept file (\(finalName))")
        check(
            app.sessions.sessions.isEmpty,
            "1,000-file cursor sweep creates zero EditorSessions (\(app.sessions.sessions.count))")
        check(
            controller.layout.activePanel == .leftPanel,
            "1,000-file cursor sweep keeps activePanel on the browser")

        if let qv {
            let closedQV = dispatch(.function(3), in: window)
            check(
                closedQV
                    && controller.layout.items(in: .rightPanel).allSatisfy {
                        !($0 is QuickViewItem)
                    },
                "F3 closes sweep Quick View")
            if controller.layout.item(qv.id) != nil {
                qv.willClose()
                controller.layout.remove(qv.id)
            }
        }
        if controller.frameController.isPreviewPaneShown {
            check(
                dispatch(KeyChord("p", [.command, .shift]), in: window)
                    && !controller.frameController.isPreviewPaneShown,
                "⇧⌘P hides sweep preview pane")
        }
        if let fdBefore {
            await waitFor { (Self.openFileDescriptorCount() ?? Int.max) <= fdBefore + 16 }
            let fdAfter = Self.openFileDescriptorCount()
            check(
                fdAfter.map { $0 <= fdBefore + 16 } ?? false,
                "1,000-file sweep leaks no file descriptors (before \(fdBefore), after \(fdAfter.map(String.init) ?? "nil"))"
            )
        } else {
            check(false, "count open file descriptors in /dev/fd")
        }
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

    private static func openFileDescriptorCount() -> Int? {
        guard let dir = opendir("/dev/fd") else { return nil }
        defer { closedir(dir) }
        var count = 0
        while let entry = readdir(dir) {
            let isDot = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                raw[0] == UInt8(ascii: ".")
                    && (raw[1] == 0 || (raw[1] == UInt8(ascii: ".") && raw[2] == 0))
            }
            if !isDot { count += 1 }
        }
        // Subtract 1 for the opendir descriptor itself.
        return max(0, count - 1)
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
