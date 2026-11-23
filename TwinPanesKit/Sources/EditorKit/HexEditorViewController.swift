import AppKit
import HexViewKit
import TwinPanesCore
import WorkspaceKit

/// Action selectors of the hex editor, so menus and the command catalog can name them.
@objc public protocol HexEditorActions {
    @objc optional func undo(_ sender: Any?)
    @objc optional func redo(_ sender: Any?)
    @objc optional func editorSave(_ sender: Any?)
    @objc optional func editorRevertToSaved(_ sender: Any?)
    @objc optional func editorSaveAs(_ sender: Any?)
    @objc optional func goToOffset(_ sender: Any?)
    @objc optional func copyAsHex(_ sender: Any?)
    @objc optional func copyAsText(_ sender: Any?)
    @objc optional func saveSelection(_ sender: Any?)
    @objc optional func editorFind(_ sender: Any?)
    @objc optional func editorFindNext(_ sender: Any?)
    @objc optional func editorFindPrevious(_ sender: Any?)
    @objc optional func editorFindAll(_ sender: Any?)
    @objc optional func editorUseSelectionForFind(_ sender: Any?)
    @objc optional func editorCloseFind(_ sender: Any?)
    @objc optional func toggleInspector(_ sender: Any?)
    /// View options; the menu item's `representedObject` carries the value.
    @objc optional func setBytesPerRow(_ sender: Any?)
    @objc optional func setGrouping(_ sender: Any?)
    @objc optional func setOffsetBase(_ sender: Any?)
    @objc optional func setTextEncoding(_ sender: Any?)
}

@MainActor
final class HexEditorViewController: NSViewController, CommandScopeProviding, HexViewDelegate {
    weak var item: HexEditorItem?
    let hexView = HexView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let findBar = FindBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
    let inspector = InspectorView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
    private let divider = NSBox()
    /// Switched by `applyVisibility()` as the find bar and inspector come and go.
    private var hexBelowTop: NSLayoutConstraint?
    private var hexBelowFindBar: NSLayoutConstraint?
    private var hexToEdge: NSLayoutConstraint?
    private var hexToInspector: NSLayoutConstraint?

    // Find state (HexEditorViewController+Find.swift).
    /// Internal test seam so search tests can inject a deterministic `ByteReading`.
    var searchSourceOverride: (any ByteReading)?
    var searchSource: (any ByteReading)? { searchSourceOverride ?? item?.snapshot }
    var searchTask: Task<Void, Never>?
    var searchGeneration = 0
    /// Internal test seam called on the main actor when the active search finishes or cancels.
    var onSearchFinished: (@MainActor () -> Void)?
    /// The match the last find selected; "next" starts after it.
    var lastMatch: Range<UInt64>?
    /// The result of the last Find All, while its pattern is still the bar's pattern.
    var allMatches: (pattern: SearchPattern, result: Searcher.AllMatches)?
    /// True between `hexView(_:overwrite:...)` and its matching `hexViewSelectionDidChange`.
    var applyingTypingEdit = false
    /// Asks whether to revert the file named by the argument; a sheet unless a test
    /// replaces it.
    var confirmRevert: @MainActor (HexEditorViewController, String) async -> Bool =
        HexEditorViewController.askToRevert
    /// Asks what to do about the file changing on disk under unsaved edits; a sheet unless
    /// a test replaces it.
    var askAboutOutsideChange:
        @MainActor (HexEditorViewController, String) async -> OutsideChangeChoice =
            HexEditorViewController.askAboutOutsideChange

    enum OutsideChangeChoice { case keepMine, reload, saveAs }

