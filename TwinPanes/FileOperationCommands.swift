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
    private var isUndoingOrRedoing = false

    init(
        grants: FolderGrants, fileSystem: any FileOperationSystem = RealFileOperationSystem(),
        windows: @escaping () -> [MainWindowController]
    ) {
        self.grants = grants
        self.fileSystem = fileSystem
        self.windows = windows
        queue = FileOperationQueue(fileSystem: fileSystem)
    }

    /// The progress strip for `controller`'s window: its own operations, and those of
    /// windows that have closed when it's the first window.
    func makeStrip(for controller: MainWindowController) -> OperationsStripViewController {
        OperationsStripViewController(queue: queue) { [weak self, weak controller] operation in
            guard let self, let controller else { return false }
            return self.window(of: operation) === controller
        }
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
        let running = queue.operations.filter { $0.result == nil }
        for operation in running { operation.cancel() }
        for operation in running { _ = await operation.finished() }
        return true
    }

    // MARK: FileCommandHandling

    func perform(_ command: FileCommand, in browser: BrowserItem) {
        guard let controller = controller(showing: browser), let window = controller.window
        else { return NSSound.beep() }
        let sources = browser.selectedEntries.map(\.url)
        switch command {
        case .copyToOtherPanel, .moveToOtherPanel:
            askDestination(
                for: command, sources: sources, from: browser, controller: controller, on: window)
        case .rename:
            guard let item = sources.first else { return NSSound.beep() }
            askName(
                TextSheet(
                    message: "Rename “\(item.lastPathComponent)” to:",
                    text: item.lastPathComponent, selecting: .nameWithoutExtension,
                    confirm: "Rename"),
                on: window, request: { name in .rename(item, to: name) },
                then: { result in
                    if case .renamed(.success(let moved)) = result {
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
                then: { result in
                    if case .madeFolder(.success(let made)) = result {
                        browser.selectWhenListed(made.lastPathComponent)
                    }
                }, from: controller)
        case .trash:
            Task { await run(.trash(sources), from: controller) }
        case .deletePermanently:
            DeleteConfirmation.makeAlert(for: sources).beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                Task { await self.run(.delete(sources), from: controller) }
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
        _ request: OperationRequest, from controller: MainWindowController
    ) async
        -> OperationResult
    {
        let result = await add(request, from: controller).finished()
        if let change = FileChange(request: request, result: result) { history.record(change) }
        return result
    }

    private func add(
        _ request: OperationRequest, from controller: MainWindowController
    )
        -> QueuedOperation
    {
        let operation = queue.add(request, scopes: scopes(for: request)) {
            [weak self] op, conflict in
            guard let window = self?.window(of: op)?.window else { return ConflictAnswer(.stop) }
            return await ConflictSheet(conflict).ask(on: window)
        }
        origins[operation.id] = { [weak controller] in controller }
        return operation
    }

    /// The access an operation keeps until it ends (§5): its items' and destination's
    /// folder grants.
    private func scopes(for request: OperationRequest) -> [SecurityScope] {
        let urls: [URL] =
            switch request {
            case .copy(let items, let destination), .move(let items, let destination):
                items + [destination]
            case .trash(let items), .delete(let items): items
            case .putBack(let items): items.flatMap { [$0.from, $0.to] }
            case .rename(let item, _): [item]
            case .makeFolder(_, let folder): [folder]
            }
        return urls.compactMap { grants.scope(covering: $0) }
    }

    private func undo(from controller: MainWindowController) {
        guard !isUndoingOrRedoing, let change = history.takeUndo() else { return NSSound.beep() }
        isUndoingOrRedoing = true
        Task {
            for request in change.undoRequests ?? [] {
                _ = await add(request, from: controller).finished()
            }
            history.didUndo(change)
            isUndoingOrRedoing = false
        }
    }

    private func redo(from controller: MainWindowController) {
        guard !isUndoingOrRedoing, let change = history.takeRedo() else { return NSSound.beep() }
        isUndoingOrRedoing = true
        Task {
            let result = await add(change.request, from: controller).finished()
            if let again = FileChange(request: change.request, result: result) {
                history.didRedo(again)
            }
            isUndoingOrRedoing = false
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
        sheet.begin(on: window) { [self] typed in
            guard let typed else { return }
            let again = { (reason: String) in
                DispatchQueue.main.async {
                    self.askDestination(
                        for: command, sources: sources, from: browser, controller: controller,
                        on: window, text: typed, refusal: reason)
                }
            }
            guard
                let destination = DestinationPath.resolve(
                    typed, from: browser.folder, home: DirectoryReader.realHomeDirectory)
            else { return again("Type the folder to \(isMove ? "move" : "copy") to.") }
            do throws(PlanningRefusal) {
                try OperationPlanner(fileSystem: fileSystem).check(
                    sources: sources, destination: destination)
            } catch {
                return again(Self.reason(for: error))
            }
            let request: OperationRequest =
                isMove ? .move(sources, into: destination) : .copy(sources, into: destination)
            Task { await self.run(request, from: controller) }
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
        sheet.begin(on: window) { [self] name in
            guard let name else { return }
            Task {
                let result = await self.run(request(name), from: controller)
                if let refusal = result.refusal {
                    let retry = TextSheet(
                        message: sheet.alert.messageText, text: name, selecting: .all,
                        confirm: sheet.alert.buttons[0].title)
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
        origins[operation.id]?() ?? windows().first
    }

    /// The other panel's folder: its front tab if that's a browser, otherwise its most
    /// recently shown browser tab (D45 guarantees one).
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
