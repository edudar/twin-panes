import AppKit
import BrowserKit
import EditorKit
import WorkspaceKit

/// Action selectors for app-level and placeholder commands. Declared once so
/// `#selector` has something to point at; the responders implement the methods
/// without conforming (they're found through the responder chain).
@objc protocol AppActions {
    @objc optional func newMainWindow(_ sender: Any?)
    @objc optional func openRecentFile(_ sender: Any?)
    @objc optional func clearRecentFiles(_ sender: Any?)
    @objc optional func locateRecentFile(_ sender: Any?)
    @objc optional func toggleFunctionKeys(_ sender: Any?)
    @objc optional func newBrowserTab(_ sender: Any?)
    @objc optional func newEditorTab(_ sender: Any?)
    @objc optional func newEditorView(_ sender: Any?)
    @objc optional func showTestSheet(_ sender: Any?)
    @objc optional func probeFile(_ sender: Any?)
    @objc optional func probeFolder(_ sender: Any?)
    @objc optional func resolveSavedBookmarks(_ sender: Any?)
    @objc optional func showSpikeReport(_ sender: Any?)
    @objc optional func exportSpikeReport(_ sender: Any?)
}

extension CommandID {
    static let quit: CommandID = "app.quit"
    static let newWindow: CommandID = "app.newWindow"
    static let openFile: CommandID = "file.open"
    static let goToOffset: CommandID = "editor.goToOffset"
    static let copyAsHex: CommandID = "editor.copyAsHex"
    static let copyAsText: CommandID = "editor.copyAsText"
    static let saveSelection: CommandID = "editor.saveSelection"
    static let save: CommandID = "file.save"
    static let revertToSaved: CommandID = "file.revertToSaved"
    static let saveAs: CommandID = "file.saveAs"
    static let newBrowserTab: CommandID = "workspace.newBrowserTab"
    static let newEditorTab: CommandID = "workspace.newEditorTab"
    static let newEditorView: CommandID = "editor.newView"
    static let closeTab: CommandID = "workspace.closeTab"
    static let closeWindow: CommandID = "window.close"
    static let toggleZoom: CommandID = "workspace.toggleZoom"
    static let exitZoom: CommandID = "workspace.exitZoom"
    static let nextTab: CommandID = "workspace.nextTab"
    static let previousTab: CommandID = "workspace.previousTab"
    static let toggleSidebar: CommandID = "view.toggleSidebar"
    static let toggleFunctionKeys: CommandID = "view.toggleFunctionKeys"
    static let switchPanel: CommandID = "panel.switch"
    static let moveTabToOtherPanel: CommandID = "panel.moveTab"
    static let browserView: CommandID = "browser.view"
    static let browserEdit: CommandID = "browser.edit"
    static let browserOpen: CommandID = "browser.open"
    static let browserOpenInEditor: CommandID = "browser.openInEditor"
    static let browserParent: CommandID = "browser.parent"
    static let browserGoToFolder: CommandID = "browser.goToFolder"
    static let browserToggleHidden: CommandID = "browser.toggleHidden"
    static let browserBack: CommandID = "browser.back"
    static let browserShowPackageContents: CommandID = "browser.showPackageContents"
    static let browserForward: CommandID = "browser.forward"
    static let editorFind: CommandID = "editor.find"
    static let editorFindNext: CommandID = "editor.findNext"
    static let editorFindPrevious: CommandID = "editor.findPrevious"
    static let editorFindAll: CommandID = "editor.findAll"
    static let editorUseSelectionForFind: CommandID = "editor.useSelectionForFind"
    static let editorCloseFind: CommandID = "editor.closeFind"
    static let toggleInspector: CommandID = "editor.toggleInspector"
    static let showTestSheet: CommandID = "debug.showTestSheet"
    static let probeFile: CommandID = "debug.probeFile"
    static let probeFolder: CommandID = "debug.probeFolder"
    static let resolveBookmarks: CommandID = "debug.resolveBookmarks"
    static let showSpikeReport: CommandID = "debug.showSpikeReport"
    static let exportSpikeReport: CommandID = "debug.exportSpikeReport"
}

extension ItemKind {
    static let report: ItemKind = "report"
}

