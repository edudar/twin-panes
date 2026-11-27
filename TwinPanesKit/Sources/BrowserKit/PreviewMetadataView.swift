import AppKit
import TwinPanesCore

/// Scrollable key/value metadata panel for the trailing preview pane (`docs/plans/M7.md`, D-c, D-d).
@MainActor
public final class PreviewMetadataView: NSView {
    struct Row: Equatable {
        let label: String
        let value: String
    }

    private let scrollView = NSScrollView()
    private let documentView = FlippedDocumentView()
    private let stackView = NSStackView()

    private(set) var titleText: String?
    private(set) var rows: [Row] = []
    private(set) var extendedAttributeRows: [Row] = []
    private(set) var hasMoreExtendedAttributes = false
    private(set) var messageText: String?

    public override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("previewMetadata")
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Displays O(1) metadata for a single file, folder, package, or symbolic link.
    public func show(_ metadata: FileMetadata) {
        titleText = metadata.name
        messageText = nil
        let candidates: [(String, String?)] = [
            ("Kind", metadata.kind),
            ("Size", metadata.size.map(Self.formatBytes)),
            ("On Disk", metadata.allocatedSize.map(Self.formatBytes)),
            ("Created", metadata.created.map(Self.formatDate)),
            ("Modified", metadata.modified.map(Self.formatDate)),
            ("Accessed", metadata.accessed.map(Self.formatDate)),
            ("Permissions", metadata.formattedPermissions),
            ("Owner", "\(metadata.owner) : \(metadata.group)"),
            ("Hard Links", metadata.hardLinkCount > 1 ? "\(metadata.hardLinkCount)" : nil),
            ("Flags", metadata.flags.isEmpty ? nil : metadata.flags.joined(separator: ", ")),
            ("Target", metadata.symlinkTarget),
        ]
        rows = candidates.compactMap { label, value in value.map { Row(label: label, value: $0) } }
        extendedAttributeRows = metadata.extendedAttributes.map {
            Row(label: $0.name, value: Self.formatBytes(UInt64(max(0, $0.size))))
        }
        hasMoreExtendedAttributes = metadata.hasMoreExtendedAttributes
        rebuildStack()
    }

    /// Displays a summary for a multi-item browser selection.
    public func showMultiSelection(count: Int, totalBytes: UInt64) {
        titleText = count == 1 ? "1 item selected" : "\(count) items selected"
        messageText = nil
        rows = [Row(label: "Total Size", value: Self.formatBytes(totalBytes))]
        extendedAttributeRows = []
        hasMoreExtendedAttributes = false
        rebuildStack()
    }

    /// Displays an empty-selection or error message in place of metadata rows.
    public func showMessage(_ message: String) {
        reset(message: message)
    }

    /// Clears all displayed metadata and messages.
    public func clear() {
        reset(message: nil)
    }

    private func reset(message: String?) {
        titleText = nil
        rows = []
        extendedAttributeRows = []
        hasMoreExtendedAttributes = false
        messageText = message
        rebuildStack()
    }

    private func configureViews() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView

        documentView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 6
        documentView.addSubview(stackView)

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 10),
            stackView.leadingAnchor.constraint(
                equalTo: documentView.leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(
                equalTo: documentView.trailingAnchor, constant: -10),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -10),
        ])
    }

    private func addLabel(_ text: String, font: NSFont, color: NSColor, selectable: Bool) {
        let field = makeWrappingLabel(text, font: font, color: color, selectable: selectable)
        addRowView(field)
    }

    private func rebuildStack() {
        for arranged in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        if let messageText {
            addLabel(
                messageText, font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                color: .secondaryLabelColor, selectable: false)
            return
        }
        if let titleText {
            addLabel(
                titleText, font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                color: .labelColor, selectable: true)
        }
        for row in rows {
            addRowView(makeKeyValueRow(label: row.label, value: row.value))
        }
        guard !extendedAttributeRows.isEmpty else { return }
        let divider = NSBox()
        divider.boxType = .separator
        addRowView(divider)
        addLabel(
            "Extended Attributes",
            font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            color: .secondaryLabelColor, selectable: false)
        for xattr in extendedAttributeRows {
            addRowView(makeExtendedAttributeRow(name: xattr.label, size: xattr.value))
        }
        if hasMoreExtendedAttributes {
            addLabel(
                "+ more (showing first \(FileMetadata.maxExtendedAttributes))",
                font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                color: .tertiaryLabelColor, selectable: false)
        }
    }

    private func addRowView(_ view: NSView) {
        stackView.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    private func makeKeyValueRow(label: String, value: String) -> NSView {
        let keyField = NSTextField(labelWithString: label)
        keyField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        keyField.textColor = .secondaryLabelColor
        keyField.alignment = .right
        keyField.lineBreakMode = .byTruncatingTail
        keyField.widthAnchor.constraint(equalToConstant: 82).isActive = true

        let valueField = makeWrappingLabel(
            value, font: .systemFont(ofSize: NSFont.smallSystemFontSize),
            color: .labelColor, selectable: true)
        return makeHorizontalRow(left: keyField, right: valueField)
    }

    private func makeExtendedAttributeRow(name: String, size: String) -> NSView {
        let nameField = makeWrappingLabel(
            name, font: .systemFont(ofSize: NSFont.smallSystemFontSize),
            color: .secondaryLabelColor, selectable: true)
        let sizeField = NSTextField(labelWithString: size)
        sizeField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeField.textColor = .labelColor
        sizeField.alignment = .right
        sizeField.isSelectable = true
        sizeField.setContentHuggingPriority(.required, for: .horizontal)
        sizeField.setContentCompressionResistancePriority(.required, for: .horizontal)
        return makeHorizontalRow(left: nameField, right: sizeField)
    }

    private func makeHorizontalRow(left: NSView, right: NSView) -> NSStackView {
        let row = NSStackView(views: [left, right])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func makeWrappingLabel(
        _ text: String, font: NSFont, color: NSColor, selectable: Bool
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = selectable
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private static func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