    init(item: HexEditorItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var commandScopes: [BindingScope] { [.item(.editor)] }

    override func loadView() {
        hexView.delegate = self
        hexView.dataSource = item
        hexView.setAccessibilityIdentifier("hexView")
        // Both panels appear on demand: ⌘F for the find bar, ⌥⌘I for the inspector.
        findBar.isHidden = true
        inspector.isHidden = true
        configureFindBar()
        divider.boxType = .separator

        // Plain constraints: the hex view has no intrinsic size, so it takes whatever
        // the find bar (top) and inspector (right) leave.
        let root = NSView()
        for child in [findBar, hexView, divider, inspector] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        hexBelowTop = hexView.topAnchor.constraint(equalTo: root.topAnchor)
        hexBelowFindBar = hexView.topAnchor.constraint(equalTo: findBar.bottomAnchor)
        hexToEdge = hexView.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        hexToInspector = hexView.trailingAnchor.constraint(equalTo: divider.leadingAnchor)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: root.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hexView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hexView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.topAnchor.constraint(equalTo: hexView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            inspector.topAnchor.constraint(equalTo: hexView.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            inspector.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            inspector.widthAnchor.constraint(equalToConstant: 280),
        ])
        view = root
        applyVisibility()
    }

    /// Puts the hex view below the find bar and left of the inspector when they show.
    func applyVisibility() {
        divider.isHidden = inspector.isHidden
        let pairs = [
            (hexBelowTop, hexBelowFindBar, findBar.isHidden),
            (hexToEdge, hexToInspector, inspector.isHidden),
        ]
        for (whenHidden, whenShown, hidden) in pairs {
            (hidden ? whenShown : whenHidden)?.isActive = false
            (hidden ? whenHidden : whenShown)?.isActive = true
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        item?.updateStatus()
        updateInspector()
    }

    // MARK: HexViewDelegate

    func hexViewSelectionDidChange(_ view: HexView) {
        if applyingTypingEdit {
            applyingTypingEdit = false
        } else {
            item?.breakTypingBurst()
        }
        item?.updateStatus()
        updateInspector()
    }

    func hexViewDidChangeColumn(_ view: HexView) {
        item?.breakTypingBurst()
    }

    func hexViewDidLoadBytes(_ view: HexView) {
        updateInspector()
    }

    /// Shows the bytes at the cursor; waits for the page if it isn't cached yet without
    /// cancelling the hex view's own viewport prefetch.
    func updateInspector() {
        guard !inspector.isHidden, let item else { return }
        let cursor = hexView.selection.cursor
        let range = cursor..<min(item.length, cursor + UInt64(Inspector.byteCount))
        if let bytes = item.cachedBytes(range) { return inspector.show(bytes) }
        item.snapshot.prefetch(range, supersede: false) { [weak self] _ in
            guard let self, let item = self.item, self.hexView.selection.cursor == cursor else {
                return
            }
            self.inspector.show(item.cachedBytes(range) ?? Data())
        }
    }

    @objc func toggleInspector(_ sender: Any?) {
        inspector.isHidden.toggle()
        applyVisibility()
        updateInspector()
    }

    func hexView(_ view: HexView, didFailToRead error: Error) {
        item?.host?.showStatus("\(error)")
    }

    func hexView(_ view: HexView, selectionTooLargeToCopy range: Range<UInt64>) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "The selection is too large to copy"
        alert.informativeText =
            "\(range.count.formatted()) bytes selected; copying is limited to "
            + "\(HexCopy.maxBytes.formatted()) bytes. Save the selection to a file instead?"
        alert.addButton(withTitle: "Save Selection…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.saveSelection(nil) }
        }
    }

    // MARK: Commands

    @objc func goToOffset(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Offset"
        alert.informativeText =
            "Decimal (4096), hex (0x1000, 1000h, $1000), or relative to the cursor (+0x10, -64)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "0x0"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, let item = self.item, response == .alertFirstButtonReturn else {
                return
            }
            if let offset = item.offset(
                for: field.stringValue, cursor: self.hexView.selection.cursor)
            {
                self.hexView.go(to: offset)
            } else {
                NSSound.beep()
                item.host?.showStatus("“\(field.stringValue)” isn't an offset in this file")
            }
        }
    }

    @objc func copyAsHex(_ sender: Any?) { hexView.copySelection(as: .hex) }

    @objc func copyAsText(_ sender: Any?) {
        hexView.copySelection(as: .text(hexView.options.textEncoding))
    }

    @objc func saveSelection(_ sender: Any?) {
        guard let item, let window = view.window else { return }
        let range = hexView.selection.range
        guard !range.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            item.url.deletingPathExtension().lastPathComponent
            + "-\(range.lowerBound)-\(range.count).bin"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, let item = self.item, response == .OK, let destination = panel.url
            else { return }
            item.host?.showStatus("Saving \(range.count.formatted()) bytes…")
            let source = item.snapshot
            let scope = item.scope
            Task.detached(priority: .userInitiated) {
                let error = withExtendedLifetime(scope) {
                    Self.write(source, range: range, to: destination)
                }
                await MainActor.run { [weak self] in
                    self?.item?.host?.showStatus(
                        error.map {
                            "Saving failed: \(($0 as? ByteSourceError)?.description ?? $0.localizedDescription)"
                        }
                            ?? "Saved \(range.count.formatted()) bytes to \(destination.lastPathComponent)"
                    )
                }
            }
        }
    }

    /// Saves `range` of `source` to `destination`; removes any partial output on failure
    /// and returns the error, if any.
    nonisolated static func write(
        _ source: some ByteReading, range: Range<UInt64>, to destination: URL
    )
        -> Error?
    {
        do {
            try source.write(range, to: destination)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return error
        }
    }
}
