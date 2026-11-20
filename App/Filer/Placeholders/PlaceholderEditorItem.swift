import AppKit
import WorkspaceKit

/// M0 stand-in for an editor session: shared text and a dirty flag. Several tabs can
/// view one session, which exercises "prompt once, when the last view closes".
@MainActor
final class PlaceholderEditorSession: NSObject, NSTextStorageDelegate {
    let name: String
    let textStorage = NSTextStorage(
        string:
            "Placeholder editor (M0). Type to make the session dirty; F3 here means Find Next.\n")
    private(set) var isDirty = false
    private var views: [WeakItem] = []

    init(name: String) {
        self.name = name
        super.init()
        textStorage.delegate = self
        textStorage.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    func makeView() -> PlaceholderEditorItem {
        let item = PlaceholderEditorItem(session: self, viewNumber: views.count + 1)
        views.append(WeakItem(item: item))
        return item
    }

    func setDirty(_ dirty: Bool) {
        guard dirty != isDirty else { return }
        isDirty = dirty
        views.removeAll { $0.item == nil }
        for view in views { view.item?.onChange?() }
    }

    nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { setDirty(true) }
    }

    private struct WeakItem {
        weak var item: PlaceholderEditorItem?
    }
}

@MainActor
final class PlaceholderEditorItem: WorkspaceItem {
    let id = ItemID()
    let kind: ItemKind = .editor
    let preferredSlot: SlotID = .leftPanel
    let session: PlaceholderEditorSession
    let viewNumber: Int
    weak var host: WorkspaceHost?
    var onChange: (() -> Void)?
    private lazy var controller = PlaceholderEditorViewController(item: self)

    init(session: PlaceholderEditorSession, viewNumber: Int) {
        self.session = session
        self.viewNumber = viewNumber
    }

    var title: String { viewNumber == 1 ? session.name : "\(session.name) (\(viewNumber))" }
    var isDirty: Bool { session.isDirty }
    var sessionKey: AnyHashable? { ObjectIdentifier(session) }
    var viewController: NSViewController { controller }
    var preferredFirstResponder: NSView? { controller.textView }

    func save() async throws { session.setDirty(false) }
    func discardChanges() { session.setDirty(false) }
}

@MainActor
final class PlaceholderEditorViewController: NSViewController, CommandScopeProviding {
    private unowned let item: PlaceholderEditorItem
    private(set) var textView: NSTextView!

    init(item: PlaceholderEditorItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var commandScopes: [BindingScope] { [.item(.editor)] }

    override func loadView() {
        // Each view gets its own layout manager over the session's shared storage.
        let layoutManager = NSLayoutManager()
        item.session.textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let text = NSTextView(frame: .zero, textContainer: container)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.allowsUndo = true
        text.isRichText = false
        text.setAccessibilityIdentifier("editorText")
        textView = text

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        view = scroll
    }

    @objc func editorFindNext(_ sender: Any?) {
        item.host?.showStatus("F3 in editor → editor.findNext (find lands in M2)")
    }
}
