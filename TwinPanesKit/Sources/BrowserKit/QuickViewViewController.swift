import AppKit
import TwinPanesCore
import WorkspaceKit

/// View controller for `QuickViewItem` (`docs/plans/M7.md`, D-e).
@MainActor
final class QuickViewViewController: NSViewController, CommandScopeProviding, NSMenuItemValidation {
    weak var item: QuickViewItem?

    var commandScopes: [BindingScope] { [.item(.quickView)] }
    var hexShowsUnsavedEdits: Bool { false }
    var preferredResponder: NSView? { viewIfLoaded }

    init(item: QuickViewItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = QuickViewRootView()
        root.setAccessibilityIdentifier("quickView")
        view = root
        syncPinButton()
        syncView()
    }

    func syncView() {}
    func syncHeader() {}
    func syncPinButton() {}
    func tearDown() {}

    /// F4 / ⌃⌘E / Edit button: opens the displayed regular file in the editor; beeps on
    /// folders, packages, or empty selection.
    @objc func browserEdit(_ sender: Any?) {
        guard let item, let entry = item.currentEntry, !entry.isDirectory, !entry.isPackage else {
            NSSound.beep()
            return
        }
        item.onEdit(entry.url, item.currentScope)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(browserEdit(_:)):
            guard let entry = item?.currentEntry else { return false }
            return !entry.isDirectory && !entry.isPackage
        default:
            return true
        }
    }
}

private final class QuickViewRootView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
