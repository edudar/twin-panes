import AppKit
import TwinPanesCore
import WorkspaceKit

extension ItemKind {
    public static let browser: ItemKind = "browser"
}

/// Action selectors of the browser, so menus and the command catalog can name them.
@objc public protocol BrowserActions {
    /// Enter, double-click, ⌘↓: into a folder, or open a file in the editor.
    @objc optional func browserOpen(_ sender: Any?)
    /// F3 and F4: open the file under the cursor in the editor (quick view is M7).
    @objc optional func browserView(_ sender: Any?)
    @objc optional func browserEdit(_ sender: Any?)
    /// ⌘↑, Backspace: the parent folder.
    @objc optional func browserParent(_ sender: Any?)
    /// ⇧⌘G: focus the path field.
    @objc optional func browserGoToFolder(_ sender: Any?)
    /// Ask for sandbox access to the current folder.
    @objc optional func browserGrantAccess(_ sender: Any?)
}

/// A browser tab over one folder at a time (M1b, PLAN.md §4.7). The listing is
/// synchronous for now; async listing for huge folders, history, sorting, hidden
/// files and live updates come in M4.
@MainActor
public final class BrowserItem: WorkspaceItem {
    public let id = ItemID()
    public let kind: ItemKind = .browser
    public let preferredSlot: SlotID = .leftPanel
    public weak var host: WorkspaceHost?
    public var onChange: (() -> Void)?

    public let grants: FolderGrants
    /// Opens a file in an editor tab; supplied by the app so BrowserKit doesn't
    /// import EditorKit (§4). The scope covers the file's folder, if one was needed.
    public let openFile: (URL, SecurityScope?) -> Void

    public private(set) var folder: URL
    public private(set) var entries: [DirectoryEntry] = []
    /// Set when the sandbox refuses the folder until the user grants access.
    public private(set) var needsAccess = false
    /// False until the first listing; the view lists the folder when it first loads.
    public private(set) var hasListed = false
    /// Access to the current folder, held for as long as this tab shows it (§5).
    private(set) var scope: SecurityScope?
    private lazy var controller = BrowserViewController(item: self)

    public init(
        folder: URL, grants: FolderGrants, openFile: @escaping (URL, SecurityScope?) -> Void
    ) {
        self.folder = folder.standardizedFileURL
        self.grants = grants
        self.openFile = openFile
    }

    public var title: String {
        folder.path == "/" ? "/" : FileManager.default.displayName(atPath: folder.path)
    }
    public var icon: NSImage? { NSWorkspace.shared.icon(forFile: folder.path) }
    public var viewController: NSViewController { controller }
    public var preferredFirstResponder: NSView? { controller.tableView }

    /// Lists `url` (default: the current folder again). On success the tab moves
    /// there; if access is needed the tab moves there and shows the access prompt.
    /// Returns false (and stays put) for missing or non-folder paths.
    @discardableResult
    public func go(to url: URL? = nil, selecting name: String? = nil) -> Bool {
        let target = (url ?? folder).standardizedFileURL
        let newScope = grants.scope(covering: target)
        do {
            entries = try DirectoryReader.entries(of: target)
            needsAccess = false
        } catch DirectoryReaderError.needsAccess {
            entries = []
            needsAccess = true
        } catch {
            host?.showStatus("Can’t open “\(target.path)”: \(error)")
            NSSound.beep()
            return false
        }
        folder = target
        scope = newScope
        hasListed = true
        controller.reload(selecting: name)
        onChange?()
        updateStatus()
        return true
    }

    /// Opens a folder entry, or hands a file to the editor.
    public func open(_ entry: DirectoryEntry) {
        if entry.isDirectory {
            go(to: entry.url)
        } else {
            openFile(entry.url, grants.scope(covering: entry.url))
        }
    }

    public func goToParent() {
        let parent = folder.deletingLastPathComponent()
        guard parent.path != folder.path else { return NSSound.beep() }
        go(to: parent, selecting: folder.lastPathComponent)
    }

    /// Records a folder the user granted in an open panel and lists it.
    public func granted(_ url: URL) {
        try? grants.add(url)
        go(to: url == folder ? nil : url)
    }

    func updateStatus() {
        if needsAccess {
            host?.showStatus("\(folder.path) · no access yet")
        } else {
            let folders = entries.filter(\.isDirectory).count
            host?.showStatus(
                "\(folder.path) · \(entries.count) items (\(folders) folders)")
        }
    }
}
