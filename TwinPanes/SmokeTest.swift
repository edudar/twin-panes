import AppKit
import BrowserKit
import EditorKit
import Synchronization
import TwinPanesCore
import WorkspaceKit

/// `Twin Panes --smoke-test`: drives the real app (signed, sandboxed) through the M0–M2
/// integration checks (M3a editing included) with its real window layout and exits 0 on success, 1 on failure.
/// Pass `--bench` to also run the slow 480-frame scroll and 256 MiB random-data search
/// throughput benchmarks (PLAN.md §7).
@MainActor
struct SmokeTest {
    let app: AppDelegate
    var includeBenchmarks = false

    func run() {
        // A guard against hangs, not a performance gate: the full run takes about 10 s on
        // the dev Mac and over 30 s on a hosted macOS 27 runner.
        let started = ContinuousClock.now
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            print("SMOKE FAIL: timed out after 120 s")
            if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
                print("::error title=Smoke test::timed out after 120 s")
            }
            exit(1)
        }
        Task { @MainActor in
            var failures: [String] = []
            func check(_ condition: Bool, _ message: String) {
                print(condition ? "  ok   \(message)" : "  FAIL \(message)")
                // On CI, also as an annotation: those are readable without signing in.
                if !condition, ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
                    print("::error title=Smoke test::\(message)")
                }
                if !condition { failures.append(message) }
            }
            await body(check)
            print("  info the smoke test took \(ContinuousClock.now - started)")
            print(failures.isEmpty ? "SMOKE OK" : "SMOKE FAIL: \(failures.count) check(s)")
            exit(failures.isEmpty ? 0 : 1)
        }
    }

    private func body(_ check: (Bool, String) -> Void) async {
        print(
            "Twin Panes smoke test — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print(
            "  sandboxed: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)"
        )

        // Two windows, each with its own layout.
        let first = app.openMainWindow()
        let second = app.openMainWindow()
        check(app.workspace.allLayouts.count == 2, "two main windows registered")
        check(first.layout !== second.layout, "each window has its own layout")
        await settle()

        // Browser (M1b): list a real folder, navigate with keys, open a file.
        guard let window = first.window,
            let browser = first.layout.focusedPanelItem as? BrowserItem
        else {
            check(false, "first window shows a browser")
            return
        }
        print(
            "  info browser starts at \(browser.folder.path), needs access: \(browser.needsAccess)")
        // Sandboxed, FileManager's home is the container; the browser must not start there.
        check(
            NSHomeDirectory().contains("/Library/Containers/")
                && !browser.folder.path.contains("/Library/Containers/"),
            "browser starts in the real home folder, not the app's container")
        guard let folder = makeSampleFolder() else {
            check(false, "create a sample folder")
            return
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        check(browser.go(to: folder), "browser lists a real folder")
        check(
            browser.entries.map(\.name) == ["sub", "data.bin"],
            "folders first: \(browser.entries.map(\.name))")
        window.makeFirstResponder(browser.preferredFirstResponder)
        var chain = FocusChain.scopes(in: window)
        check(
            chain.first == .item(.browser, part: "fileList"),
            "file list is innermost scope (\(chain))")
        check(resolve(.function(3), chain) == .browserView, "F3 in browser → browser.view")
        check(resolve(.function(4), chain) == .browserEdit, "F4 in browser → browser.edit")
        check(dispatch(.returnKey, in: window), "Return opens the selected folder")
        check(browser.folder.lastPathComponent == "sub", "now inside sub")
        check(dispatch(KeyChord("\u{7f}"), in: window), "Backspace goes to the parent")
        check(browser.folder == folder.standardizedFileURL, "back in the sample folder")
        (browser.preferredFirstResponder as? NSTableView)?
            .selectRowIndexes([1], byExtendingSelection: false)
        check(dispatch(.function(4), in: window), "F4 dispatched on a file")
        let opened = app.workspace.allItems.compactMap { $0 as? HexEditorItem }
        check(
            opened.contains { $0.url.lastPathComponent == "data.bin" },
            "F4 opens the file in a hex editor tab")
        for item in opened { first.layout.remove(item.id) }
        first.layout.select(browser.id)

        // Dropping a folder onto the second window opens a browser tab in that window
        // (and MainWindow conforms to NSDraggingDestination for AppKit).
        check(
            second.window is NSDraggingDestination,
            "MainWindow conforms to NSDraggingDestination")
        app.openDropped([folder], in: second)
        check(
            second.layout.allItems.contains {
                ($0 as? BrowserItem)?.folder == folder.standardizedFileURL
            },
            "dropping a folder opens a browser tab in the target window")
        for item in second.layout.allItems
        where (item as? BrowserItem)?.folder == folder.standardizedFileURL {
            second.layout.remove(item.id)
        }

        // The path field inside the browser: Tab must fall through to the key-view loop.
        if let path = Self.view(in: browser.viewController.view, id: "browserPath") {
            window.makeFirstResponder(path)
            chain = FocusChain.scopes(in: window)
            check(resolve(.tab, chain) == nil, "Tab in path field is not intercepted")
            check(resolve(.function(3), chain) == .browserView, "F3 in path field → browser.view")
        } else {
            check(false, "browser has a path field")
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

        // M0: while a sheet is up, the registry intercepts nothing, so keys reach the sheet.
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.beginSheet(sheet) { _ in }
        await settle()
        check(window.attachedSheet === sheet, "a sheet is attached")
        check(!dispatch(.function(3), in: window), "F3 isn't dispatched while a sheet is up")
        check(!dispatch(KeyChord("w", .command), in: window), "⌘W isn't dispatched under a sheet")
        window.endSheet(sheet)
        await settle()
        check(window.attachedSheet == nil, "the sheet is gone")

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

        // Menu automatically refreshes on focus change and shows ⌘G as primary on Find Next.
        let viewMenu = NSApp.mainMenu?.item(withTitle: "View")?.submenu
        if let viewMenu {
            window.makeFirstResponder(editor.preferredFirstResponder)
            let findMenu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu?
                .item(withTitle: "Find")?.submenu
            let findNext = findMenu?.items.first {
                $0.action == #selector(HexEditorActions.editorFindNext(_:))
            }
            let browserView = viewMenu.items.first {
                $0.action == #selector(BrowserActions.browserView(_:))
            }
            check(
                findNext?.keyEquivalent == "g" && findNext?.keyEquivalentModifierMask == .command,
                "menu automatically shows ⌘G on Find Next in editor")
            check(browserView?.keyEquivalent == "", "menu shows no key on View in editor")
        } else {
            check(false, "View menu exists")
        }

        await hexEditor(check, window: window)
        await hexPerformance(check)

        first.closeWithoutAsking()
        second.closeWithoutAsking()
        await settle()
        check(app.workspace.allLayouts.isEmpty, "closed windows unregister their layouts")
    }

    private func resolve(_ chord: KeyChord, _ chain: [BindingScope]) -> CommandID? {
        app.registry.candidates(for: chord, chain: chain).first?.id
    }

    /// Sends a synthetic key-down through the dispatcher, as `MainWindow` would.
    func dispatch(_ chord: KeyChord, in window: NSWindow) -> Bool {
        // AppKit reports a shifted letter as the capital ("G" for ⇧⌘G).
        let shifted = chord.menuKeyEquivalent.mask.contains(.shift)
        let characters = shifted && chord.key.count == 1 ? chord.key.uppercased() : chord.key
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: chord.menuKeyEquivalent.mask,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)
        else { return false }
        return app.dispatcher.handle(event, in: window)
    }

    func status(of controller: MainWindowController) -> String {
        controller.frameController.view.subviews.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "statusLine" }?.stringValue ?? ""
    }

    /// M1: open a real file, draw it, move and copy, and refuse a folder.
    private func hexEditor(_ check: (Bool, String) -> Void, window: NSWindow) async {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("smoke-\(UUID().uuidString).bin")
        let bytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        do { try bytes.write(to: url) } catch {
            check(false, "write sample file: \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let hex = app.openFile(url) else {
            check(false, "hex editor opens a regular file")
            return
        }
        check(app.controller(containing: hex.id) != nil, "hex editor opens as a tab")
        check(hex.length == 200_000, "file length is read")
        await settle()
        let editorView = hex.viewController.view
        editorView.window?.layoutIfNeeded()
        let editor = editorView.bounds, hexFrame = hex.hexView.frame
        check(
            hexFrame.size == editor.size,
            "with find bar and inspector hidden the hex view fills the editor: \(hexFrame) in \(editor)"
        )
        hex.hexView.display()  // drawing asks for the visible bytes in the background
        for _ in 0..<50 where hex.source.cachedBytes(0..<256) == nil { await settle() }
        check(hex.source.cachedBytes(0..<256) != nil, "visible rows were prefetched")

        hex.hexView.go(to: 0x1041)
        check(hex.hexView.selection.cursor == 0x1041, "go to offset moves the cursor")
        check(hex.statusText.hasPrefix("Offset 0x1041"), "status shows the offset")
        NSPasteboard.general.clearContents()
        hex.hexView.copySelection(as: .hex)
        check(NSPasteboard.general.string(forType: .string) == "41", "copy as hex")

        window.makeFirstResponder(hex.hexView)
        let chain = FocusChain.scopes(in: window)
        check(
            resolve(KeyChord("l", .command), chain) == .goToOffset, "⌘L in hex view → go to offset")
        // Wide layout (32 bytes/row) renders cleanly in the real window layout.
        hex.hexView.options.bytesPerRow = .fixed(32)
        hex.hexView.display()
        hex.hexView.options.bytesPerRow = .fixed(16)

        await find(check, hex: hex, window: window)
        await editing(check, hex: hex, window: window)
        await truncation(check, hex: hex, url: url)
        check(app.openFile(dir) == nil, "a folder is refused")
        window.attachedSheet.map { window.endSheet($0) }
    }

    /// Review bug 1: the file gets shorter while it's open. Scrolling past the new end
    /// must draw placeholders and report the problem, not trap.
    private func truncation(_ check: (Bool, String) -> Void, hex: HexEditorItem, url: URL) async {
        do { try FileHandle(forWritingTo: url).truncate(atOffset: 1000) } catch {
            return check(false, "truncate the sample file: \(error)")
        }
        hex.hexView.go(to: 150_000)
        for _ in 0..<5 {
            hex.hexView.display()
            await settle(milliseconds: 20)
        }
        let status = app.controller(containing: hex.id).map { self.status(of: $0) } ?? ""
        check(status.contains("shorter"), "a truncated file is reported: \(status)")
    }

    /// M2 find bar, driven through key dispatch. The sample repeats 00…FF, so "ABC"
    /// starts at 0x41 + 256·k, 781 times in 200,000 bytes.
    private func find(_ check: (Bool, String) -> Void, hex: HexEditorItem, window: NSWindow) async {
        let root = hex.viewController.view
        guard let field = Self.view(in: root, id: "findField") as? NSSearchField,
            let status = Self.view(in: root, id: "findStatus") as? NSTextField
        else { return check(false, "editor has a find bar") }
        check(Self.view(in: root, id: "inspectorTable") != nil, "editor has an inspector")
        window.makeFirstResponder(hex.hexView)
        check(dispatch(KeyChord("f", .command), in: window), "⌘F opens the find bar")
        check(window.firstResponder === field.currentEditor(), "find field has focus")
        root.layoutSubtreeIfNeeded()
        check(
            hex.hexView.frame.height == root.bounds.height - 32,
            "hex view sits below the find bar: \(hex.hexView.frame)")
        field.stringValue = "ABC"
        func cursor(becomes offset: UInt64) async -> Bool {
            for _ in 0..<50 where hex.hexView.selection.range != offset..<offset + 3 {
                await settle(milliseconds: 20)
            }
            return hex.hexView.selection.range == offset..<offset + 3
        }
        check(dispatch(KeyChord("g", .command), in: window), "⌘G dispatched from the find field")
        check(await cursor(becomes: 0x1041), "⌘G finds the match at the cursor")
        _ = dispatch(KeyChord("g", .command), in: window)
        check(await cursor(becomes: 0x1141), "⌘G again finds the next match")
        _ = dispatch(KeyChord("g", [.command, .shift]), in: window)
        check(await cursor(becomes: 0x1041), "⇧⌘G finds the previous match")
        if let findAll = app.registry.command(.editorFindAll) {
            check(app.dispatcher.perform(findAll, in: window), "Find All runs")
        }
        for _ in 0..<50 where !status.stringValue.contains("of 781") {
            await settle(milliseconds: 20)
        }
        check(status.stringValue.contains("of 781"), "Find All counts 781: \(status.stringValue)")
        check(dispatch(.escape, in: window), "Esc in the find field is handled")
        check(field.superview?.superview?.isHidden == true, "Esc closes the find bar")
        check(hex.hexView.highlights.isEmpty, "closing the bar clears the highlights")
        check(
            dispatch(KeyChord("i", [.command, .option]), in: window), "⌥⌘I shows the inspector")
        root.layoutSubtreeIfNeeded()
        check(
            hex.hexView.frame.width == root.bounds.width - 281
                && hex.hexView.frame.height == root.bounds.height,
            "hex view sits beside the inspector: \(hex.hexView.frame)")
        if let table = Self.view(in: root, id: "inspectorTable") as? NSTableView {
            check(table.numberOfRows == 17, "inspector has a row per type: \(table.numberOfRows)")
            check(
                table.rows(in: table.visibleRect).length > 5,
                "inspector rows are visible: \(table.visibleRect)")
            // Jump to an uncached page while the inspector is open and verify it decodes.
            hex.hexView.go(to: 0x18041)
            hex.hexView.display()
            for _ in 0..<50 where hex.source.cachedBytes(0x18041..<0x18049) == nil {
                await settle(milliseconds: 20)
            }
            await settle(milliseconds: 20)
            let uint8Cell = table.view(atColumn: 1, row: 2, makeIfNecessary: true) as? NSTextField
            check(
                uint8Cell?.stringValue == "65",
                "inspector decodes uncached jump: \(uint8Cell?.stringValue ?? "nil")")
        }
        _ = dispatch(KeyChord("i", [.command, .option]), in: window)
        root.layoutSubtreeIfNeeded()
        check(hex.hexView.frame.size == root.bounds.size, "⌥⌘I again hides the inspector")
    }

    /// M1 targets on a sparse 4 GiB file: open < 100 ms, drawing a frame well under
    /// 8.3 ms (120 Hz) while scrolling through the file, memory < 100 MB. Only the
    /// engine's open time can fail the run; tab-open time, frame time and memory are
    /// printed, since shared CI machines vary too much to gate on them.
    private func hexPerformance(_ check: (Bool, String) -> Void) async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-4g-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        do { try FileHandle(forWritingTo: url).truncate(atOffset: 4 << 30) } catch {
            check(false, "create 4 GiB sparse file: \(error)")
            return
        }
        let before = Self.residentMegabytes()
        let clock = ContinuousClock()
        // The M1 target is the engine's open: file, size, first and last page. Opening
        // the tab adds view setup and Open Recent bookmarking, which vary a lot on
        // shared CI machines, so that time is only printed.
        let engine = clock.measure {
            if let source = try? ByteSource(url: url) {
                _ = try? source.read(0..<16)
                _ = try? source.read((source.length - 16)..<source.length)
            }
        }
        check(engine < .milliseconds(100), "4 GiB file opens in \(engine) (< 100 ms)")
        var item: HexEditorItem?
        let open = clock.measure { item = app.openFile(url) }
        guard let item else {
            check(false, "4 GiB file opens in a tab")
            return
        }
        print("  info opening it in a tab took \(open)")
        // Use the real window layout (AGENTS.md: never force view frames in smoke tests).
        item.viewController.view.window?.layoutIfNeeded()
        item.hexView.display()
        let after = Self.residentMegabytes()
        print("  info resident memory \(after) MB, \(after - before) MB more than before opening")
        await fullSearch(check, item: item)
        await editingLargeFile(check, item: item)

        if includeBenchmarks {
            Self.printFrames(await scrollThroughFile(item), "")
            let searcher = Searcher(source: item.source)
            let search = Task {
                try await Searcher.run { token in
                    try searcher.all(try SearchPattern.hex("FF"), cancellation: token)
                }
            }
            Self.printFrames(await scrollThroughFile(item), " while searching")
            search.cancel()
            _ = try? await search.value
            print("  info resident memory while searching \(Self.residentMegabytes()) MB")
            await realDataSearch(check)
        }
    }

    /// Jumps through the whole file in 240 steps, letting prefetches land, and times one
    /// redraw at each.
    private func scrollThroughFile(_ item: HexEditorItem) async -> [Duration] {
        let view = item.hexView
        let clock = ContinuousClock()
        var frames: [Duration] = []
        for step in 0..<240 {
            view.go(to: UInt64(step) * (item.length / 240))
            view.display()
            await settle(milliseconds: 5)
            frames.append(clock.measure { view.display() })
        }
        return frames
    }

    private static func printFrames(_ frames: [Duration], _ label: String) {
        let sorted = frames.sorted()
        print(
            "  info frame time\(label) p50 \(sorted[sorted.count / 2]), "
                + "p95 \(sorted[sorted.count * 95 / 100]), max \(sorted.last!)")
    }

    /// §7: search throughput on real (non-sparse) data. A sparse zero file is the best
    /// case: no byte ever matches the anchor. 256 MiB of pseudo-random bytes hits it
    /// every 256 bytes on average. Printed, not gated.
    private func realDataSearch(_ check: (Bool, String) -> Void) async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-random-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: url)
            var state: UInt64 = 0x2545_F491_4F6C_DD1D
            var chunk = [UInt64](repeating: 0, count: 1 << 17)  // 1 MiB
            for _ in 0..<256 {
                for index in chunk.indices {
                    state ^= state << 13
                    state ^= state >> 7
                    state ^= state << 17
                    chunk[index] = state
                }
                try chunk.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
            }
            try handle.close()
            let source = try ByteSource(url: url)
            let pattern = try SearchPattern.hex("DE AD BE EF CA FE BA BE")
            let clock = ContinuousClock()
            var found: Searcher.AllMatches?
            let elapsed = try await clock.measure {
                found = try await Searcher.run { token in
                    try Searcher(source: source).all(pattern, cancellation: token)
                }
            }
            let seconds =
                Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            print(
                "  info search of 256 MiB of random data took \(elapsed) "
                    + "(\(Int(256 / max(seconds, 0.001))) MiB/s, \(found?.ranges.count ?? 0) matches)"
            )
        } catch {
            check(false, "real-data search: \(error)")
        }
    }

    /// M2 target: a full search of the 4 GiB file, with progress and cancel, without
    /// evicting the pages the view is showing. The time is printed, not gated.
    private func fullSearch(_ check: (Bool, String) -> Void, item: HexEditorItem) async {
        let view = item.hexView
        view.go(to: 2 << 30)
        view.display()
        let visible = view.selection.cursor..<view.selection.cursor + 4096
        for _ in 0..<50 where item.source.cachedBytes(visible) == nil {
            await settle(milliseconds: 20)
        }
        check(
            item.source.cachedBytes(visible) != nil, "the view's pages are cached before searching")

        let searcher = Searcher(source: item.source)
        let pattern = try! SearchPattern.hex("FF")
        let scanned = Mutex<UInt64>(0)
        let clock = ContinuousClock()
        var found: Searcher.Match?
        var failure: (any Error)?
        let elapsed = await clock.measure {
            do {
                found = try await Searcher.run { token in
                    try searcher.next(
                        pattern, from: 0, direction: .forward, wraps: false, cancellation: token
                    ) { done, _ in scanned.withLock { $0 = done } }
                }
            } catch {
                failure = error
            }
        }
        check(
            failure == nil && found == nil,
            "full search of 4 GiB finds nothing in a zero file \(failure.map { "\($0)" } ?? "")")
        check(scanned.withLock { $0 } == 4 << 30, "progress reached the whole file")
        print("  info full search of 4 GiB took \(elapsed)")
        check(item.source.cachedBytes(visible) != nil, "searching didn't evict the view's pages")

        let started = Mutex(false)
        let task = Task {
            try await Searcher.run { token in
                try searcher.all(pattern, cancellation: token) { _, _ in
                    started.withLock { $0 = true }
                }
            }
        }
        for _ in 0..<100 where !started.withLock({ $0 }) { await settle(milliseconds: 5) }
        task.cancel()
        let cancelled = await clock.measure {
            do { _ = try await task.value } catch is CancellationError {} catch {}
        }
        check(
            task.isCancelled && cancelled < .milliseconds(500),
            "a search cancels quickly (\(cancelled))")
    }

    private static func residentMegabytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }

    /// A folder in the container's temp dir with one subfolder and one file.
    private func makeSampleFolder() -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-folder-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: folder.appendingPathComponent("data.bin"))
            return folder
        } catch {
            return nil
        }
    }

    private static func view(in root: NSView, id: String) -> NSView? {
        if root.accessibilityIdentifier() == id { return root }
        for child in root.subviews {
            if let found = view(in: child, id: id) { return found }
        }
        return nil
    }

    func settle(milliseconds: Int = 100) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}