/// The command catalog and default bindings (D21). F3 is the context-dependent
/// example: View in a browser, Find Next in an editor.
@MainActor
enum DefaultCommands {
    static func makeRegistry() -> CommandRegistry {
        let registry = CommandRegistry()
        func add(_ id: CommandID, _ title: String, _ action: Selector) {
            registry.register(Command(id, title: title, action: action))
        }
        add(.quit, "Quit Twin Panes", #selector(NSApplication.terminate(_:)))
        add(.newWindow, "New Window", #selector(AppActions.newMainWindow(_:)))
        add(.openFile, "Open…", #selector(NSDocumentController.openDocument(_:)))
        add(.goToOffset, "Go to Offset…", #selector(HexEditorActions.goToOffset(_:)))
        add(.copyAsHex, "Copy as Hex", #selector(HexEditorActions.copyAsHex(_:)))
        add(.copyAsText, "Copy as Text", #selector(HexEditorActions.copyAsText(_:)))
        add(.save, "Save", #selector(HexEditorActions.editorSave(_:)))
        add(.saveAs, "Save As…", #selector(HexEditorActions.editorSaveAs(_:)))
        add(
            .revertToSaved, "Revert to Saved",
            #selector(HexEditorActions.editorRevertToSaved(_:)))
        add(.saveSelection, "Save Selection…", #selector(HexEditorActions.saveSelection(_:)))
        add(.newBrowserTab, "New Browser Tab", #selector(AppActions.newBrowserTab(_:)))
        add(.newEditorTab, "New Editor Tab", #selector(AppActions.newEditorTab(_:)))
        add(.newEditorView, "New View of This Editor", #selector(AppActions.newEditorView(_:)))
        add(.closeTab, "Close Tab", #selector(MainFrameViewController.closeTab(_:)))
        add(.closeWindow, "Close Window", #selector(NSWindow.performClose(_:)))
        add(.toggleZoom, "Zoom Item", #selector(MainFrameViewController.toggleZoom(_:)))
        add(.exitZoom, "Exit Zoom", #selector(MainFrameViewController.exitZoom(_:)))
        add(.nextTab, "Show Next Tab", #selector(MainFrameViewController.selectNextTab(_:)))
        add(
            .previousTab, "Show Previous Tab",
            #selector(MainFrameViewController.selectPreviousTab(_:)))
        add(
            .toggleSidebar, "Show Sidebar",
            #selector(MainFrameViewController.toggleSidebarShown(_:)))
        add(
            .toggleFunctionKeys, "Hide Function Keys",
            #selector(AppActions.toggleFunctionKeys(_:)))
        add(.switchPanel, "Switch Panel", #selector(MainFrameViewController.switchPanel(_:)))
        add(
            .moveTabToOtherPanel, "Move Tab to Other Panel",
            #selector(MainFrameViewController.moveTabToOtherPanel(_:)))
        add(.browserView, "View", #selector(BrowserActions.browserView(_:)))
        add(.browserEdit, "Edit", #selector(BrowserActions.browserEdit(_:)))
        add(.browserOpen, "Open", #selector(BrowserActions.browserOpen(_:)))
        add(
            .browserOpenInEditor, "Open in Hex Editor",
            #selector(BrowserActions.browserOpenInEditor(_:)))
        add(.browserParent, "Enclosing Folder", #selector(BrowserActions.browserParent(_:)))
        add(.browserGoToFolder, "Go to Folder…", #selector(BrowserActions.browserGoToFolder(_:)))
        add(.browserBack, "Back", #selector(BrowserActions.browserBack(_:)))
        add(
            .browserShowPackageContents, "Show Package Contents",
            #selector(BrowserActions.browserShowPackageContents(_:)))
        add(.browserForward, "Forward", #selector(BrowserActions.browserForward(_:)))
        add(
            .browserToggleHidden, "Show Hidden Files",
            #selector(BrowserActions.browserToggleHidden(_:)))
        add(.editorFind, "Find…", #selector(HexEditorActions.editorFind(_:)))
        add(.editorFindNext, "Find Next", #selector(HexEditorActions.editorFindNext(_:)))
        add(
            .editorFindPrevious, "Find Previous",
            #selector(HexEditorActions.editorFindPrevious(_:)))
        add(.editorFindAll, "Find All", #selector(HexEditorActions.editorFindAll(_:)))
        add(
            .editorUseSelectionForFind, "Use Selection for Find",
            #selector(HexEditorActions.editorUseSelectionForFind(_:)))
        add(.editorCloseFind, "Close Find Bar", #selector(HexEditorActions.editorCloseFind(_:)))
        add(.toggleInspector, "Show Inspector", #selector(HexEditorActions.toggleInspector(_:)))
        add(.showTestSheet, "Show Test Sheet", #selector(AppActions.showTestSheet(_:)))
        add(.probeFile, "Probe a Test File…", #selector(AppActions.probeFile(_:)))
        add(.probeFolder, "Probe a Folder…", #selector(AppActions.probeFolder(_:)))
        add(
            .resolveBookmarks, "Resolve Saved Bookmarks",
            #selector(AppActions.resolveSavedBookmarks(_:)))
        add(.showSpikeReport, "Show Spike Report", #selector(AppActions.showSpikeReport(_:)))
        add(
            .exportSpikeReport, "Export Spike Report…",
            #selector(AppActions.exportSpikeReport(_:)))

        let browser = BindingScope.item(.browser)
        let fileList = BindingScope.item(.browser, part: "fileList")
        let pathField = BindingScope.item(.browser, part: "pathField")
        let editor = BindingScope.item(.editor)
        let findBar = BindingScope.item(.editor, part: "findBar")

        registry.bind(KeyChord("q", .command), to: .quit)
        registry.bind(.function(10), to: .quit)  // as in Norton Commander (§4.7)
        registry.bind(KeyChord("n", .command), to: .newWindow)
        registry.bind(KeyChord("o", .command), to: .openFile)
        // ⌘L is Finder's "Make Alias"; the conflict is deferred to M10 (§9).
        registry.bind(KeyChord("l", .command), to: .goToOffset, in: editor)
        registry.bind(KeyChord("t", .command), to: .newBrowserTab)
        registry.bind(KeyChord("t", [.command, .option]), to: .newEditorTab)
        registry.bind(KeyChord("w", .command), to: .closeTab)
        registry.bind(KeyChord("w", [.command, .shift]), to: .closeWindow)
        registry.bind(KeyChord("\r", [.command, .shift]), to: .toggleZoom)
        registry.bind(.escape, to: .exitZoom, in: .mainFrame)
        registry.bind(KeyChord("\t", .control), to: .nextTab)
        registry.bind(KeyChord("\t", [.control, .shift]), to: .previousTab)
        registry.bind(KeyChord("s", [.control, .command]), to: .toggleSidebar)  // as in Finder
        // Only in the file list, so the path field and the editor keep Tab (§4.11).
        registry.bind(.tab, to: .switchPanel, in: fileList)
        registry.bind(KeyChord("\t", .shift), to: .switchPanel, in: fileList)
        registry.bind(.function(3), to: .browserView, in: browser)
        registry.bind(.function(4), to: .browserEdit, in: browser)
        registry.bind(.returnKey, to: .browserOpen, in: fileList)
        registry.bind(KeyChord("\r", .command), to: .browserOpenInEditor, in: pathField)
        registry.bind(
            KeyChord(Self.arrow(NSDownArrowFunctionKey), .command), to: .browserOpen, in: browser)
        registry.bind(
            KeyChord(Self.arrow(NSUpArrowFunctionKey), .command), to: .browserParent, in: browser)
        registry.bind(KeyChord("\u{7f}"), to: .browserParent, in: fileList)
        registry.bind(KeyChord("g", [.command, .shift]), to: .browserGoToFolder, in: browser)
        registry.bind(KeyChord(">", .command), to: .browserToggleHidden, in: browser)  // ⇧⌘.
        registry.bind(KeyChord("[", .command), to: .browserBack, in: browser)
        registry.bind(
            KeyChord(Self.arrow(NSDownArrowFunctionKey), [.command, .option]),
            to: .browserShowPackageContents, in: browser)
        registry.bind(KeyChord("]", .command), to: .browserForward, in: browser)
        registry.bind(KeyChord("s", .command), to: .save, in: editor)
        registry.bind(KeyChord("s", [.command, .shift]), to: .saveAs, in: editor)
        registry.bind(KeyChord("f", .command), to: .editorFind, in: editor)
        // Primary menu shortcuts (⌘G / ⇧⌘G) are bound before secondary F3 / ⇧F3.
        registry.bind(KeyChord("g", .command), to: .editorFindNext, in: editor)
        registry.bind(KeyChord("g", [.command, .shift]), to: .editorFindPrevious, in: editor)
        registry.bind(.function(3), to: .editorFindNext, in: editor)
        registry.bind(
            KeyChord(KeyChord.function(3).key, .shift), to: .editorFindPrevious, in: editor)
        registry.bind(KeyChord("e", .command), to: .editorUseSelectionForFind, in: editor)
        registry.bind(KeyChord("i", [.command, .option]), to: .toggleInspector, in: editor)
        registry.bind(.escape, to: .editorCloseFind, in: findBar)
        return registry
    }

    private static func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt32(key))!))
    }
}
