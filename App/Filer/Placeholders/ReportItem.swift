import AppKit
import WorkspaceKit

/// Read-only text tab, used to show the sandbox spike report inside the main frame
/// rather than in a separate window (D7).
@MainActor
final class ReportItem: WorkspaceItem {
    let id = ItemID()
    let kind: ItemKind = .report
    let preferredSlot: SlotID = .leftPanel
    let title: String
    weak var host: WorkspaceHost?
    var onChange: (() -> Void)?
    private var text: String
    private lazy var controller = ReportViewController(text: text)

    init(title: String, text: String) {
        self.title = title
        self.text = text
    }

    var viewController: NSViewController { controller }
    var preferredFirstResponder: NSView? { controller.textView }

    func update(text: String) {
        self.text = text
        controller.textView.string = text
    }
}

@MainActor
final class ReportViewController: NSViewController {
    let textView = NSTextView()
    private let initialText: String

    init(text: String) {
        initialText = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = initialText
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        view = scroll
    }
}
