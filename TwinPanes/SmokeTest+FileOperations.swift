import AppKit
import BrowserKit
import EditorKit
import TwinPanesCore
import WorkspaceKit

extension SmokeTest {
    /// File operations with real keys and real sheets (docs/plans/M6.md, step 18): F5,
    /// the conflict sheet, F6, F2, F7, F8 and undo, ⇧F8. Everything happens in a temp
    /// folder; what went to the real Trash is removed at the end.
    func fileOperations(
        _ check: (Bool, String) -> Void, in controller: MainWindowController
    )
        async
    {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "smoke-ops-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("src", isDirectory: true)
        let destination = root.appendingPathComponent("dest", isDirectory: true)
        defer {
            if let window = controller.window { closeLeftoverSheet(on: window) }
            removeWhatWentToTheTrash()
            try? fm.removeItem(at: root)
        }
        do {
            try fm.createDirectory(
                at: source.appendingPathComponent("docs"), withIntermediateDirectories: true)
            try fm.createDirectory(
                at: source.appendingPathComponent("merge"), withIntermediateDirectories: true)
            try fm.createDirectory(
                at: destination.appendingPathComponent("merge"), withIntermediateDirectories: true)
            try Data("alpha".utf8).write(to: source.appendingPathComponent("a.txt"))
            try Data("beta".utf8).write(to: source.appendingPathComponent("b.txt"))
            try Data("x".utf8).write(to: source.appendingPathComponent("docs/x.txt"))
            try Data("y".utf8).write(to: source.appendingPathComponent("merge/y.txt"))
            try Data("x".utf8).write(to: destination.appendingPathComponent("merge/x.txt"))
        } catch {
            return check(false, "make the file operations' folders: \(error)")
        }
        let layout = controller.layout
        let base = operationTally.count
        guard let window = controller.window,
            let left = layout.selectedItem(in: .leftPanel) as? BrowserItem,
            let right = layout.selectedItem(in: .rightPanel) as? BrowserItem
        else { return check(false, "the window shows two browsers") }
        let (leftFolder, rightFolder, activePanel) = (left.folder, right.folder, layout.activePanel)
        layout.activate(.leftPanel)
        left.go(to: source)
        right.go(to: destination)
        await left.listed()
        await right.listed()
        await runFileOperations(
            check, left: left, source: source, destination: destination, window: window, base: base)
        await finishAndCleanTrash(on: window)
        // The checks after these expect the window as it was, and the progress strip empty
        // again (finished rows linger a few seconds).
        left.go(to: leftFolder)
        right.go(to: rightFolder)
        await left.listed()
        await right.listed()
        layout.activate(activePanel)
        window.makeFirstResponder(left.preferredFirstResponder)
        let strip = controller.frameController.bottomAccessory?.view
        for _ in 0..<250 where (strip?.fittingSize.height ?? 0) >= 1 {
            await settle(milliseconds: 20)
        }
    }

    private func runFileOperations(
        _ check: (Bool, String) -> Void, left: BrowserItem, source: URL, destination: URL,
        window: NSWindow, base: Int
    ) async {
        let fm = FileManager.default
        func select(_ names: [String]) { Self.select(names, in: left, window: window) }
        func exists(_ url: URL, _ path: String) -> Bool {
            fm.fileExists(atPath: url.appendingPathComponent(path).path)
        }

        // F5: the sheet offers the other panel's folder; Return copies.
        select(["a.txt", "docs"])
        check(dispatch(.function(5), in: window), "F5 dispatched")
        let field = sheetField(of: window)
        check(
            field?.stringValue == destination.standardizedFileURL.path,
            "F5's sheet offers the other panel's folder: \(field?.stringValue ?? "no sheet")")
        confirm("Copy", inSheetOf: window)
        guard await sheetClosed(on: window) else {
            return check(false, "Return confirms F5's sheet")
        }
        await operationsFinished(count: base + 1)
        check(
            (try? String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8))
                == "alpha" && exists(destination, "docs/x.txt"),
            "F5 copies the selection to the other panel: \(Self.queueReport(app.fileOperations.queue, base: base)), sheet \(window.attachedSheet.map { Self.labels(in: $0.contentView ?? NSView()).joined(separator: " | ") } ?? "none")"
        )

