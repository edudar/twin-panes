import AppKit
import BrowserKit
import Darwin
import EditorKit
import HexViewKit
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
        await structuredQuickViewChecks(
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
                && qv?.activeMode == .text
                && controller.layout.activePanel == .leftPanel
                && window.firstResponder === table,
            "F3 opens Quick View in Text mode in opposite panel without stealing focus")

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

        let quickHex = standalone.flatMap {
            Self.view(in: $0.viewController.view, id: "readOnlyHexView") as? HexView
        }
        check(
            quickHex != nil && window.firstResponder === quickHex
                && quickHex?.options == HexViewOptions(),
            "Hex Quick View focuses readOnlyHexView and starts with Edit's default options (16 bytes/row)"
        )
        let targetOptions = HexViewOptions(
            bytesPerRow: .fixed(8), grouping: 4, offsetBase: .decimal, textEncoding: .latin1)
        defer { app.hexViewPreferences.options = HexViewOptions() }
        for (action, value) in [
            (#selector(HexEditorActions.setBytesPerRow(_:)), 8 as Any),
            (#selector(HexEditorActions.setGrouping(_:)), 4 as Any),
            (#selector(HexEditorActions.setOffsetBase(_:)), "decimal" as Any),
            (#selector(HexEditorActions.setTextEncoding(_:)), "latin1" as Any),
        ] {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.representedObject = value
            _ = window.firstResponder?.tryToPerform(action, with: item)
        }
        check(
            quickHex?.options == targetOptions && app.hexViewPreferences.options == targetOptions,
            "View menu hex options update focused Hex Quick View via responder chain")

        check(dispatch(.function(4), in: window), "F4 inside Quick View promotes to editor")
        let promoted = controller.layout.selectedItem(in: .leftPanel) as? HexEditorItem
        check(
            promoted?.url.lastPathComponent == "raw.bin"
                && promoted?.hexView.options == targetOptions,
            "F4 from Quick View opens HexEditorItem in the same panel with shared hex options")
        app.hexViewPreferences.options = HexViewOptions()
        check(
            quickHex?.options == HexViewOptions() && promoted?.hexView.options == HexViewOptions(),
            "Shared hex option changes sync across open Quick View and editor")
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

    /// M7b checks (docs/plans/M7b.md, D-e): structured Pretty | Text | Hex Quick View on real
    /// files, bounded truncation, and format overrides with an isolated `UserDefaults` suite.
    private func structuredQuickViewChecks(
        _ check: (Bool, String) -> Void, browser: BrowserItem, table: NSTableView,
        controller: MainWindowController, window: NSWindow
    ) async {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-structured-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: folder) }
        let minifiedJSON = #"{"name":"twin","list":[1,2,{"ok":true}],"n":12345678901234567890}"#
        guard makeStructuredFixtures(in: folder, minifiedJSON: minifiedJSON) else {
            return check(false, "create structured Quick View fixtures")
        }
        let savedFolder = browser.folder
        defer { browser.go(to: savedFolder) }
        browser.go(to: folder)
        await browser.listed()
        controller.layout.select(browser.id)
        window.makeFirstResponder(table)
        select(name: "min.json", in: browser, table: table)
        _ = dispatch(.function(3), in: window)
        guard let qv = controller.layout.selectedItem(in: .rightPanel) as? QuickViewItem else {
            return check(false, "F3 opens Quick View for structured checks")
        }
        defer {
            qv.willClose()
            controller.layout.remove(qv.id)
            controller.layout.select(browser.id)
            window.makeFirstResponder(table)
        }

        func textView(of item: QuickViewItem) -> NSTextView? {
            Self.view(in: item.viewController.view, id: "structuredPreviewTextView") as? NSTextView
        }
        func notice(of item: QuickViewItem) -> String? {
            let label =
                Self.view(in: item.viewController.view, id: "structuredPreviewNotice")
                as? NSTextField
            return label?.isHidden == false && label?.superview?.isHidden == false
                ? label?.stringValue : nil
        }
        func segments(of item: QuickViewItem) -> [String] {
            guard
                let control = Self.view(in: item.viewController.view, id: "quickViewModeControl")
                    as? NSSegmentedControl
            else { return [] }
            return (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
        }
        func isModeControlHidden(_ item: QuickViewItem) -> Bool? {
            Self.view(in: item.viewController.view, id: "quickViewModeControl")?.isHidden
        }
        func hasColoredText(_ view: NSTextView?) -> Bool {
            guard let storage = view?.textStorage, storage.length > 0 else { return false }
            var colored = false
            storage.enumerateAttribute(
                .foregroundColor, in: NSRange(location: 0, length: storage.length)
            ) { value, _, stop in
                if let color = value as? NSColor, color != NSColor.labelColor {
                    colored = true
                    stop.pointee = true
                }
            }
            return colored
        }
        func open(_ name: String, until ready: @escaping (NSTextView) -> Bool) async -> Bool {
            select(name: name, in: browser, table: table)
            await waitFor {
                qv.currentURL?.lastPathComponent == name
                    && (textView(of: qv).map(ready) ?? false)
            }
            return qv.currentURL?.lastPathComponent == name
                && (textView(of: qv).map(ready) ?? false)
        }
        func choose(_ mode: Int, of item: QuickViewItem) {
            guard
                let control = Self.view(in: item.viewController.view, id: "quickViewModeControl")
                    as? NSSegmentedControl
            else { return }
            control.selectedSegment = mode
            _ = control.sendAction(control.action, to: control.target)
        }
        let lineCount: (NSTextView) -> Int = { $0.string.split(separator: "\n").count }

        let jsonReady = await open("min.json") { lineCount($0) >= 5 }
        check(
            jsonReady && qv.activeMode == .pretty && segments(of: qv) == ["Pretty", "Text", "Hex"]
                && textView(of: qv)?.string.contains("  \"name\": \"twin\"") == true
                && textView(of: qv)?.string.contains("12345678901234567890") == true
                && hasColoredText(textView(of: qv)),
            "minified .json opens Pretty with Pretty | Text | Hex, indented, colored, exact numbers"
        )
        choose(1, of: qv)
        let rawShown = await open("min.json") { $0.string == minifiedJSON }
        check(
            rawShown && qv.activeMode == .text && !hasColoredText(textView(of: qv)),
            "Text segment shows the raw minified .json uncolored")
        choose(0, of: qv)

        let badReady = await open("bad.json") { $0.string == "{\"a\":1," }
        check(
            badReady && notice(of: qv)?.contains("Invalid JSON") == true,
            "malformed .json shows raw text with an Invalid JSON notice")

        let xmlReady = await open("min.xml") { lineCount($0) >= 3 }
        check(
            xmlReady && qv.activeMode == .pretty
                && textView(of: qv)?.string.contains("<item id=\"1\">") == true
                && hasColoredText(textView(of: qv)),
            "minified .xml pretty-prints with colored tokens")
        let plistReady = await open("bin.plist") { $0.string.contains("<key>name</key>") }
        check(
            plistReady && lineCount(textView(of: qv)!) >= 4 && hasColoredText(textView(of: qv)),
            "binary .plist shows pretty-printed colored XML")
        let csvReady = await open("data.csv") { $0.string.contains("│") }
        check(csvReady, "pretty .csv shows aligned columns")
        let yamlReady = await open("conf.yaml") { $0.string.contains("name") && hasColoredText($0) }
        check(yamlReady, "pretty .yaml shows colored tokens")

        select(name: "blob.bin", in: browser, table: table)
        await waitFor { qv.currentURL?.lastPathComponent == "blob.bin" && qv.activeMode == .hex }
        check(
            qv.activeMode == .hex && isModeControlHidden(qv) == true,
            "unknown .bin opens Hex with the mode control hidden")

        let bigReady = await open("big.json") { _ in notice(of: qv) != nil }
        let shownBytes = textView(of: qv)?.string.utf8.count ?? .max
        check(
            bigReady && notice(of: qv)?.contains("Showing first") == true
                && shownBytes <= 140 * 1024,
            "2.1 MiB .json shows a truncation notice with bounded text (\(shownBytes) bytes)")

        await structuredOverrideChecks(check, folder: folder, browser: browser)
        check(
            app.sessions.sessions.isEmpty, "structured Quick View checks create zero EditorSessions"
        )
    }

    /// Persistent overrides go to a temp-folder `UserDefaults` suite so nothing reaches
    /// `~/Library/Preferences`.
    private func structuredOverrideChecks(
        _ check: (Bool, String) -> Void, folder: URL, browser: BrowserItem
    ) async {
        let suitePath = folder.appendingPathComponent("overrides").path
        guard let defaults = UserDefaults(suiteName: suitePath),
            let entry = browser.entries.first(where: { $0.name == "x.myconf" })
        else { return check(false, "override checks have an isolated suite and x.myconf") }
        defer { defaults.removePersistentDomain(forName: suitePath) }
        let overrides = PreviewFormatOverrides(defaults: defaults)
        let item = QuickViewItem(
            viewerFactory: app.viewerFactory, sessions: app.sessions, isFollowing: false,
            debounce: .zero, formatOverrides: overrides
        ) { _, _ in }
        defer { item.willClose() }
        let root = item.viewController.view
        func choose(_ title: String) {
            guard
                let menu = (Self.view(in: root, id: "quickViewFormatButton") as? NSPopUpButton)?
                    .menu
            else { return }
            let index = menu.indexOfItem(withTitle: title)
            if index >= 0 { menu.performActionForItem(at: index) }
        }
        func shownText() -> String {
            (Self.view(in: root, id: "structuredPreviewTextView") as? NSTextView)?.string ?? ""
        }

        item.show(entry, scope: nil)
        check(item.activeMode == .hex, "unknown .myconf starts in Hex")
        choose("Properties")
        await waitFor { shownText().contains("key") }
        check(
            item.activeMode == .pretty && shownText().contains("key")
                && overrides.override(forExtension: "myconf") == nil,
            "transient Properties override reclassifies .myconf without persisting")
        choose("Remember for .myconf")
        check(
            overrides.override(forExtension: "myconf") == .structured(.properties),
            "Remember for .ext persists the override in the isolated suite")
        item.show(nil, scope: nil)
        item.show(entry, scope: nil)
        check(
            item.activeMode == .pretty, "remembered override applies when the file is shown again")
        choose("Reset .myconf to Auto")
        check(
            item.activeMode == .hex && overrides.override(forExtension: "myconf") == nil,
            "Reset .ext to Auto removes the override")
    }

    private func makeStructuredFixtures(in folder: URL, minifiedJSON: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func write(_ text: String, _ name: String) throws {
                try Data(text.utf8).write(to: folder.appendingPathComponent(name))
            }
            try write(minifiedJSON, "min.json")
            try write("{\"a\":1,", "bad.json")
            try write(
                #"<root><item id="1">x</item><item id="2">y</item></root>"#, "min.xml")
            try write("name,age\nalice,30\nbob,4\n", "data.csv")
            try write("name: demo\nitems:\n  - 1\n  - true\n# note\n", "conf.yaml")
            try write("key=value\n# note\n", "x.myconf")
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["name": "x", "count": 1], format: .binary, options: 0)
            try plist.write(to: folder.appendingPathComponent("bin.plist"))
            try Data([0x00, 0xFF, 0x10, 0x80, 0x00]).write(
                to: folder.appendingPathComponent("blob.bin"))
            let record = "\"" + String(repeating: "x", count: 62) + "\",\n"
            let big = "[\n" + String(repeating: record, count: 34_000) + "\"end\"\n]\n"
            try write(big, "big.json")
            return true
        } catch {
            return false
        }
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
        await waitFor { Self.openFileDescriptorCount() <= fdBefore + 16 }
        let fdAfter = Self.openFileDescriptorCount()
        check(
            fdAfter <= fdBefore + 16,
            "1,000-file sweep leaks no file descriptors (before \(fdBefore), after \(fdAfter))"
        )
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

    private static func openFileDescriptorCount() -> Int {
        // Probe the process FD table directly rather than opendir("/dev/fd"), which
        // App Sandbox denies on macOS 15.
        var limit = rlimit()
        let upper: Int32 =
            getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur > 0
            ? Int32(min(limit.rlim_cur, 16_384)) : 4_096
        var count = 0
        for fd in 0..<upper where fcntl(fd, F_GETFD) != -1 {
            count += 1
        }
        return count
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
