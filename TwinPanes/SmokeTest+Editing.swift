import AppKit
import EditorKit
import Synchronization
import TwinPanesCore
import WorkspaceKit

/// M3a overwrite editing in the running app, typed with real key events through the
/// window and the main menu (docs/plans/M3a.md).
extension SmokeTest {
    /// Sends `text` as key-downs through `NSApp`, so typing reaches the first responder
    /// and ⌘-keys reach the main menu, as they do for the user.
    func type(_ text: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) {
        for character in text {
            let characters = String(character)
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)
            else { continue }
            NSApp.sendEvent(event)
        }
    }

    /// Chooses the main-menu item for `action` the way AppKit does for a key window: the
    /// first object in the first responder's chain that implements the action validates
    /// and performs it. (The smoke-test app isn't frontmost, so its window never becomes
    /// key and the menu's own key-equivalent path has no target.) Finds the item by its
    /// action, since validation may retitle it ("Undo Typing"), and checks its key.
    func menu(_ action: Selector, key: String, in window: NSWindow) -> Bool {
        guard
            let item = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
                .first(where: { $0.action == action }),
            item.keyEquivalent.lowercased() == key
        else { return false }
        var responder = window.firstResponder
        while let current = responder, !current.responds(to: action) {
            responder = current.nextResponder
        }
        guard let target = responder,
            (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
        else { return false }
        return target.tryToPerform(action, with: item)
    }

    /// The sample repeats 00…FF, so every byte's value is its offset modulo 256.
    func editing(_ check: (Bool, String) -> Void, hex: HexEditorItem, window: NSWindow) async {
        func bytes(_ range: Range<UInt64>) -> [UInt8] {
            (try? hex.read(range)).map(Array.init) ?? []
        }
        let undo = #selector(HexEditorActions.undo(_:)), redo = #selector(HexEditorActions.redo(_:))
        window.makeFirstResponder(hex.hexView)
        hex.hexView.go(to: 0x10)
        type("AB", in: window)
        check(
            bytes(0x10..<0x11) == [0xAB],
            "typing hex digits overwrites a byte: \(bytes(0x10..<0x11))")
        check(hex.hexView.selection.cursor == 0x11, "the cursor moves on after two digits")
        type("\t", in: window)
        type("Hi", in: window)
        check(bytes(0x11..<0x13) == Array("Hi".utf8), "typing in the text column writes characters")
        check(hex.isDirty, "edits make the tab dirty")
        let status = app.controller(containing: hex.id).map { self.status(of: $0) } ?? ""
        check(status.contains("Modified"), "the status line says Modified: \(status)")
        check(hex.modifiedRanges(in: 0..<0x100) == [0x10..<0x13], "the changed bytes are marked")
        hex.hexView.display()

        // Drive the real Find bar to locate the text we just typed.
        let root = hex.viewController.view
        if let field = Self.view(in: root, id: "findField") as? NSSearchField {
            check(dispatch(KeyChord("f", .command), in: window), "⌘F opens find after edit")
            field.stringValue = "Hi"
            hex.hexView.go(to: 0)
            window.makeFirstResponder(field)
            _ = dispatch(KeyChord("g", .command), in: window)
            for _ in 0..<50 where hex.hexView.selection.range != 0x11..<0x13 {
                await settle(milliseconds: 20)
            }
            check(hex.hexView.selection.range == 0x11..<0x13, "Find bar locates typed bytes")
            _ = dispatch(.escape, in: window)
            window.makeFirstResponder(hex.hexView)
        } else {
            check(false, "editor has a find field")
        }

        check(menu(undo, key: "z", in: window), "Edit › Undo (⌘Z) reaches the editor")
        check(bytes(0x11..<0x13) == [0x11, 0x12], "Undo reverts the text-column typing")
        check(menu(undo, key: "z", in: window), "Undo again")
        check(bytes(0x10..<0x11) == [0x10] && !hex.isDirty, "Undo again reverts the hex typing")
        check(menu(redo, key: "z", in: window), "Edit › Redo (⇧⌘Z) reaches the editor")
        check(bytes(0x10..<0x11) == [0xAB], "Redo brings the hex typing back")

        let dirty = app.closeCoordinator.dirtySessions(closing: [hex])
        check(dirty.count == 1, "closing the edited tab asks first")
        if let session = dirty.first {
            let alert = app.makeCloseAlert(for: session)
            let titles = alert.buttons.map(\.title)
            check(
                titles == ["Save", "Cancel", "Don’t Save"],
                "a writable file's close prompt offers Save: \(titles)")
            check(
                alert.buttons[2].hasDestructiveAction && alert.buttons[2].keyEquivalent == "d"
                    && alert.buttons[2].keyEquivalentModifierMask == .command,
                "Don’t Save is destructive with ⌘D")
            check(
                AppDelegate.closeDecision(for: .alertFirstButtonReturn, canSave: true) == .save
                    && AppDelegate.closeDecision(for: .alertThirdButtonReturn, canSave: true)
                        == .discard
                    && AppDelegate.closeDecision(for: .alertFirstButtonReturn, canSave: false)
                        == .discard,
                "close prompt responses map to save, discard and cancel")
        }
        hex.discardChanges()
        check(!hex.isDirty && bytes(0x10..<0x11) == [0x10], "Discard drops the edits")
        type("\t", in: window)  // back to the hex column

    }

    /// M3b saving in the running app, on a file of its own: a save swaps in a new file,
    /// and the tab keeps reading the one it opened.
    func saving(_ check: (Bool, String) -> Void, window target: NSWindow) async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-save-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        do { try Data((0..<256).map { UInt8($0) }).write(to: url) } catch {
            return check(false, "write a sample to save: \(error)")
        }
        guard let hex = app.openFile(url), let controller = app.controller(containing: hex.id),
            let window = controller.window
        else { return check(false, "the save sample opens") }
        defer { controller.layout.remove(hex.id) }
        check(window === target, "it opens in the window under test")
        await settle()
        window.makeFirstResponder(hex.hexView)
        func disk(_ range: Range<Int>) -> [UInt8] {
            (try? Data(contentsOf: url)).map { Array($0[range]) } ?? []
        }
        func saved() async {
            for _ in 0..<100 where hex.isDirty || hex.session.isSaving {
                await settle(milliseconds: 20)
            }
        }
        let save = #selector(HexEditorActions.editorSave(_:))
        hex.hexView.go(to: 0x20)
        type("7E", in: window)
        // M3c: the first edit made the session's folder, with a clone of the file.
        let made = hex.session.folder
        check(
            made.map { FileManager.default.fileExists(atPath: $0.file("original.clone").path) }
                == true && !hex.session.isNarrowed,
            "the first edit clones the file into the session's folder")
        check(menu(save, key: "s", in: window), "File › Save (⌘S) reaches the editor")
        await saved()
        check(!hex.isDirty && disk(0x20..<0x21) == [0x7E], "the save reaches the file")
        let undo = #selector(HexEditorActions.undo(_:))
        check(menu(undo, key: "z", in: window) && hex.isDirty, "undo after a save is unsaved")
        check(menu(save, key: "s", in: window), "and File › Save saves it")
        await saved()
        check(disk(0x20..<0x21) == [0x20], "which puts the original byte back")

        // Save As: the menu item is there with ⇧⌘S; the panel itself can't be driven
        // here, so the tab's saveAs stands in for its OK button.
        let action = #selector(HexEditorActions.editorSaveAs(_:))
        let saveAs = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.action == action }
        var responder = window.firstResponder
        while let current = responder, !current.responds(to: action) {
            responder = current.nextResponder
        }
        let enabled = saveAs.flatMap { item in
            (responder as? NSMenuItemValidation)?.validateMenuItem(item)
        }
        check(
            saveAs?.keyEquivalent == "s" && saveAs?.keyEquivalentModifierMask == [.command, .shift]
                && responder != nil && enabled != false,
            "File › Save As… (⇧⌘S) reaches the editor and is enabled")
        let copy = url.deletingLastPathComponent()
            .appendingPathComponent("smoke-save-as-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: copy) }
        hex.hexView.go(to: 0x21)
        type("11", in: window)
        do { try await hex.saveAs(to: copy) } catch { check(false, "Save As: \(error)") }
        check(
            hex.title == copy.lastPathComponent && !hex.isDirty
                && (try? Data(contentsOf: copy))?[0x21] == 0x11,
            "Save As writes the new file and the tab follows it")
        check(
            app.recentFiles.entries.contains { $0.url.lastPathComponent == copy.lastPathComponent },
            "the new file is a recent file")

        // Closing with unsaved edits: the real close sheet, and its Save button.
        type("22", in: window)
        controller.layout.select(hex.id)
        check(dispatch(KeyChord("w", .command), in: window), "⌘W closes the edited tab")
        var sheet: NSWindow?
        for _ in 0..<50 where sheet == nil {
            await settle(milliseconds: 20)
            sheet = window.attachedSheet
        }
        let button = sheet.flatMap { Self.button("Save", in: $0.contentView) }
        check(button != nil, "the close sheet offers Save")
        button?.performClick(nil)
        for _ in 0..<100 where controller.layout.item(hex.id) != nil {
            await settle(milliseconds: 20)
        }
        check(
            controller.layout.item(hex.id) == nil && (try? Data(contentsOf: copy))?[0x22] == 0x22,
            "Save in the close sheet saves, then closes the tab")
        for _ in 0..<50
        where made.map({ FileManager.default.fileExists(atPath: $0.url.path) }) == true {
            await settle(milliseconds: 20)
        }
        check(
            made.map { !FileManager.default.fileExists(atPath: $0.url.path) } == true,
            "closing the tab deletes the session's folder")
    }

    /// The button titled `title` under `view`, for pressing a sheet's buttons.
    static func button(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(title, in: $0) }.first
    }

    /// A file without write permission opens read-only (M3b, D-b): typing changes
    /// nothing and the status line says why.
    func readOnlyFile(_ check: (Bool, String) -> Void, window target: NSWindow) async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-readonly-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try Data(repeating: 0x11, count: 64).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o444], ofItemAtPath: url.path)
        } catch {
            return check(false, "write a read-only sample: \(error)")
        }
        guard let item = app.openFile(url), let controller = app.controller(containing: item.id),
            let window = controller.window
        else { return check(false, "a read-only file opens") }
        check(window === target, "it opens in the window under test")
        defer { controller.layout.remove(item.id) }
        await settle()
        window.makeFirstResponder(item.hexView)
        type("FF", in: window)
        check(
            (try? item.read(0..<1)) == Data([0x11]) && !item.isDirty,
            "typing into a read-only file changes nothing")
        let status = self.status(of: controller)
        check(status.contains("read-only"), "the status line says why: \(status)")
    }

    /// Edits near the end of a 4 GiB file, and while a Find All scans all of it.
    func editingLargeFile(_ check: (Bool, String) -> Void, item: HexEditorItem) async {
        guard let window = item.viewController.view.window else {
            return check(false, "the 4 GiB tab has a window")
        }
        window.makeFirstResponder(item.hexView)
        let last = item.length - 1
        // Typing a hex digit on an uncached offset falls back to a 1-byte read cleanly.
        item.hexView.go(to: last)
        type("7F", in: window)
        check((try? item.read(last..<item.length)) == Data([0x7F]), "edit at the end of 4 GiB")
        // Saving clones the 4 GiB file and patches one byte: near-instant.
        var saveError: Error?
        let saving = await ContinuousClock().measure {
            do { try await item.save() } catch { saveError = error }
        }
        print("  info saving one byte of a 4 GiB file took \(saving)")
        check(
            saveError == nil && !item.isDirty,
            "save at the end of 4 GiB: \(saveError.map { "\($0)" } ?? "ok")")
        check(saving < .seconds(2), "and it is near-instant (\(saving))")

        // Move to 1 GiB and warm its page before starting the scan so typing overlaps it.
        item.hexView.go(to: 1 << 30)
        item.hexView.display()
        for _ in 0..<50 where item.cachedBytes((1 << 30)..<((1 << 30) + 1)) == nil {
            await settle(milliseconds: 20)
        }

        let searcher = Searcher(source: item.snapshot)
        let state = SearchState()
        let search = Task {
            defer { state.finish() }
            return try await Searcher.run { token in
                try searcher.all(try SearchPattern.hex("7F"), cancellation: token) { _, _ in
                    state.noteStarted()
                }
            }
        }
        await state.waitUntilStarted()
        let clock = ContinuousClock()
        let typing = clock.measure { type("7F", in: window) }
        let frame = clock.measure { item.hexView.display() }
        let overlapped = !state.isFinished
        let result = try? await search.value
        print(
            "  info typing during 4 GiB Find All took \(typing), frame \(frame)"
                + (overlapped ? " (overlapped)" : " (search finished first)"))
        check(typing < .milliseconds(100), "an edit doesn't wait for a running search (\(typing))")
        check(
            result?.ranges == [last..<item.length],
            "the search reports the file as it was when it started")
        item.discardChanges()
    }
}

/// Tracks start and completion of a background search across threads.
private final class SearchState: Sendable {
    private struct Flags {
        var started = false
        var finished = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(Flags())

    func noteStarted() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            guard !s.started else { return [] }
            s.started = true
            let list = s.waiters
            s.waiters.removeAll()
            return list
        }
        for waiter in waiters { waiter.resume() }
    }

    func finish() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.finished = true
            s.started = true
            let list = s.waiters
            s.waiters.removeAll()
            return list
        }
        for waiter in waiters { waiter.resume() }
    }

    var isFinished: Bool { state.withLock { $0.finished } }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { s -> Bool in
                if s.started { return true }
                s.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
