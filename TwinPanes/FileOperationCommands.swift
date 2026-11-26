import AppKit
import BrowserKit
import TwinPanesCore
import WorkspaceKit

/// Runs the browsers' file commands (docs/plans/M6.md): asks through the sheets, queues
/// the operation with its folders' access, records it for undo, and shows its progress
/// in the window it was started from.
@MainActor
final class FileOperationCommands: FileCommandHandling {
    let queue: FileOperationQueue
    let history = FileOperationHistory()
    private let fileSystem: any FileOperationSystem
    private let grants: FolderGrants
    private let windows: () -> [MainWindowController]
    /// The window each operation was started from, held weakly.
    private var origins: [QueuedOperation.ID: () -> MainWindowController?] = [:]
    private var strips: [() -> OperationsStripViewController?] = []
    private nonisolated(unsafe) var windowCloseObserver: (any NSObjectProtocol)?
    private var isUndoingOrRedoing = false
    private var isQuitting = false

    init(
        grants: FolderGrants, fileSystem: any FileOperationSystem = RealFileOperationSystem(),
        windows: @escaping () -> [MainWindowController]
    ) {
        self.grants = grants
        self.fileSystem = fileSystem
        self.windows = windows
        queue = FileOperationQueue(fileSystem: fileSystem)
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Run after MainWindowController.windowWillClose updates windowControllers.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refreshStripsAfterWindowClose() }
            }
        }
    }

    deinit {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
    }

    /// The progress strip for `controller`'s window: its own operations, and those of
    /// windows that have closed when it's the first window.
    func makeStrip(for controller: MainWindowController) -> OperationsStripViewController {
        let strip = OperationsStripViewController(
            queue: queue,
            shows: { [weak self, weak controller] operation in
                guard let self, let controller else { return false }
                return self.window(of: operation) === controller
            },
            onDismiss: { [weak self] id in
                self?.queue.removeFinished(id)
                self?.origins.removeValue(forKey: id)
            })
        strips.append { [weak strip] in strip }
        return strip
    }

    var hasRunningOperations: Bool { queue.operations.contains { $0.result == nil } }

    /// Asks before quitting while operations run; if the user quits, cancels them and
    /// returns once they've stopped (a partial copy is removed).
    func stopForQuit() async -> Bool {
        let alert = NSAlert()
        alert.messageText = "File operations are still running. Quit anyway?"
        alert.informativeText = "They stop where they are; a partly copied file is removed."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        isQuitting = true
        defer { isQuitting = false }
        while true {
            let running = queue.operations.filter { $0.result == nil }
            guard !running.isEmpty else { return true }
            for operation in running { operation.cancel() }
            for operation in running { _ = await operation.finished() }
        }
    }

    // MARK: FileCommandHandling

    func perform(_ command: FileCommand, in browser: BrowserItem) {
        guard !isQuitting else { return }
        guard let controller = controller(showing: browser), let window = controller.window
        else { return NSSound.beep() }
        switch command {
        case .copyToOtherPanel, .moveToOtherPanel:
            let sources = browser.selectedEntries.map(\.url)
            guard !sources.isEmpty else { return NSSound.beep() }
            askDestination(
                for: command, sources: sources, from: browser, controller: controller, on: window)
        case .rename:
            guard let item = browser.selectedEntries.first?.url else { return NSSound.beep() }
            let expectedParent = item.deletingLastPathComponent()
            askName(
                TextSheet(
                    message: "Rename “\(item.lastPathComponent)” to:",
                    text: item.lastPathComponent, selecting: .nameWithoutExtension,
                    confirm: "Rename"),
                on: window, request: { name in .rename(item, to: name) },
                then: { [weak browser] result in
                    if case .renamed(.success(let moved)) = result,
                        let browser, BookmarkStore.pathsEqual(browser.folder, expectedParent)
                    {
                        browser.selectWhenListed(moved.to.lastPathComponent)
                    }
                }, from: controller)
        case .newFolder:
            let folder = browser.folder
            askName(
                TextSheet(
                    message: "New folder in “\(folder.lastPathComponent)”:",
                    text: "untitled folder", selecting: .all, confirm: "Create"),
                on: window, request: { name in .makeFolder(named: name, in: folder) },
                then: { [weak browser] result in
                    if case .madeFolder(.success(let made)) = result,
                        let browser, BookmarkStore.pathsEqual(browser.folder, folder)
                    {
                        browser.selectWhenListed(made.lastPathComponent)
                    }
                }, from: controller)
        case .trash:
            let sources = browser.selectedEntries.map(\.url)
            guard !sources.isEmpty else { return NSSound.beep() }
            let origin: () -> MainWindowController? = { [weak controller] in controller }
            Task { await run(.trash(sources), origin: origin) }
        case .deletePermanently:
            let sources = browser.selectedEntries.map(\.url)
            guard !sources.isEmpty else { return NSSound.beep() }
            DeleteConfirmation.makeAlert(for: sources).beginSheetModal(for: window) {
                [weak self, weak controller] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                let origin: () -> MainWindowController? = { [weak controller] in controller }
                Task { await self.run(.delete(sources), origin: origin) }
            }
        case .undo: undo(from: controller)
        case .redo: redo(from: controller)
        }
    }

    func validate(_ command: FileCommand, in browser: BrowserItem, menuItem: NSMenuItem) -> Bool {
        switch command {
        case .undo:
            menuItem.title =
                history.nextUndo.map { "Undo \($0.title)" }
                ?? (history.isBlockedByDelete ? "Can’t Undo Delete" : "Undo")
            return history.nextUndo != nil && !isUndoingOrRedoing
        case .redo:
            menuItem.title = history.nextRedo.map { "Redo \($0.title)" } ?? "Redo"
            return history.nextRedo != nil && !isUndoingOrRedoing
        default:
            return true
        }
    }

    // MARK: Running

    /// Queues `request`, waits for it and records it for undo.
    @discardableResult
    private func run(
        _ request: OperationRequest, scopes: [SecurityScope]? = nil,
        origin: @escaping () -> MainWindowController?
    ) async -> OperationResult {
        let operation = add(request, scopes: scopes, origin: origin)
        let result = await operation.finished()
        if let change = FileChange(request: request, result: result) { history.record(change) }
        return result
    }

    private func add(
        _ request: OperationRequest, scopes: [SecurityScope]? = nil,
        origin: @escaping () -> MainWindowController?
    ) -> QueuedOperation {
        let operation = queue.add(request, scopes: scopes ?? self.scopes(for: request)) {
            [weak self] op, conflict in
            guard let self, let window = self.window(of: op)?.window else {
                return ConflictAnswer(.stop)
            }
            if window.isMiniaturized { window.deminiaturize(nil) }
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            let sheet = ConflictSheet(conflict)
            op.onCancelWhileWaiting = { [weak sheet, weak window] in
                guard let sheet, let window else { return }
                sheet.dismiss(on: window)
            }
            defer { op.onCancelWhileWaiting = nil }
            return await sheet.ask(on: window)
        }
        origins[operation.id] = origin
        return operation
    }

    /// The access an operation keeps until it ends (§5): its items' and destination's
    /// folder grants, deduplicated per grant.
    private func scopes(for request: OperationRequest) -> [SecurityScope] {
        switch request {
        case .copy(let items, let destination), .move(let items, let destination):
            scopes(forItems: items, folders: [destination])
        case .trash(let items), .delete(let items):
            scopes(forItems: items, folders: [])
        case .putBack(let items):
            scopes(forItems: items.flatMap { [$0.from, $0.to] }, folders: [])
        case .rename(let item, _):
            scopes(forItems: [item], folders: [])
        case .makeFolder(_, let folder):
            scopes(forItems: [], folders: [folder])
        }
    }

    private func scopes(forItems items: [URL], folders: [URL]) -> [SecurityScope] {
        var candidates: [URL] = []
        var seenPaths: Set<String> = []
        var seenParents: Set<String> = []
        var lastParent = ""
        for folder in folders where seenPaths.insert(folder.path).inserted {
            candidates.append(folder)
        }
        let includeItems = items.count <= FolderListing.mainActorLimit
        for item in items {
            if includeItems {
                if seenPaths.insert(item.path).inserted { candidates.append(item) }
            } else if Self.hasParent(item.path, parent: lastParent) {
                continue
            }
            let parent = item.deletingLastPathComponent()
            lastParent = parent.path
            if seenParents.insert(lastParent).inserted { candidates.append(parent) }
        }
        var seenGrants: Set<String> = []
        var result: [SecurityScope] = []
        for candidate in candidates {
            guard let grant = grants.grant(covering: candidate),
                seenGrants.insert(grant.path).inserted,
                let scope = grants.scope(covering: candidate)
            else { continue }
            result.append(scope)
        }
        return result
    }

    private static func hasParent(_ path: String, parent: String) -> Bool {
        guard !parent.isEmpty, path.hasPrefix(parent) else { return false }
        var rest = path.dropFirst(parent.count)
        if !parent.hasSuffix("/") {
            guard rest.first == "/" else { return false }
            rest = rest.dropFirst()
        }
        return !rest.isEmpty && !rest.contains("/")
    }

    private func undo(from controller: MainWindowController) {
        guard !isUndoingOrRedoing, let (change, epoch) = history.takeUndoWithToken() else {
            return NSSound.beep()
        }
        isUndoingOrRedoing = true
        let origin: () -> MainWindowController? = { [weak controller] in controller }
        Task {
            defer { isUndoingOrRedoing = false }
            var allSucceeded = true
            var changedAnything = false
            for request in change.undoRequests ?? [] {
                let operation = add(request, origin: origin)
                let result = await operation.finished()
                if FileChange(request: request, result: result) != nil {
                    changedAnything = true
                }
                if result.wasCancelled || !result.failures.isEmpty {
                    allSucceeded = false
                    if result.wasCancelled { break }
                }
            }
            if allSucceeded {
                history.didUndo(change, epoch: epoch)
            } else if !changedAnything {
                history.restoreUndo(change, epoch: epoch)
            }
        }
    }

    private func redo(from controller: MainWindowController) {
        guard !isUndoingOrRedoing, let (change, epoch) = history.takeRedoWithToken() else {
            return NSSound.beep()
        }
        isUndoingOrRedoing = true
        let origin: () -> MainWindowController? = { [weak controller] in controller }
        Task {
            defer { isUndoingOrRedoing = false }
            let operation = add(change.request, origin: origin)
            let result = await operation.finished()
            if let again = FileChange(request: change.request, result: result) {
                history.didRedo(again, epoch: epoch)
            }
        }
    }

    // MARK: Sheets

    /// F5 and F6: asks where to, with the other panel's folder, and asks again with the
    /// reason when the answer can't work.
    private func askDestination(
        for command: FileCommand, sources: [URL], from browser: BrowserItem,
        controller: MainWindowController, on window: NSWindow, text: String? = nil,
        refusal: String? = nil
    ) {
        let isMove = command == .moveToOtherPanel
        let what =
            sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : "\(sources.count) items"
        let sheet = TextSheet(
            message: "\(isMove ? "Move" : "Copy") \(what) to:",
            text: text ?? otherFolder(of: browser, in: controller)?.path ?? browser.folder.path,
            selecting: .all, confirm: isMove ? "Move" : "Copy")
        if let refusal { sheet.refuse(refusal) }
        sheet.begin(on: window) { [weak self, weak browser, weak controller, weak window] typed in
            guard let self, let browser, let typed else { return }
            let again: (String) -> Void = { reason in
                DispatchQueue.main.async {
                    [weak self, weak browser, weak controller, weak window] in
                    guard let self, let browser, let controller, let window, window.isVisible,
                        self.windows().contains(where: { $0 === controller })
                    else { return }
                    self.askDestination(
                        for: command, sources: sources, from: browser, controller: controller,
                        on: window, text: typed, refusal: reason)
                }
            }
            guard
                let destination = DestinationPath.resolve(
                    typed, from: browser.folder, home: DirectoryReader.realHomeDirectory)
            else { return again("Type the folder to \(isMove ? "move" : "copy") to.") }
            let checkScopes = self.scopes(forItems: sources, folders: [destination])
            let fileSystem = self.fileSystem
            let origin: () -> MainWindowController? = { [weak controller] in controller }
            Task { [weak self] in
                let refusal: PlanningRefusal? = await Task.detached(priority: .userInitiated) {
                    withExtendedLifetime(checkScopes) {
                        do throws(PlanningRefusal) {
                            try OperationPlanner(fileSystem: fileSystem).check(
                                sources: sources, destination: destination)
                            return nil
                        } catch {
                            return error
                        }
                    }
                }.value
                guard let self else { return }
                if let refusal {
                    return again(Self.reason(for: refusal))
                }
                guard !self.isQuitting else { return }
                let request: OperationRequest =
                    isMove ? .move(sources, into: destination) : .copy(sources, into: destination)
                await self.run(request, scopes: checkScopes, origin: origin)
            }
        }
    }

    /// F2 and F7: asks for a name, runs the request, and asks again when the name is
    /// refused.
    private func askName(
        _ sheet: TextSheet, on window: NSWindow,
        request: @escaping (String) -> OperationRequest,
        then finished: @escaping (OperationResult) -> Void,
        from controller: MainWindowController
    ) {
        let message = sheet.alert.messageText
        let confirm = sheet.alert.buttons[0].title
        sheet.begin(on: window) { [weak self, weak controller, weak window] name in
            guard let self, let name else { return }
            let origin: () -> MainWindowController? = { [weak controller] in controller }
            Task { [weak self, weak controller, weak window] in
                guard let self else { return }
                let result = await self.run(request(name), origin: origin)
                if let refusal = result.refusal {
                    guard let controller, let window, window.isVisible,
                        self.windows().contains(where: { $0 === controller })
                    else { return }
                    let retry = TextSheet(
                        message: message, text: name, selecting: .all, confirm: confirm)
                    retry.refuse(Self.reason(for: refusal))
                    self.askName(
                        retry, on: window, request: request, then: finished, from: controller)
                } else {
                    finished(result)
                }
            }
        }
    }

    private static func reason(for refusal: PlanningRefusal) -> String {
        switch refusal {
        case .sourceMissing(let url): "“\(url.lastPathComponent)” is no longer there."
        case .intoItself(let url): "“\(url.lastPathComponent)” can’t go inside itself."
        case .destinationMissing(let url): "There’s no folder at \(url.path)."
        case .destinationNotWritable(let url):
            "Twin Panes can’t write to \(url.path). Open it in a panel to grant access first."
        }
    }

    private static func reason(for refusal: NameRefusal) -> String {
        switch refusal {
        case .empty: "Type a name."
        case .notAName: "A name can’t contain “/” or be “.” or “..”."
        case .tooLong: "That name is too long."
        case .taken(let url): "“\(url.lastPathComponent)” is already taken."
        case .failed(let error): error.description
        }
    }

    // MARK: Windows

    private func controller(showing browser: BrowserItem) -> MainWindowController? {
        windows().first { $0.layout.allItems.contains { $0 === browser } }
    }

    /// The window an operation's row and questions belong to: where it started, or the
    /// first window once that one has closed.
    private func window(of operation: QueuedOperation) -> MainWindowController? {
        if let origin = origins[operation.id]?(), windows().contains(where: { $0 === origin }) {
            return origin
        }
        return windows().first
    }

    private func refreshStripsAfterWindowClose() {
        strips.removeAll { $0() == nil }
        for ref in strips { ref()?.refresh() }
    }

    /// The other panel's folder: its front tab if that's a browser, otherwise its
    /// rightmost browser tab (D45 guarantees one).
    private func otherFolder(
        of browser: BrowserItem, in controller: MainWindowController
    )
        -> URL?
    {
        let layout = controller.layout
        guard let other = layout.slot(of: browser.id)?.otherPanel else { return nil }
        if let front = layout.selectedItem(in: other) as? BrowserItem { return front.folder }
        return layout.items(in: other).compactMap { $0 as? BrowserItem }.last?.folder
    }
}