        // F5 again: the conflict sheet; Keep Both for all.
        select(["a.txt", "docs"])
        _ = dispatch(.function(5), in: window)
        confirm("Copy", inSheetOf: window)
        // Apply to All covers one kind: the file and the folder each ask once.
        var asked = 0
        while asked < 2, await sheetTitled("already exists", on: window) {
            let sheet = window.attachedSheet
            clickCheckbox("Apply to All", inSheetOf: window)
            clickButton("Keep Both", inSheetOf: window)
            asked += 1
            await waitForSheetChange(from: sheet, on: window)
        }
        check(asked == 2, "taken names bring up the conflict sheet, once per kind: \(asked)")
        await operationsFinished(count: base + 2)
        check(
            exists(destination, "a 2.txt") && exists(destination, "docs 2/x.txt"),
            "Keep Both, applied to all, copies under the next names")

        // F6 with Replace: the moved file takes the old one's place, which goes to the Trash.
        select(["a.txt"])
        _ = dispatch(.function(6), in: window)
        confirm("Move", inSheetOf: window)
        if await sheetTitled("already exists", on: window) {
            let sheet = window.attachedSheet
            clickButton("Replace", inSheetOf: window)
            await waitForSheetChange(from: sheet, on: window)
        }
        await operationsFinished(count: base + 3)
        check(
            !exists(source, "a.txt") && exists(destination, "a.txt"),
            "F6 with Replace moves the file over the old one")

        // F5 with Merge: copying a folder over an existing folder keeps existing files too.
        select(["merge"])
        _ = dispatch(.function(5), in: window)
        confirm("Copy", inSheetOf: window)
        if await sheetTitled("already exists", on: window) {
            let sheet = window.attachedSheet
            clickButton("Merge", inSheetOf: window)
            await waitForSheetChange(from: sheet, on: window)
        }
        await operationsFinished(count: base + 4)
        check(
            exists(destination, "merge/x.txt") && exists(destination, "merge/y.txt"),
            "Merge keeps existing files and copies new ones")

        // F5 copy followed by ⌘Z moves the copied item to the Trash.
        select(["b.txt"])
        _ = dispatch(.function(5), in: window)
        confirm("Copy", inSheetOf: window)
        guard await sheetClosed(on: window) else {
            return check(false, "Return confirms F5's sheet for copy-undo")
        }
        await operationsFinished(count: base + 5)
        check(exists(destination, "b.txt"), "F5 copies b.txt to the other panel")
        await undo(
            check, expectingTitle: "Undo Copy of “b.txt”", operationCount: base + 6, in: window)
        check(!exists(destination, "b.txt"), "⌘Z after a copy moves the copied item to the Trash")

