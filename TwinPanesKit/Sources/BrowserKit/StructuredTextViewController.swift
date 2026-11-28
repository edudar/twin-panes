import AppKit
import TwinPanesCore

/// Read-only, syntax-colored text view for structured and plain-text Quick View files
/// (`docs/plans/M7b.md`, D-e). Loads off the main actor and drops stale results by generation.
@MainActor
final class StructuredTextViewController: NSViewController {
    private static let loadQueue = DispatchQueue(
        label: "com.twinpanes.quickView.structured", qos: .userInitiated)
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let noticeBox = NSBox()
    private let noticeLabel = NSTextField(labelWithString: "")

    private var generation: UInt64 = 0
    private var currentDocument: StructuredDocument?
    private var currentScope: SecurityScope?

    /// Called on the main actor after each load whose result was applied (success or error).
    var onLoadFinished: (() -> Void)?

    var displayedText: String { textView.string }
    var displayedNotice: String? { noticeBox.isHidden ? nil : noticeLabel.stringValue }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        configureNotice()
        configureTextView()
        let stack = AppearanceObservingStackView(views: [noticeBox, scrollView])
        stack.onAppearanceChange = { [weak self] in self?.render(self?.currentDocument) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.detachesHiddenViews = true
        for subview in [noticeBox, scrollView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            subview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = stack
    }

    /// Loads and displays `url`; `nil` clears the view. Any in-flight load is superseded.
    func show(_ url: URL?, format: StructuredFormat?, pretty: Bool, scope: SecurityScope?) {
        generation &+= 1
        guard let url else {
            currentDocument = nil
            currentScope = nil
            render(nil)
            setNotice(nil)
            return
        }
        currentScope = scope
        applyWrapping(!pretty)
        let expected = generation
        Self.loadQueue.async { [weak self] in
            let result = withExtendedLifetime(scope) {
                Result {
                    try StructuredPreviewLoader.load(url: url, format: format, pretty: pretty)
                }
            }
            Task { @MainActor [weak self] in
                self?.finishLoad(result, generation: expected)
            }
        }
    }

    private func finishLoad(_ result: Result<StructuredDocument, any Error>, generation: UInt64) {
        guard generation == self.generation else { return }
        switch result {
        case .success(let document):
            currentDocument = document
            render(document)
            setNotice(document.notice)
        case .failure(let error):
            currentDocument = nil
            render(nil)
            setNotice("Couldn't read this file: \(error.localizedDescription)")
        }
        onLoadFinished?()
    }

    private func render(_ document: StructuredDocument?) {
        guard let document else {
            textView.textStorage?.setAttributedString(NSAttributedString())
            return
        }
        let attributed = NSMutableAttributedString(
            string: document.text,
            attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor])
        let length = attributed.length
        for token in document.tokens where NSMaxRange(token.range) <= length {
            attributed.addAttribute(
                .foregroundColor, value: Self.color(for: token.kind), range: token.range)
            if token.kind == .header {
                attributed.addAttribute(
                    .font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                    range: token.range)
            }
        }
        textView.textStorage?.setAttributedString(attributed)
    }

    private static func color(for kind: SyntaxTokenKind) -> NSColor {
        switch kind {
        case .key: .systemBlue
        case .string: .systemGreen
        case .number: .systemOrange
        case .keyword: .systemPurple
        case .comment, .punctuation: .secondaryLabelColor
        case .tag: .systemTeal
        case .attribute: .systemIndigo
        case .header: .labelColor
        case .columnAlt: .systemTeal
        }
    }

    private func setNotice(_ notice: String?) {
        noticeLabel.stringValue = notice ?? ""
        noticeBox.isHidden = notice == nil
    }

    private func applyWrapping(_ wraps: Bool) {
        scrollView.hasHorizontalScroller = !wraps
        textView.isHorizontallyResizable = !wraps
        textView.textContainer?.widthTracksTextView = wraps
        let width = wraps ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude
        textView.textContainer?.containerSize = NSSize(
            width: width, height: CGFloat.greatestFiniteMagnitude)
    }

    private func configureNotice() {
        noticeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        noticeLabel.setAccessibilityIdentifier("structuredPreviewNotice")
        noticeBox.boxType = .custom
        noticeBox.borderWidth = 0
        noticeBox.fillColor = NSColor.systemYellow.withAlphaComponent(0.15)
        noticeBox.contentViewMargins = .zero
        noticeBox.isHidden = true
        noticeBox.addSubview(noticeLabel)
        NSLayoutConstraint.activate([
            noticeLabel.topAnchor.constraint(equalTo: noticeBox.topAnchor, constant: 4),
            noticeLabel.bottomAnchor.constraint(equalTo: noticeBox.bottomAnchor, constant: -4),
            noticeLabel.leadingAnchor.constraint(equalTo: noticeBox.leadingAnchor, constant: 10),
            noticeLabel.trailingAnchor.constraint(equalTo: noticeBox.trailingAnchor, constant: -10),
        ])
    }

    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.setAccessibilityIdentifier("structuredPreviewTextView")
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        textView.drawsBackground = false
    }
}

/// `NSViewController` has no appearance hook, so the root view reports Light/Dark changes.
private final class AppearanceObservingStackView: NSStackView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
