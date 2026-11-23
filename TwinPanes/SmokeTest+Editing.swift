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

    /// Chooses an Edit menu item the way AppKit does for a key window: the first object
    /// in the first responder's chain that implements the action validates and performs
    /// it. (The smoke-test app isn't frontmost, so its window never becomes key and
    /// the menu's own key-equivalent path has no target.) Checks the key equivalent too.
    func menu(_ title: String, in window: NSWindow) -> Bool {
        guard let item = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu?.item(withTitle: title),
            item.keyEquivalent.lowercased() == "z", let action = item.action
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

        check(menu("Undo", in: window), "Edit › Undo (⌘Z) reaches the editor")
        check(bytes(0x11..<0x13) == [0x11, 0x12], "Undo reverts the text-column typing")
        check(menu("Undo", in: window), "Undo again")
        check(bytes(0x10..<0x11) == [0x10] && !hex.isDirty, "Undo again reverts the hex typing")
        check(menu("Redo", in: window), "Edit › Redo (⇧⌘Z) reaches the editor")
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