        await renameAndNewFolder(
            check, left: left, source: source, window: window, base: base + 6)
        await trashAndDelete(
            check, left: left, source: source, window: window, base: base + 8, select: select)
    }

    /// F2 renames "docs"; F7 makes a folder, which ends up selected.
    private func renameAndNewFolder(
        _ check: (Bool, String) -> Void, left: BrowserItem, source: URL, window: NSWindow,
        base: Int
    ) async {
        let fm = FileManager.default
        Self.select(["docs"], in: left, window: window)
        _ = dispatch(.function(2), in: window)
        sheetField(of: window)?.stringValue = "renamed"
        confirm("Rename", inSheetOf: window)
        await operationsFinished(count: base + 1)
        for _ in 0..<100 {
            if left.selectedName == "renamed" { break }
            await settle(milliseconds: 20)
        }
        check(
            fm.fileExists(atPath: source.appendingPathComponent("renamed/x.txt").path)
                && left.selectedName == "renamed",
            "F2 renames and selects the new name (selected: \(left.selectedName ?? "nil"))")
        _ = dispatch(.function(7), in: window)
        sheetField(of: window)?.stringValue = "made"
        confirm("Create", inSheetOf: window)
        await operationsFinished(count: base + 2)
        for _ in 0..<100 {
            if left.selectedName == "made" { break }
            await settle(milliseconds: 20)
        }
        check(
            fm.fileExists(atPath: source.appendingPathComponent("made").path)
                && left.selectedName == "made",
            "F7 makes a folder and selects it")
    }

    /// F8 trashes "made" and ⌘Z puts it back; ⇧F8 deletes "renamed" after ⌘D.
    private func trashAndDelete(
        _ check: (Bool, String) -> Void, left: BrowserItem, source: URL, window: NSWindow,
        base: Int, select: ([String]) -> Void
    ) async {
        let made = source.appendingPathComponent("made")
        let fm = FileManager.default
        select(["made"])
        _ = dispatch(.function(8), in: window)
        await operationsFinished(count: base + 1)
        check(!fm.fileExists(atPath: made.path), "F8 moves the folder to the Trash")
        await undo(
            check, expectingTitle: "Undo Move to Trash", operationCount: base + 2, in: window)
        check(fm.fileExists(atPath: made.path), "⌘Z puts it back from the Trash")

        select(["renamed"])
        check(dispatch(KeyChord.function(8, .shift), in: window), "⇧F8 dispatched")
        let confirm = window.attachedSheet
        pressKey("d", modifiers: .command, inSheetOf: window)
        await operationsFinished(count: base + 3)
        check(
            confirm != nil && !fm.fileExists(atPath: source.appendingPathComponent("renamed").path),
            "⇧F8 deletes after its confirmation")
    }

    // MARK: Helpers

    /// What the queue holds since `base`, for a failed check's message.
    private static func queueReport(_ queue: FileOperationQueue, base: Int) -> String {
        queue.operations.dropFirst(base).map { operation in
            "\(operation.request) → \(operation.result.map { "failures \($0.failures), cancelled \($0.wasCancelled)" } ?? "running")"
        }.joined(separator: "; ")
    }

    /// Selects `names` in `browser`'s file list, its first responder; row 0 is "..".
    private static func select(_ names: [String], in browser: BrowserItem, window: NSWindow) {
        guard let table = browser.preferredFirstResponder as? NSTableView else { return }
        let rows = names.compactMap { name in
            browser.entries.firstIndex { $0.name == name }.map { $0 + 1 }
        }
        window.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    /// Waits for every queued operation, and for the sheets they were asked on to close.
    /// Waits until the queue has held `count` operations in all (a confirmed sheet queues its
    /// operation a moment later), then for all of them to finish.
    /// Gives up after about 10 s, so an operation stuck on an unanswered sheet fails its
    /// check instead of the whole run.
    func operationsFinished(count: Int) async {
        let queue = app.fileOperations.queue
        for _ in 0..<500 {
            if operationTally.count >= count, queue.operations.allSatisfy({ $0.result != nil }) {
                break
            }
            await settle(milliseconds: 20)
        }
        await settle(milliseconds: 50)
    }

    private func sheetField(of window: NSWindow) -> NSTextField? {
        window.attachedSheet?.contentView.flatMap { Self.view(in: $0, id: "operationSheetField") }
            as? NSTextField
    }

    private func sheetTitled(_ text: String, on window: NSWindow) async -> Bool {
        for _ in 0..<200 {
            if let content = window.attachedSheet?.contentView,
                Self.labels(in: content).contains(where: { $0.contains(text) })
            {
                return true
            }
            await settle(milliseconds: 20)
        }
        return false
    }

    private static func labels(in view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? [])
            + view.subviews.flatMap { labels(in: $0) }
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }

    private func clickButton(_ title: String, inSheetOf window: NSWindow) {
        guard let content = window.attachedSheet?.contentView else { return }
        Self.buttons(in: content).first { $0.title == title }?.performClick(nil)
    }

    private func clickCheckbox(_ title: String, inSheetOf window: NSWindow) {
        guard let content = window.attachedSheet?.contentView else { return }
        Self.buttons(in: content).first { $0.title == title }?.state = .on
    }

    /// Return in a sheet: clicks its confirming button, the one bound to Return. Found by
    /// its title, since an alert binds Return to its first button only as it lays out.
    private func confirm(_ title: String, inSheetOf window: NSWindow) {
        clickButton(title, inSheetOf: window)
    }

    /// A key in a sheet as AppKit routes key equivalents there: to the button bound to it.
    private func pressKey(
        _ key: String, modifiers: NSEvent.ModifierFlags, inSheetOf window: NSWindow
    ) {
        guard let content = window.attachedSheet?.contentView else { return }
        Self.buttons(in: content).first {
            $0.keyEquivalent == key && $0.keyEquivalentModifierMask.contains(modifiers)
        }?.performClick(nil)
    }

    /// Whether the sheet a key closed is gone; one that stays is closed here, so the
    /// checks after it aren't blocked.
    private func sheetClosed(on window: NSWindow) async -> Bool {
        for _ in 0..<50 where window.attachedSheet != nil { await settle(milliseconds: 20) }
        guard window.attachedSheet == nil else {
            closeLeftoverSheet(on: window)
            return false
        }
        return true
    }

    /// Waits until `sheet` is no longer `window.attachedSheet` (dismissed or replaced).
    private func waitForSheetChange(from sheet: NSWindow?, on window: NSWindow) async {
        guard let sheet else { return }
        for _ in 0..<100 {
            if window.attachedSheet !== sheet { break }
            await settle(milliseconds: 20)
        }
    }

    /// Triggers Edit › Undo through the responder chain and waits for the undo operation.
    private func undo(
        _ check: (Bool, String) -> Void, expectingTitle title: String, operationCount: Int,
        in window: NSWindow
    ) async {
        let undoAction = #selector(HexEditorActions.undo(_:))
        let item = NSMenuItem(title: "Undo", action: undoAction, keyEquivalent: "")
        let handler = CommandDispatcher.target(for: undoAction, in: window)
        let canUndo = (handler as? NSMenuItemValidation)?.validateMenuItem(item) ?? false
        check(canUndo && item.title == title, "Edit › Undo reads \(item.title)")
        guard canUndo else { return }
        NSApp.sendAction(undoAction, to: handler, from: nil)
        for _ in 0..<200 {
            if app.fileOperations.history.nextRedo != nil { break }
            await settle(milliseconds: 20)
        }
        await operationsFinished(count: operationCount)
    }

    /// Closes a sheet a failed check left open, so the checks after it aren't blocked.
    private func closeLeftoverSheet(on window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
    }

    /// Cancels any still-running or waiting operations and awaits their finish before
    /// cleaning the Trash, so failed or early-return paths leave nothing in-flight.
    private func finishAndCleanTrash(on window: NSWindow) async {
        closeLeftoverSheet(on: window)
        let pending = app.fileOperations.queue.operations.filter { $0.result == nil }
        for operation in pending { operation.cancel() }
        for operation in pending { _ = await operation.finished() }
        removeWhatWentToTheTrash()
    }

    /// The smoke test never leaves anything in the user's Trash: everything its
    /// operations sent there is removed for good.
    private func removeWhatWentToTheTrash() {
        for operation in app.fileOperations.queue.operations {
            let trashed: [TrashedItem] =
                switch operation.result {
                case .trashed(let outcome): outcome.trashed
                case .copied(let outcome): outcome.replaced
                case .moved(let outcome): outcome.replaced
                default: []
                }
            for item in trashed { try? FileManager.default.removeItem(at: item.trashed) }
        }
    }
}

/// How many operations the queue has held since the smoke test started counting. A
/// finished operation leaves the queue once its strip row is dismissed, so the queue's
/// own count can't say how many have run.
@MainActor
final class OperationTally {
    private var seen: Set<QueuedOperation.ID> = []
    /// Keeps the observation alive. Two modules name their token type ObservationToken.
    private var token: AnyObject?

    init(queue: FileOperationQueue) {
        note(queue)
        token = queue.observe { [weak self, weak queue] in
            guard let queue else { return }
            self?.note(queue)
        }
    }

    var count: Int { seen.count }

    private func note(_ queue: FileOperationQueue) {
        seen.formUnion(queue.operations.map(\.id))
    }
}

extension SmokeTest {
    /// One tally for the whole run, started on first use.
    @MainActor private static var tally: OperationTally?

    var operationTally: OperationTally {
        if let tally = Self.tally { return tally }
        let tally = OperationTally(queue: app.fileOperations.queue)
        Self.tally = tally
        return tally
    }
}
