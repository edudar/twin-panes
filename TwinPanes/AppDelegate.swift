import AppKit
import BrowserKit
import EditorKit
import TwinPanesCore
import WorkspaceKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let registry = DefaultCommands.makeRegistry()
    lazy var dispatcher = CommandDispatcher(registry: registry)
    lazy var menuUpdater = MenuBindingUpdater(registry: registry)
    let workspace = WorkspaceRegistry()
    lazy var closeCoordinator = CloseCoordinator(
        openItems: { [workspace] in workspace.allItems },
        prompt: { [weak self] session in await self?.askToSave(session) ?? .cancel },
        onSaveError: { [weak self] session, error in
            await self?.presentCloseSaveError(error, session: session)
        })
    lazy var spike = SandboxSpike(app: self)
    private static var isIsolatedRun: Bool {
        ["--smoke-test", "--bench", SmokeChild.flag].contains(where: CommandLine.arguments.contains)
    }

    let recentFiles: RecentFiles
    /// One session per open file (docs/plans/M3b.md, D-a).
    let sessions: SessionRegistry

    private(set) var windowControllers: [MainWindowController] = []
    private var editorCount = 0
    private let isolatedGrantsFolder: URL?
    private let isolatedGrantsSuite: String?
    let folderGrants: FolderGrants
    /// The sidebar's favorites, kept with the grants: isolated in smoke and bench runs.
    let favorites: Favorites
    /// Small view choices kept for every window, such as hiding the function keys:
    /// isolated in smoke and bench runs.
    let preferences: UserDefaults
    /// Every file operation and its undo history, for all windows (docs/plans/M6.md).
    lazy var fileOperations = FileOperationCommands(grants: folderGrants) { [unowned self] in
        self.windowControllers
    }

    override init() {
        let child = SmokeChild(arguments: CommandLine.arguments)
        if Self.isIsolatedRun {
            let baseFolder =
                child?.folder
                ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("smoke-grants-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            let grantsDir =
                child != nil
                ? baseFolder.appendingPathComponent("grants", isDirectory: true) : baseFolder
            try? FileManager.default.createDirectory(
                at: grantsDir, withIntermediateDirectories: true)
            let suite = grantsDir.appendingPathComponent("defaults").path
            guard let defaults = UserDefaults(suiteName: suite) else {
                preconditionFailure("Unable to create isolated UserDefaults suite at \(suite)")
            }
            isolatedGrantsFolder = grantsDir
            isolatedGrantsSuite = suite
            folderGrants = FolderGrants(defaults: defaults)
            favorites = Favorites(defaults: defaults, home: DirectoryReader.realHomeDirectory)
            preferences = defaults

            let recentsDir = baseFolder.appendingPathComponent("recents", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: recentsDir, withIntermediateDirectories: true)
            let recentsSuite = recentsDir.appendingPathComponent("defaults").path
            guard let recentsDefaults = UserDefaults(suiteName: recentsSuite) else {
                preconditionFailure(
                    "Unable to create isolated UserDefaults suite at \(recentsSuite)")
            }
            recentFiles = RecentFiles(
                defaults: recentsDefaults,
                recordSystemRecents: false,
                isolatedFolder: recentsDir,
                isolatedSuite: recentsSuite)
            let sessionsRoot =
                child?.sessionsRoot
                ?? baseFolder.appendingPathComponent("Sessions", isDirectory: true)
            sessions = SessionRegistry(sessionsRoot: sessionsRoot)
        } else {
            isolatedGrantsFolder = nil
            isolatedGrantsSuite = nil
            folderGrants = FolderGrants()
            favorites = Favorites(defaults: .standard, home: DirectoryReader.realHomeDirectory)
            preferences = .standard
            recentFiles = RecentFiles()
            sessions = SessionRegistry(sessionsRoot: SessionFolder.defaultRoot)
        }
        super.init()
        if Self.isIsolatedRun { Self.ignoreSavedWindows() }
    }

    /// The smoke test and the benchmarks never restore the windows a normal launch saved
    /// (docs/plans/M5.md, D-c). Set in the argument domain, as `-ApplePersistenceIgnoreState
    /// YES` would be, so nothing is written to the user's defaults.
    private static func ignoreSavedWindows() {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["ApplePersistenceIgnoreState"] = true
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Rebuilds restored tabs (docs/plans/M5.md, D-c). Holds the app strongly: the app
    /// delegate lives as long as the process.
    lazy var itemRestorer: ItemRestorer = {
        var restorer = ItemRestorer()
        restorer.register(.browser, newestVersion: BrowserItem.stateVersion) { state in
            let browser = BrowserItem.restored(from: state, grants: self.folderGrants) {
                url, scope in
                self.openFile(url, scope: scope)
            }
            browser?.fileCommands = self.fileOperations
            return browser
        }
        restorer.register(.editor, newestVersion: HexEditorItem.stateVersion) { state in
            self.restoredEditor(from: state)
        }
        return restorer
    }()

    /// An editor tab on the file `state` names, opened the way Open Recent opens one,
    /// with its view put back. Nil when the file can't be reached any more: the
    /// restorer skips the tab.
    private func restoredEditor(from state: ItemState) -> HexEditorItem? {
        guard let saved = HexEditorItem.editorState(from: state),
            let (url, _) = BookmarkStore.resolve(saved.fileBookmark),
            let (session, _) = try? sessions.open(url, scope: SecurityScope(url: url)),
            editorItem(showing: session) == nil
        else { return nil }
        let item = HexEditorItem(session: session)
        item.didSaveAs = { [weak self] url in self?.recentFiles.note(url) }
        item.restoreView(saved)
        return item
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let child = SmokeChild(arguments: CommandLine.arguments) {
            child.run(app: self)
            return
        }
        if CommandLine.arguments.contains("--smoke-test") {
            SmokeTest(app: self, includeBenchmarks: CommandLine.arguments.contains("--bench")).run()
            return
        }
        if CommandLine.arguments.contains("--bench") {
            SmokeTest(app: self, includeBenchmarks: true).run()
            return
        }
        // Files from Finder's Open With may already have opened a window.
        if windowControllers.isEmpty { openMainWindow() }
        let unclaimed = launchRecovery?.takeUnclaimed { self.editorItem(showing: $0) != nil }
        showRecovered(unclaimed ?? [])
        launchRecovery = nil
        if let menu = NSApp.mainMenu { menuUpdater.refresh(menu) }
        NSApp.activate()
    }

    /// Crash recovery runs before AppKit restores windows, so a restored editor tab on a
    /// recovered file gets its session, edits and all (docs/plans/M5.md, D-c). The smoke
    /// test runs recovery itself, on its own folders.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(updater: menuUpdater, recentFiles: recentFiles)
        guard !Self.isIsolatedRun else {
            // Smoke and bench runs never become the active app, so they don't take focus
            // from what the developer is doing; their windows still show and draw. The
            // checks already work without a key window.
            NSApp.setActivationPolicy(.accessory)
            return
        }
        launchRecovery = LaunchRecovery(crashedSessions(), registry: sessions)
    }

    /// Holds the sessions recovered at launch until restored tabs have claimed theirs.
    private var launchRecovery: LaunchRecovery?

    /// Reopens, as dirty tabs, the sessions that crashed with unsaved edits, and deletes
    /// the folders of sessions that closed (docs/plans/M3c.md, D-f). A folder that can't
    /// be recovered stays for the next launch.
    @discardableResult
    func recoverCrashedSessions(in root: URL = SessionFolder.defaultRoot) -> [HexEditorItem] {
        let found = crashedSessions(in: root)
        for session in found { sessions.adopt(session) }
        return showRecovered(found)
    }

    func crashedSessions(in root: URL = SessionFolder.defaultRoot) -> [EditorSession] {
        SessionFolder.sweep(root).compactMap { folder in
            // A folder that can't be read stays for the next launch, as the sweep says.
            guard let session = try? EditorSession(recovering: folder) else { return nil }
            session.startWatching()
            return session
        }
    }

    @discardableResult
    func showRecovered(_ recovered: [EditorSession]) -> [HexEditorItem] {
        recovered.map { session in
            let item = HexEditorItem(session: session)
            item.didSaveAs = { [weak self] url in self?.recentFiles.note(url) }
            show(item)
            return item
        }
    }

    /// Finder "Open With", dropping files on the Dock icon, `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        openURLs(urls, in: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    )
        -> Bool
    {
        if !hasVisibleWindows { openMainWindow() }
        return true
    }

    /// The app quits without tearing sessions down: close them so their folders don't
    /// look like a crash at the next launch.
    func applicationWillTerminate(_ notification: Notification) {
        for session in sessions.sessions { session.close() }
        cleanUpIsolatedRun()
    }

    func cleanUpIsolatedRun() {
        recentFiles.cleanUp()
        if let isolatedGrantsSuite {
            UserDefaults().removePersistentDomain(forName: isolatedGrantsSuite)
        }
        if let isolatedGrantsFolder {
            try? FileManager.default.removeItem(at: isolatedGrantsFolder)
        }
    }

    /// Quitting waits for saves that are running, then runs the same close workflow as
    /// closing a tab or window: one sheet per dirty session, then quit (PLAN.md §4).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if fileOperations.hasRunningOperations {
            Task {
                guard await fileOperations.stopForQuit() else {
                    return NSApp.reply(toApplicationShouldTerminate: false)
                }
                // Asked again with nothing running: unsaved edits come next, and their
                // flow replies itself when it can't answer at once.
                if applicationShouldTerminate(sender) == .terminateNow {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
        }
        let items = workspace.allItems
        let saving = sessions.sessions.filter(\.isSaving)
        if saving.isEmpty, closeCoordinator.dirtySessions(closing: items).isEmpty {
            return .terminateNow
        }
        Task {
            while true {
                for session in sessions.sessions.filter(\.isSaving) {
                    await session.finishSaving()
                }
                let currentItems = workspace.allItems
                if closeCoordinator.dirtySessions(closing: currentItems).isEmpty {
                    if sessions.sessions.contains(where: \.isSaving) { continue }
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                guard await closeCoordinator.confirmClose(currentItems) else {
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
        }
        return .terminateLater
    }

    // MARK: Windows and items

    /// A new main window with the default browsers, or with the tabs and divider of
    /// `saved` when AppKit restores one.
    @discardableResult
    func openMainWindow(
        restoring saved: WindowState? = nil, show: Bool = true
    ) -> MainWindowController {
        let layout = MainFrameLayout(
            // Holds the app strongly: the app delegate lives as long as the process.
            filler: PanelFiller(kind: .browser) { panel, layout in
                let other = panel.otherPanel.flatMap { layout.selectedItem(in: $0) }
                return self.makeBrowser(at: (other as? BrowserItem)?.folder)
            })
        let controller = MainWindowController(
            layout: layout, workspace: workspace, dispatcher: dispatcher,
            closeCoordinator: closeCoordinator)
        controller.onClose = { [weak self] closed in
            self?.windowControllers.removeAll { $0 === closed }
        }
        windowControllers.append(controller)
        if let mainWindow = controller.window as? MainWindow {
            mainWindow.onDropFiles = { [weak self, weak controller] urls in
                guard let self, let controller else { return }
                self.openDropped(urls, in: controller)
            }
            mainWindow.onFocusChange = { [weak self] window in
                if let menu = NSApp.mainMenu { self?.menuUpdater.refresh(menu, for: window) }
            }
        }
        if let window = controller.window {
            window.isRestorable = !Self.isIsolatedRun
            window.restorationClass = MainWindowRestoration.self
            window.identifier = MainWindowRestoration.identifier
        }
        addSidebar(to: controller)
        if let saved {
            controller.frameController.restore(saved, using: itemRestorer)
        } else {
            layout.fillEmptyPanels()
        }
        if show {
            if let frame = NSApp.keyWindow?.frame {
                controller.window?.setFrameTopLeftPoint(
                    NSPoint(x: frame.minX + 24, y: frame.maxY - 24))
            } else {
                controller.window?.center()
            }
            controller.showWindow(nil)
        }
        return controller
    }

    /// The sidebar (docs/plans/M5.md, D-d): a chosen folder opens in the active panel,
    /// and the row for the folder that panel shows is highlighted.
    private func addSidebar(to controller: MainWindowController) {
        let sidebar = SidebarViewController(favorites: favorites)
        sidebar.onOpen = { [weak self, weak controller] folder in
            guard let self, let controller else { return }
            self.open(folder, inActivePanelOf: controller)
        }
        controller.frameController.onUpdate = { [weak sidebar, weak controller] in
            let active = controller?.layout.zoomedItem ?? controller?.layout.focusedPanelItem
            sidebar?.highlight((active as? BrowserItem)?.folder)
        }
        sidebar.onFavoritesEdited = { [weak self] in
            for controller in self?.windowControllers ?? [] {
                (controller.frameController.sidebar as? SidebarViewController)?.reloadFavorites()
            }
        }
        sidebar.onEject = { [weak self, weak controller] volume in
            guard let self, let controller else { return }
            self.eject(volume, reportingIn: controller)
        }
        controller.frameController.sidebar = sidebar
        controller.frameController.isFunctionKeyBarShown = isFunctionKeyBarShown
        controller.frameController.bottomAccessory = fileOperations.makeStrip(for: controller)
        sidebar.show(volumes: volumes)
        volumeWatcher.start()
    }

    /// The volumes the sidebars show, kept current for all windows.
    private var volumes: [Volume] = []
    private var ejectingVolumes: Set<String> = []
    private lazy var volumeWatcher = VolumeWatcher { [weak self] volumes in
        guard let self else { return }
        self.volumes = volumes
        for controller in windowControllers {
            (controller.frameController.sidebar as? SidebarViewController)?.show(volumes: volumes)
        }
    }

    /// Unmounts and ejects off the main actor: it can take seconds. The watcher hears of
    /// the unmount; a refusal is shown in the window's status line.
    private func eject(_ volume: Volume, reportingIn controller: MainWindowController) {
        let key = volume.url.standardizedFileURL.path
        guard ejectingVolumes.insert(key).inserted else { return }
        let url = volume.url
        let name = volume.name
        Task { [weak self, weak controller] in
            defer { self?.ejectingVolumes.remove(key) }
            let failure: String? = await Task.detached {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure {
                controller?.frameController.showStatus("Can’t eject “\(name)”: \(failure)")
            }
        }
    }

    /// Shows `folder` in the active panel's browser, or in a new browser tab there when
    /// that panel shows something else.
    func open(_ folder: URL, inActivePanelOf controller: MainWindowController) {
        let layout = controller.layout
        if layout.zoomedItem != nil { layout.exitZoom() }
        if let browser = layout.focusedPanelItem as? BrowserItem {
            if !browser.go(to: folder) {
                (controller.frameController.sidebar as? SidebarViewController)?.highlight(
                    (layout.focusedPanelItem as? BrowserItem)?.folder)
            }
        } else {
            layout.insert(makeBrowser(at: folder), in: layout.activePanel)
        }
    }

    /// A browser tab at `folder`, or the active browser's folder, or the real home.
    func makeBrowser(at folder: URL? = nil) -> BrowserItem {
        let current = activeController?.layout.focusedPanelItem as? BrowserItem
        let browser = BrowserItem(
            folder: folder ?? current?.folder ?? DirectoryReader.realHomeDirectory,
            grants: folderGrants
        ) { [weak self] url, scope in
            self?.openFile(url, scope: scope)
        }
        browser.fileCommands = fileOperations
        return browser
    }

    func makeEditorSession() -> PlaceholderEditorSession {
        editorCount += 1
        return PlaceholderEditorSession(name: "Untitled \(editorCount)")
    }

    /// The main window that menu commands act on.
    var activeController: MainWindowController? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        return windowControllers.first { $0.window === window } ?? windowControllers.first
    }

    func controller(containing id: ItemID) -> MainWindowController? {
        windowControllers.first { $0.layout.item(id) != nil }
    }

    /// Adds an item to `target` (or the active window, opening one if needed).
    func show(_ item: any WorkspaceItem, in target: MainWindowController? = nil) {
        let controller = target ?? activeController ?? openMainWindow()
        controller.layout.insert(item)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Commands

    @objc func newMainWindow(_ sender: Any?) { openMainWindow() }

    // MARK: Opening files

    /// Handles items dropped onto `controller`: folders open in a browser tab (and save
    /// their grant); regular files open in a hex editor tab.
    func openDropped(_ urls: [URL], in controller: MainWindowController) {
        openURLs(urls, in: controller)
    }

    private func openURLs(_ urls: [URL], in target: MainWindowController?) {
        for url in urls {
            let resolved = url.resolvingSymlinksInPath()
            let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true, values?.isPackage != true {
                try? folderGrants.add(resolved)
                show(makeBrowser(at: resolved), in: target)
            } else {
                openFile(resolved, in: target)
            }
        }
    }

    /// Opens `url` as a hex editor tab in `target` (or the active window), or brings
    /// forward the tab already editing that file, wherever it is. `scope` keeps sandbox
    /// access when the URL came from a bookmark; panel, drop and Finder URLs carry their
    /// own access for this run.
    @discardableResult
    func openFile(
        _ url: URL, scope: SecurityScope? = nil, in target: MainWindowController? = nil
    ) -> HexEditorItem? {
        do {
            let (session, isNew) = try sessions.open(url, scope: scope)
            recentFiles.note(url)
            if !isNew, let item = editorItem(showing: session),
                let controller = controller(containing: item.id)
            {
                controller.layout.select(item.id)
                controller.window?.makeKeyAndOrderFront(nil)
                return item
            }
            let item = HexEditorItem(session: session)
            item.didSaveAs = { [weak self] url in self?.recentFiles.note(url) }
            show(item, in: target)
            return item
        } catch {
            presentOpenError(error, url: url, in: target)
            return nil
        }
    }

    /// The editor tab showing `session`, in any window.
    func editorItem(showing session: EditorSession) -> HexEditorItem? {
        workspace.allItems.lazy.compactMap { $0 as? HexEditorItem }
            .first { $0.session === session }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openFile(url) }
    }

    @objc func openRecentFile(_ sender: Any?) {
        guard let data = (sender as? NSMenuItem)?.representedObject as? Data else { return }
        if let (url, scope) = recentFiles.open(data) {
            openFile(url, scope: scope)
        } else if let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path {
            locateRecentFile(at: URL(fileURLWithPath: path))
        } else {
            NSSound.beep()
        }
    }

    /// A recent file that moved or was renamed: ask the user to find it, starting where
    /// it was; the file they pick replaces the old entry.
    @objc func locateRecentFile(_ sender: Any?) {
        guard let lost = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        locateRecentFile(at: lost)
    }

    private func locateRecentFile(at lost: URL) {
        var folder = lost.deletingLastPathComponent()
        while folder.path != "/", !FileManager.default.fileExists(atPath: folder.path) {
            folder = folder.deletingLastPathComponent()
        }
        let panel = NSOpenPanel()
        panel.message =
            "“\(lost.lastPathComponent)” was moved or renamed. Find it to open it again."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard openFile(url) != nil else { return }
        if url.resolvingSymlinksInPath() != lost.resolvingSymlinksInPath() {
            recentFiles.forget(lost)
        }
    }

    @objc func clearRecentFiles(_ sender: Any?) {
        recentFiles.clear()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    private func presentOpenError(
        _ error: Error, url: URL, in target: MainWindowController? = nil
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(url.lastPathComponent)” can’t be opened"
        alert.informativeText =
            (error as? ByteSourceError)?.description
            ?? error.localizedDescription
        if let window = (target ?? activeController)?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc func newBrowserTab(_ sender: Any?) { show(makeBrowser()) }

    @objc func newEditorTab(_ sender: Any?) { show(makeEditorSession().makeView()) }

    @objc func newEditorView(_ sender: Any?) {
        guard let editor = activeController?.layout.focusedPanelItem as? PlaceholderEditorItem
        else { return }
        show(editor.session.makeView())
    }

    @objc func showTestSheet(_ sender: Any?) {
        guard let window = activeController?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Test sheet"
        alert.informativeText =
            "While a sheet is up the command registry intercepts nothing: F3 and Tab behave "
            + "as the sheet's controls expect."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.placeholderString = "Type here; Tab moves between controls"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window)
    }

    @objc func probeFile(_ sender: Any?) { spike.probeFile() }
    @objc func probeFolder(_ sender: Any?) { spike.probeFolder() }
    @objc func resolveSavedBookmarks(_ sender: Any?) { spike.resolveSavedBookmarks() }
    @objc func showSpikeReport(_ sender: Any?) { spike.showReport() }
    @objc func exportSpikeReport(_ sender: Any?) { spike.exportReport() }

    // MARK: Function keys

    /// Off unless turned on (D51); the earlier "FunctionKeyBarHidden" key, from when the
    /// bar started shown, is no longer read.
    private static let functionKeyBarShownKey = "FunctionKeyBarShown"

    private var isFunctionKeyBarShown: Bool {
        preferences.bool(forKey: Self.functionKeyBarShownKey)
    }

    /// View › Show/Hide Function Keys, for every window (D51).
    @objc func toggleFunctionKeys(_ sender: Any?) {
        preferences.set(!isFunctionKeyBarShown, forKey: Self.functionKeyBarShownKey)
        for controller in windowControllers {
            controller.frameController.isFunctionKeyBarShown = isFunctionKeyBarShown
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleFunctionKeys(_:)):
            menuItem.title = isFunctionKeyBarShown ? "Hide Function Keys" : "Show Function Keys"
            return true
        case #selector(newEditorView(_:)):
            return activeController?.layout.focusedPanelItem is PlaceholderEditorItem
        default:
            return true
        }
    }

    // MARK: Close prompt

    func makeCloseAlert(for session: DirtySession) -> NSAlert {
        let alert = NSAlert()
        let title = session.representative.title
        if session.representative.canSave {
            alert.messageText = "Do you want to save the changes made to “\(title)”?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            let dontSave = alert.addButton(withTitle: "Don’t Save")
            dontSave.hasDestructiveAction = true
            dontSave.keyEquivalent = "d"
            dontSave.keyEquivalentModifierMask = .command
        } else {
            alert.messageText = "Discard the changes made to “\(title)”?"
            alert.informativeText =
                "This file can’t be saved here, so closing discards your changes."
            let discard = alert.addButton(withTitle: "Discard Changes")
            discard.hasDestructiveAction = true
            discard.keyEquivalent = "d"
            discard.keyEquivalentModifierMask = .command
            let cancel = alert.addButton(withTitle: "Cancel")
            cancel.keyEquivalent = "\u{1b}"
        }
        return alert
    }

    static func closeDecision(
        for response: NSApplication.ModalResponse, canSave: Bool
    ) -> CloseDecision {
        switch (response, canSave) {
        case (.alertFirstButtonReturn, true): return .save
        case (.alertThirdButtonReturn, true), (.alertFirstButtonReturn, false): return .discard
        default: return .cancel
        }
    }

    private func askToSave(_ session: DirtySession) async -> CloseDecision {
        let alert = makeCloseAlert(for: session)
        let response: NSApplication.ModalResponse
        if let controller = controller(containing: session.representative.id),
            let window = controller.window
        {
            controller.layout.exitZoom()
            controller.layout.select(session.representative.id)
            window.makeKeyAndOrderFront(nil)
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return Self.closeDecision(for: response, canSave: session.representative.canSave)
    }

    private func presentCloseSaveError(_ error: Error, session: DirtySession) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t save “\(session.representative.title)”."
        let reason =
            (error as? Saver.SaveError)?.description
            ?? (error as? FileSystemError)?.description
            ?? (error as? ByteSourceError)?.description
            ?? (error as? EditorSessionError)?.description
            ?? error.localizedDescription
        alert.informativeText = "\(reason). Your changes are still here."
        if let window = controller(containing: session.representative.id)?.window {
            window.makeKeyAndOrderFront(nil)
            await alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
