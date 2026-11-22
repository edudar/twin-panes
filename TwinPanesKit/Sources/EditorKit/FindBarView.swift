import AppKit
import TwinPanesCore
import WorkspaceKit

/// The inline find bar at the top of an editor item (PLAN.md §4.10): a pattern field,
/// what kind of pattern it is, previous/next, Find All, and progress for long searches.
/// It only collects input and shows state; `HexEditorViewController` runs the search.
@MainActor
final class FindBarView: NSView, CommandScopeProviding, NSSearchFieldDelegate {
    enum Kind: Int, CaseIterable {
        case hex, utf8, utf16LE, utf16BE

        var title: String {
            switch self {
            case .hex: return "Hex"
            case .utf8: return "Text (UTF-8)"
            case .utf16LE: return "Text (UTF-16 LE)"
            case .utf16BE: return "Text (UTF-16 BE)"
            }
        }
    }

    var onFind: ((Searcher.Direction) -> Void)?
    var onFindAll: (() -> Void)?
    var onPatternChange: (() -> Void)?
    var onDone: (() -> Void)?

    let field = NSSearchField()
    let kindPopUp = NSPopUpButton()
    let ignoreCase = NSButton(checkboxWithTitle: "Ignore Case", target: nil, action: nil)
    private let steps = NSSegmentedControl()
    private let findAll = NSButton(title: "Find All", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let done = NSButton(title: "Done", target: nil, action: nil)

    var commandScopes: [BindingScope] { [.item(.editor, part: "findBar")] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "Find"
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.target = self
        field.action = #selector(fieldEntered(_:))
        field.delegate = self
        field.setAccessibilityIdentifier("findField")

        for kind in Kind.allCases { kindPopUp.addItem(withTitle: kind.title) }
        kindPopUp.selectItem(at: Kind.utf8.rawValue)
        kindPopUp.target = self
        kindPopUp.action = #selector(optionsChanged(_:))
        ignoreCase.target = self
        ignoreCase.action = #selector(optionsChanged(_:))

        steps.segmentCount = 2
        steps.trackingMode = .momentary
        steps.setImage(
            NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous"),
            forSegment: 0)
        steps.setImage(
            NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next"),
            forSegment: 1)
        steps.setToolTip("Find Previous", forSegment: 0)
        steps.setToolTip("Find Next", forSegment: 1)
        steps.target = self
        steps.action = #selector(stepClicked(_:))
        findAll.target = self
        findAll.action = #selector(findAllClicked(_:))
        done.target = self
        done.action = #selector(doneClicked(_:))

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityIdentifier("findStatus")
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true

        for control in [kindPopUp, ignoreCase, steps, findAll, done] as [NSControl] {
            control.controlSize = .small
            control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        field.controlSize = .small

        let row = NSStackView(views: [
            kindPopUp, field, ignoreCase, steps, findAll, statusLabel, progress, done,
        ])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 32),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            progress.widthAnchor.constraint(equalToConstant: 80),
        ])
        optionsChanged(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    var kind: Kind {
        get { Kind(rawValue: kindPopUp.indexOfSelectedItem) ?? .utf8 }
        set {
            kindPopUp.selectItem(at: newValue.rawValue)
            optionsChanged(nil)
        }
    }

    /// The pattern the bar describes; throws `SearchPattern.ParseError` for bad input.
    func pattern() throws -> SearchPattern {
        let text = field.stringValue
        let fold = ignoreCase.state == .on
        switch kind {
        case .hex: return try .hex(text)
        case .utf8: return try .text(text, encoding: .utf8, ignoringCase: fold)
        case .utf16LE: return try .text(text, encoding: .utf16LE, ignoringCase: fold)
        case .utf16BE: return try .text(text, encoding: .utf16BE, ignoringCase: fold)
        }
    }

    /// Shows progress (0…1) while a search runs; nil hides it.
    func setProgress(_ fraction: Double?) {
        progress.isHidden = fraction == nil
        progress.doubleValue = fraction ?? 0
    }

    func show(_ status: String, isError: Bool = false) {
        statusLabel.stringValue = status
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    // MARK: Actions

    @objc private func fieldEntered(_ sender: Any?) {
        guard !field.stringValue.isEmpty else { return }
        let backward = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        onFind?(backward ? .backward : .forward)
    }

    @objc private func stepClicked(_ sender: NSSegmentedControl) {
        onFind?(sender.selectedSegment == 0 ? .backward : .forward)
    }

    @objc private func findAllClicked(_ sender: Any?) { onFindAll?() }
    @objc private func doneClicked(_ sender: Any?) { onDone?() }

    @objc private func optionsChanged(_ sender: Any?) {
        ignoreCase.isEnabled = kind != .hex
        field.placeholderString = kind == .hex ? "Hex bytes, e.g. 4F 2A" : "Find text"
        if sender != nil { onPatternChange?() }
    }

    func controlTextDidChange(_ notification: Notification) { onPatternChange?() }
}
